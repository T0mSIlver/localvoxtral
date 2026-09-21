import Foundation
import os

/// Mid-dictation reconnect (#380).
///
/// A realtime socket that drops on its own while the user is still speaking
/// used to end the dictation. It now buys the session a bounded run of retries
/// instead: the mic keeps recording, the transcript and the overlay survive the
/// gap, and the audio spoken into it waits in `AudioChunkBuffer` to be replayed
/// on the new socket. Only when the run exhausts its attempts does the session
/// land where it always did — "Connection lost. Dictation stopped."
///
/// Three things the run must never do, and how each is held:
///  - **Resurrect a stopped session.** Every resume point re-checks
///    `reconnectRunID`; `cancelRealtimeReconnect()` bumps it, and the stop,
///    cancel and abort paths all call that.
///  - **Re-commit the audio buffer.** The run never sends a commit. It cancels
///    the periodic commit task at the drop and restarts it only on success.
///  - **Re-insert text Live Auto-Paste already typed.** The dangling partial is
///    promoted into the committed transcript at the drop, so the reconnected
///    backend — which starts with an empty transcript of its own — can only
///    produce text that has never been typed.
extension DictationViewModel {
    // MARK: - Entry

    /// An unexpected drop arrived while dictating. Starts a reconnect run and
    /// returns true when it did; false means this drop is not recoverable and
    /// the caller must end the dictation.
    func beginRealtimeReconnectIfPossible(
        policy: RealtimeReconnectPolicy = .default
    ) -> Bool {
        guard let configuration = sessionRealtimeConfiguration else {
            Log.backends.error(
                "realtime socket dropped mid-dictation with no latched session configuration; cannot reconnect"
            )
            return false
        }

        reconnectRunID &+= 1
        let runID = reconnectRunID
        isReconnectingRealtimeSession = true
        reconnectAttemptDidFail = false

        // Nothing may keep talking to a socket that is gone. Stopping the
        // audio drain is also what lets the buffer hold the gap: chunks the
        // send loop would have taken and dropped stay put for the replay.
        commitTask?.cancel()
        commitTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil

        // The partial in flight can never be finalized by a session that no
        // longer exists. Promoting it keeps those words — and, because the
        // reconnected backend starts empty, is also what stops Live Auto-Paste
        // typing them a second time.
        if let promoted = promotePendingRealtimeTextToLatestSegment() {
            // Also into the running transcript the popover shows, which the
            // stop-time promotion can skip (the session ends right behind it)
            // but a session that keeps going cannot: the gap would leave a
            // hole in it for the rest of the dictation.
            appendToTranscript(promoted)
        }
        refreshOverlayBufferSession()

        // The socket error that preceded the drop is the reconnect's business,
        // not a standing error for the user to read while it works.
        if let lastError, lastError == lastSocketErrorMessage {
            self.lastError = nil
        }

        statusText = StatusStrings.reconnecting
        Log.backends.notice(
            "realtime socket dropped mid-dictation; reconnect run \(runID, privacy: .public) starting, up to \(policy.maxAttempts, privacy: .public) attempts"
        )

        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            #if DEBUG
            if let sleep = self.debugReconnectSleepOverride {
                await self.runRealtimeReconnect(
                    runID: runID,
                    configuration: configuration,
                    policy: policy,
                    sleepFor: sleep
                )
                return
            }
            #endif
            await self.runRealtimeReconnect(
                runID: runID,
                configuration: configuration,
                policy: policy
            )
        }
        return true
    }

    /// Abandon any reconnect run in flight. Idempotent, and safe to call from
    /// paths that never started one.
    func cancelRealtimeReconnect() {
        guard isReconnectingRealtimeSession || reconnectTask != nil else { return }
        // Bumped before the task is cancelled: a run suspended in its sleep
        // seam resumes, sees a run ID that is no longer its own, and returns
        // without touching the session.
        reconnectRunID &+= 1
        isReconnectingRealtimeSession = false
        reconnectAttemptDidFail = false
        reconnectTask?.cancel()
        reconnectTask = nil
        // Cancelling the task does not cancel the socket the attempt opened.
        // Left alone, a socket still in `connecting` can open after the stop
        // and transmit the audio the stop flushed into its pending queue — the
        // stop-finalization path takes its `!isConnected` shortcut and never
        // closes it, and its late `.connected` turns the menu bar icon green
        // with no session behind it. A run is only ever in flight when the
        // session has no healthy socket, so there is nothing here to protect.
        // Emission is queued to the main queue, so the `.disconnected` this
        // raises cannot re-enter before the caller finishes tearing down.
        activeRealtimeClient.disconnect()
        Log.backends.notice("realtime reconnect run cancelled")
    }

    // MARK: - The run

    /// Retry `configuration` on a bounded backoff until the socket opens or the
    /// attempts run out. `sleepFor` is the only clock: tests drive the whole
    /// run — including a stop landing mid-attempt — through it.
    func runRealtimeReconnect(
        runID: Int,
        configuration: RealtimeSessionConfiguration,
        policy: RealtimeReconnectPolicy = .default,
        sleepFor: @MainActor (TimeInterval) async -> Void = DictationViewModel.sleepForReconnect
    ) async {
        for attempt in 1...max(1, policy.maxAttempts) {
            await sleepFor(policy.backoff(beforeAttempt: attempt))
            guard isReconnectRunCurrent(runID) else { return }

            reconnectAttemptDidFail = false
            Log.backends.notice(
                "realtime reconnect attempt \(attempt, privacy: .public)/\(policy.maxAttempts, privacy: .public)"
            )
            do {
                // `connect` closes whatever the client still holds, so the run
                // never calls `disconnect` itself: that would emit a
                // `.disconnected` of its own and read as the new socket failing.
                try activeRealtimeClient.connect(configuration: configuration)
            } catch {
                Log.backends.error(
                    "realtime reconnect attempt \(attempt, privacy: .public) could not open a socket: \(error.localizedDescription, privacy: .public)"
                )
                continue
            }

            var waited: TimeInterval = 0
            while waited < policy.attemptTimeout {
                await sleepFor(policy.pollInterval)
                guard isReconnectRunCurrent(runID) else { return }
                // Failure is read FIRST: a server can accept the upgrade and
                // then reject the session on an open socket, which leaves
                // `isConnected` true on a session that will never transcribe.
                if reconnectAttemptDidFail { break }
                if activeRealtimeClient.isConnected {
                    completeRealtimeReconnect(attempt: attempt)
                    return
                }
                waited += policy.pollInterval
            }
            Log.backends.error(
                "realtime reconnect attempt \(attempt, privacy: .public) did not reach a connected socket"
            )
        }

        guard isReconnectRunCurrent(runID) else { return }
        exhaustRealtimeReconnect(policy: policy)
    }

    /// Whether `runID` still owns the session. False once a stop, a cancel or a
    /// newer session has moved on — the run must then change nothing.
    private func isReconnectRunCurrent(_ runID: Int) -> Bool {
        isReconnectingRealtimeSession && reconnectRunID == runID && isDictating
    }

    private func completeRealtimeReconnect(attempt: Int) {
        isReconnectingRealtimeSession = false
        reconnectAttemptDidFail = false
        reconnectTask = nil

        let replaySeconds =
            Double(audioChunkBuffer.bufferedByteCount) / Double(AudioChunkBuffer.bytesPerSecond)
        Log.backends.notice(
            "realtime reconnected on attempt \(attempt, privacy: .public); replaying \(String(format: "%.1f", replaySeconds), privacy: .public)s of buffered audio"
        )

        setRealtimeIndicatorConnected()
        statusText = "Listening..."
        // The buffer is deliberately NOT cleared: the first tick of the
        // restarted send loop is what replays the gap.
        restartAudioSendTask()
        restartCommitTask()
    }

    private func exhaustRealtimeReconnect(policy: RealtimeReconnectPolicy) {
        isReconnectingRealtimeSession = false
        reconnectAttemptDidFail = false
        reconnectTask = nil
        Log.backends.error(
            "realtime reconnect exhausted after \(policy.maxAttempts, privacy: .public) attempts; stopping dictation"
        )
        // The last attempt may still hold a half-open socket that would
        // otherwise connect into a session that no longer exists.
        activeRealtimeClient.disconnect()
        endDictationAfterLostConnection(
            technicalDetails:
                "Realtime websocket disconnected unexpectedly during active dictation; reconnect failed after \(policy.maxAttempts) attempts."
        )
    }

    /// The end of the line for a dropped socket: tear the session down and say
    /// so. Shared by an unrecoverable drop and an exhausted reconnect run.
    func endDictationAfterLostConnection(
        technicalDetails: String =
            "Realtime websocket disconnected unexpectedly during active dictation."
    ) {
        commitTask?.cancel()
        commitTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        healthMonitor.stop()
        isAwaitingMicrophonePermission = false
        microphone.stop()
        isDictating = false
        escapeCancelHandler.stop()
        finishStoppedSession(promotePendingSegment: true)
        statusText = Self.connectionLostMessage
        lastError = Self.connectionLostMessage
        logConnectionFailure(
            message: Self.connectionLostMessage,
            technicalDetails: technicalDetails
        )
        markRecentConnectionFailureIndicator()
    }

    private static func sleepForReconnect(_ duration: TimeInterval) async {
        try? await Task.sleep(for: .seconds(duration))
    }
}
