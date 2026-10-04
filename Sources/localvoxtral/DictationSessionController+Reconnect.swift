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
extension DictationSessionController {
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
        audio.cancelSendAndCommitTasks()
        // Ahead of them, what the socket took but closed on before sending.
        audio.reclaimUnsentAudio(from: activeRealtimeClient)
        // No text can arrive while the socket is down; a silence stop now
        // would end the session before the gap is replayed.
        pauseSilenceAutoStopForReconnect()
        // Likewise for the voice stop; the next text after the reconnect
        // decides again.
        disarmSpokenStop()

        // The partial in flight can never be finalized by a session that no
        // longer exists. Promoting it keeps those words — and, because the
        // reconnected backend starts empty, is also what stops Live Auto-Paste
        // typing them a second time.
        if let promoted = promotePendingRealtimeTextToLatestSegment() {
            // Also into the running transcript the popover shows, which the
            // stop-time promotion can skip (the session ends right behind it)
            // but a session that keeps going cannot: the gap would leave a
            // hole in it for the rest of the dictation.
            transcript.appendToTranscript(promoted)
        }
        // The new server session's first word must not run into the last one
        // typed (#1364).
        if !transcript.currentDictationEventText.isEmpty {
            firstChunkPreprocessor.markReconnect()
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
            await self.runRealtimeReconnect(
                runID: runID,
                configuration: configuration,
                policy: policy,
                sleepFor: self.dependencies.reconnectSleep
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
        // The session gives up whatever socket the last attempt opened, so it
        // is on no connection: a socket that opens after this cannot turn the
        // menu bar icon green behind a session that ended (#417).
        sessionConnectionGeneration = .none
        // Cancelling the task does not cancel the socket the attempt opened.
        // Left alone, a socket still in `connecting` can open after the stop
        // and transmit the audio the stop flushed into its pending queue — the
        // stop-finalization path takes its `!isConnected` shortcut and never
        // closes it. The connection stamp refuses everything that socket says
        // (the cleared generation above), but it cannot stop it from SENDING;
        // only closing it does. A run is only ever in flight when the session
        // has no healthy socket, so there is nothing here to protect.
        // Emission is queued to the main queue, so the `.disconnected` this
        // raises cannot re-enter before the caller finishes tearing down.
        activeRealtimeClient.disconnect()
        Log.backends.notice("realtime reconnect run cancelled")
    }

    // MARK: - The run

    /// Retry `configuration` on a bounded backoff until a server session is
    /// ready or the attempts run out. `sleepFor` is the only clock: tests drive the whole
    /// run — including a stop landing mid-attempt — through it.
    func runRealtimeReconnect(
        runID: Int,
        configuration: RealtimeSessionConfiguration,
        policy: RealtimeReconnectPolicy = .default,
        sleepFor: @MainActor (TimeInterval) async -> Void = DictationSessionController.sleepForReconnect
    ) async {
        var helperStartBudget = sessionUsesManagedSpeechHelper ? policy.managedHelperStartBudget : 0
        for attempt in 1...max(1, policy.maxAttempts) {
            await sleepFor(policy.backoff(beforeAttempt: attempt))
            guard isReconnectRunCurrent(runID) else { return }
            if helperStartBudget > 0, backendManager.speechdStatus == .starting {
                Log.backends.notice(
                    "realtime reconnect waiting for the bundled helper to finish starting before attempt \(attempt, privacy: .public)"
                )
                while helperStartBudget > 0, backendManager.speechdStatus == .starting {
                    await sleepFor(policy.pollInterval)
                    guard isReconnectRunCurrent(runID) else { return }
                    helperStartBudget -= policy.pollInterval
                }
                Log.backends.notice(
                    "realtime reconnect done waiting for the bundled helper: \(String(describing: self.backendManager.speechdStatus), privacy: .public)"
                )
            }

            reconnectAttemptDidFail = false
            Log.backends.notice(
                "realtime reconnect attempt \(attempt, privacy: .public)/\(policy.maxAttempts, privacy: .public)"
            )
            do {
                // `connect` closes whatever the client still holds, so the run
                // never calls `disconnect` itself: that would emit a
                // `.disconnected` of its own and read as the new socket failing.
                try activeRealtimeClient.connect(configuration: configuration)
                // The session moves onto the socket this attempt opened. The
                // one it left behind can still emit — a transcript above all —
                // and is refused from here by name, not by guesswork (#417).
                sessionConnectionGeneration = activeRealtimeClient.connectionGeneration
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
                // Readiness, not the upgrade (#1457). Audio the restarted send
                // loop hands an open socket before its handshake waits in the
                // client, and a close before the handshake erases it there:
                // until then the gap stays in `AudioChunkBuffer`, and such a
                // close fails this attempt instead of ending the run and
                // starting a fresh one with a fresh allowance.
                if activeRealtimeClient.isSessionReady {
                    completeRealtimeReconnect(attempt: attempt)
                    return
                }
                waited += policy.pollInterval
            }
            Log.backends.error(
                "realtime reconnect attempt \(attempt, privacy: .public) did not reach a ready session"
            )
        }

        guard isReconnectRunCurrent(runID) else { return }
        exhaustRealtimeReconnect(policy: policy)
    }

    /// Whether `runID` still owns the session. False once a stop, a cancel or a
    /// newer session has moved on — the run must then change nothing.
    private func isReconnectRunCurrent(_ runID: Int) -> Bool {
        // A stop during the run keeps it, to finalize the gap (#1582).
        isReconnectingRealtimeSession && reconnectRunID == runID && (isDictating || isFinalizingStop)
    }

    private func completeRealtimeReconnect(attempt: Int) {
        isReconnectingRealtimeSession = false
        reconnectAttemptDidFail = false
        reconnectTask = nil

        let replaySeconds =
            Double(audio.audioChunkBuffer.bufferedByteCount) / Double(AudioChunkBuffer.bytesPerSecond)
        Log.backends.notice(
            "realtime reconnected on attempt \(attempt, privacy: .public); replaying \(String(format: "%.1f", replaySeconds), privacy: .public)s of buffered audio"
        )

        setRealtimeIndicatorConnected()
        guard isDictating else {
            // The user stopped while the run dialled: the gap goes to the new
            // server session with the stop's final commit behind it, once.
            statusText = StatusStrings.finalizing
            audio.flushBufferedAudio(to: activeRealtimeClient)
            scheduleStopFinalization()
            startStopFinalizationWatchdog()
            return
        }
        statusText = "Listening..."
        // The buffer is deliberately NOT cleared: the first tick of the
        // restarted send loop is what replays the gap.
        audio.restartAudioSendTask(
            client: activeRealtimeClient,
            debugLoggingEnabled: debugLoggingEnabled,
            sleep: dependencies.clock.sleep
        )
        audio.restartCommitTask(client: activeRealtimeClient, sleep: dependencies.clock.sleep)
        resumeSilenceAutoStopAfterReconnect()
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
        guard isDictating else {
            finishStopWithoutTheReconnectGap(
                reason: "reconnect failed after \(policy.maxAttempts) attempts"
            )
            return
        }
        endDictationAfterLostConnection(
            technicalDetails:
                "Realtime websocket disconnected unexpectedly during active dictation; reconnect failed after \(policy.maxAttempts) attempts."
        )
    }

    /// The socket closed while the stop finalizes. Audio it never sent (a
    /// rollover's carried audio, with the final commit queued behind it,
    /// #1672) goes to a new socket through a reconnect, under the stop's
    /// watchdog; otherwise the stop ends with what arrived.
    func finishStopOnClosedSocket() {
        // A reconnect already carries the stop; its watchdog bounds it.
        guard !isReconnectingRealtimeSession else { return }
        if !isCompletingStoppedSession, audio.reclaimUnsentAudio(from: activeRealtimeClient) {
            stopFinalizationTask?.cancel()
            stopFinalizationTask = nil
            if beginRealtimeReconnectIfPossible() {
                statusText = StatusStrings.finalizing
                return
            }
        }
        finishStoppedSession(promotePendingSegment: true)
    }

    /// A stop that waited on a reconnect run which never got through: it
    /// finishes with the text received before the drop, and says its end may
    /// be missing, since the speech since the drop was never transcribed.
    func finishStopWithoutTheReconnectGap(reason: String) {
        let lostSeconds =
            Double(audio.audioChunkBuffer.takeAll().count) / Double(AudioChunkBuffer.bytesPerSecond)
        Log.backends.error(
            "stop finalization: \(reason, privacy: .public); \(String(format: "%.1f", lostSeconds), privacy: .public)s of speech since the drop not transcribed"
        )
        realtimeErrorDuringStop = true
        finishStoppedSession(promotePendingSegment: true)
    }

    /// The end of the line for a dropped socket: tear the session down and say
    /// so. Shared by an unrecoverable drop and an exhausted reconnect run.
    func endDictationAfterLostConnection(
        technicalDetails: String =
            "Realtime websocket disconnected unexpectedly during active dictation."
    ) {
        audio.cancelSendAndCommitTasks()
        audio.healthMonitor.stop()
        isAwaitingMicrophonePermission = false
        audio.stopSessionAudioCapture()
        // Here and not at the drop: a reconnect keeps the session running, and
        // fading the user's music back mid-sentence would announce a blip they
        // were never meant to notice. This is the end of the line.
        audio.audioDucking.restoreAfterSession()
        isDictating = false
        disarmSilenceAutoStop()
        disarmSpokenStop()
        escapeCancelHandler.stop()
        endDestinations()
        ownStopWithoutFinalization()
        finishStoppedSession(promotePendingSegment: true)
        statusText = Self.connectionLostMessage
        lastError = Self.connectionLostMessage
        logConnectionFailure(
            message: Self.connectionLostMessage,
            technicalDetails: technicalDetails
        )
        markRecentConnectionFailureIndicator()
    }

    nonisolated static func sleepForReconnect(_ duration: TimeInterval) async {
        try? await Task.sleep(for: .seconds(duration))
    }
}
