import Foundation
import os

extension DictationSessionController {
    // MARK: - Realtime Event Routing

    /// The door every realtime event comes through in the running app, and the
    /// one place a connection's identity is judged (#417).
    ///
    /// `generation` names the socket that raised the event. A socket the session
    /// has already retired can report its close, its error or a transcript long
    /// after the session moved on — in Live Auto-Paste a straggling transcript
    /// would be typed a second time, and there are no backspaces in the
    /// insertion path. Nothing downstream re-checks this, so nothing downstream
    /// has to guess from session state which socket it is hearing.
    func handle(event: RealtimeEvent, from generation: RealtimeConnectionGeneration) {
        guard generation == sessionConnectionGeneration else {
            debugLog(
                "dropping an event from connection \(generation); "
                    + "the session is on \(sessionConnectionGeneration)"
            )
            return
        }
        if case .disconnected = event {
            // The session's socket just said it is gone, so the session is on no
            // connection until the next dial stamps one. This is what refuses a
            // straggler emitted between the close and the reconnect's first
            // attempt, when the generation has not moved on yet.
            sessionConnectionGeneration = .none
        }
        handle(event: event)
    }

    /// Routes an event that has already been judged to belong to the session's
    /// live socket. Reached from `handle(event:from:)` in the app; called
    /// directly only by tests that drive the session without a socket.
    func handle(event: RealtimeEvent) {
        // Instrument the raw, pre-processing delta stream first. This is the
        // single choke point where every realtime event arrives on the main
        // actor; logging here captures exactly what the backend delivered
        // before FirstChunkPreprocessor / merge / insertion touch it. No-op
        // unless the hidden `debug.log_realtime_deltas` toggle is set.
        realtimeDeltaLog.record(
            event,
            isEnabled: settings.debugLogRealtimeDeltas,
            sink: dependencies.onRealtimeDeltaLogRecord
        )

        switch event {
        case .connected:
            handleConnectedEvent()
        case .disconnected:
            handleDisconnectedEvent()
        case .status(let message):
            handleStatusEvent(message)
        case .partialTranscript(let delta):
            handlePartialTranscriptEvent(delta)
        case .finalTranscript(let text):
            handleFinalTranscriptEvent(text)
        case .transcriptionFinalized:
            handleTranscriptionFinalizedEvent()
        case .error(let message):
            handleErrorEvent(message)
        case .transcriptionStopped(let message):
            handleTranscriptionStoppedEvent(message)
        }
    }

    // MARK: - Event Handlers

    private func handleConnectedEvent() {
        cancelConnectTimeout()
        if isReconnectingRealtimeSession {
            // The run's own poll notices the open socket and owns what happens
            // next (status line, audio and commit tasks). Only the indicator
            // turns green here, as early as the news arrives.
            setRealtimeIndicatorConnected()
            return
        }
        if isConnectingRealtimeSession {
            if shortcuts.shouldCancelPushToTalkStartAfterConnect() {
                abortConnectingSession()
                setRealtimeIndicatorIdle()
                statusText = "Ready"
                return
            }
            setRealtimeIndicatorConnected()
            startAudioCaptureAfterConnection()
            return
        }
        setRealtimeIndicatorConnected()
        statusText = activeStatusText
    }

    private func handleDisconnectedEvent() {
        cancelConnectTimeout()
        if isConnectingRealtimeSession {
            abortConnectingSession(disconnectSocket: false)
            handleConnectFailure(reason: .socketError(message: lastSocketErrorMessage))
            return
        }

        if isFinalizingStop {
            finishStoppedSession(promotePendingSegment: true)
            return
        }
        guard isDictating else {
            // A socket closing after the session already ended must not erase
            // the red icon a failure just lit: an exhausted reconnect run
            // closes its last half-open socket right after the teardown.
            if realtimeSessionIndicatorState != .recentFailure {
                setRealtimeIndicatorIdle()
            }
            return
        }
        if isReconnectingRealtimeSession {
            // This is the answer to the attempt in flight, not a fresh drop.
            reconnectAttemptDidFail = true
            return
        }
        guard !beginRealtimeReconnectIfPossible() else { return }
        endDictationAfterLostConnection()
    }

    private func handleStatusEvent(_ message: String) {
        // "Reconnecting..." stands until the run ends, whatever a dying or a
        // freshly opened socket has to say about its session in the meantime.
        if isReconnectingRealtimeSession { return }
        if isConnectingRealtimeSession {
            statusText = "Connecting to realtime backend..."
            return
        }
        if !acceptsRealtimeEvents {
            statusText = "Ready"
            return
        }
        if isFinalizingStop {
            statusText = "Finalizing..."
            return
        }

        let normalized = message.trimmed.lowercased()
        if normalized.contains("session") || normalized.contains("connected")
            || normalized.contains("disconnected")
        {
            statusText = "Listening..."
        } else {
            statusText = message
        }
    }

    private func handlePartialTranscriptEvent(_ delta: String) {
        guard acceptsRealtimeEvents else { return }
        let processedDelta = preprocessIncomingTranscriptChunk(delta)
        guard !processedDelta.isEmpty else { return }
        if isFinalizingStop {
            realtimeFinalizationLastActivityAt = dependencies.clock.now()
        }

        transcript.appendPartial(processedDelta)
        if isLiveAutoPasteModeEnabled, liveSpokenSendWithholdsSegment() {
            // Typed at the final, once it is known whether it ends in the
            // trigger: typed text cannot be taken back.
        } else if isLiveAutoPasteModeEnabled {
            textInsertion.enqueueRealtimeInsertion(processedDelta)
            if let accessibilityError = textInsertion.lastAccessibilityError {
                lastError = accessibilityError
            }
        }
        statusText = isFinalizingStop ? StatusStrings.finalizing : "Transcribing..."
        refreshOverlayBufferSession()
    }

    private func handleFinalTranscriptEvent(_ text: String) {
        guard acceptsRealtimeEvents else { return }
        let processedText = preprocessIncomingTranscriptChunk(text)
        if isFinalizingStop {
            realtimeFinalizationLastActivityAt = dependencies.clock.now()
        }

        guard let finalized = transcript.applyFinal(processedText) else {
            refreshOverlayBufferSession()
            return
        }
        statusText = activeStatusText

        if isLiveAutoPasteModeEnabled, liveSpokenSendWithholdsSegment() {
            // No partial of this segment was typed, so the whole segment is.
            deliverLiveSpokenSendFinal(processedText, merged: finalized.text)
        } else if isLiveAutoPasteModeEnabled {
            liveSpokenSendSegmentMode = .undecided
            if let liveInsertion = finalized.liveInsertion {
                textInsertion.enqueueRealtimeInsertion(liveInsertion)
            }
            if let accessibilityError = textInsertion.lastAccessibilityError {
                lastError = accessibilityError
            }
        }

        if isLiveAutoPasteModeEnabled, settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }
        refreshOverlayBufferSession()
    }

    private func handleTranscriptionFinalizedEvent() {
        guard isFinalizingStop else { return }
        debugLog("transcription finalized, disconnecting")
        activeRealtimeClient.disconnect()
    }

    private func handleErrorEvent(_ message: String) {
        lastSocketErrorMessage = message
        if isConnectingRealtimeSession {
            abortConnectingSession()
            handleConnectFailure(reason: .socketError(message: message))
            return
        }
        if isResolvingConnectTimeout {
            handleConnectFailure(reason: .socketError(message: message))
            return
        }
        if isReconnectingRealtimeSession {
            // The socket this attempt opened has already failed. Let the
            // attempt give up now instead of waiting out its timeout.
            reconnectAttemptDidFail = true
            Log.backends.error(
                "realtime reconnect attempt reported a socket error: \(message, privacy: .public)"
            )
            return
        }
        if !acceptsRealtimeEvents {
            statusText = "Ready"
            return
        }
        if isFinalizingStop {
            debugLog("realtime error while finalizing: \(message)")
            return
        }

        statusText = "Realtime error."
        lastError = message
        Log.dictation.error("Realtime error: \(message, privacy: .public)")
    }

    /// The backend stopped transcribing mid-dictation and said why in one short sentence
    /// (#314). That sentence IS the status line: a generic "Realtime error." with "See
    /// Console for details." would hide the only actionable part. The mic stays open, so
    /// nothing later overwrites it until the user stops.
    private func handleTranscriptionStoppedEvent(_ message: String) {
        Log.dictation.error("Realtime transcription stopped: \(message, privacy: .public)")
        guard acceptsRealtimeEvents, !isFinalizingStop else { return }
        statusText = message
    }

    // MARK: - Segment Promotion

    @discardableResult
    func promotePendingRealtimeTextToLatestSegment() -> String? {
        guard let pendingSegment = transcript.promotePendingToLatestSegment() else { return nil }

        // Withheld partials are typed nowhere else: a promotion (stop,
        // dropped socket) stands in for the final they never got.
        if isLiveAutoPasteModeEnabled {
            deliverPromotedLiveSpokenSendSegment(pendingSegment)
        }

        if isLiveAutoPasteModeEnabled, settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }

        return pendingSegment
    }

    // MARK: - Helpers

    /// Status text appropriate for the current dictation phase.
    private var activeStatusText: String {
        if isDictating { return "Listening..." }
        if isFinalizingStop { return "Finalizing..." }
        return "Ready"
    }

    private func preprocessIncomingTranscriptChunk(_ chunk: String) -> String {
        firstChunkPreprocessor.preprocess(chunk)
    }

    // MARK: - Overlay Text

    func currentOverlayDisplayText() -> String {
        overlayStreamingCorrectedText(transcript.overlayDisplayText)
    }

    func currentOverlayCommitText() -> String {
        overlayStreamingCorrectedText(transcript.overlayCommitText)
    }

    private func overlayStreamingCorrectedText(_ text: String) -> String {
        guard isOverlayBufferModeEnabled,
              !isCompletingStoppedSession,
              let dictionary = replacementDictionaryForCurrentSession()
        else {
            return text
        }

        return LiveReplacementCorrector.completedBoundaryCorrectedText(
            text,
            dictionary: dictionary
        )
    }
}
