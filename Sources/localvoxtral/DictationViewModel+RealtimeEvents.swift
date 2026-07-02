import Foundation
import os

extension DictationViewModel {
    // MARK: - Realtime Event Routing

    func handle(event: RealtimeEvent) {
        // Instrument the raw, pre-processing delta stream first. This is the
        // single choke point where every realtime event arrives on the main
        // actor; logging here captures exactly what the backend delivered
        // before FirstChunkPreprocessor / merge / insertion touch it. No-op
        // unless the hidden `debug.log_realtime_deltas` toggle is set.
        logRawRealtimeEventIfEnabled(event)

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
        }
    }

    // MARK: - Event Handlers

    private func handleConnectedEvent() {
        cancelConnectTimeout()
        if isConnectingRealtimeSession {
            if shouldCancelPushToTalkStartAfterConnect() {
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
            handleConnectFailure(reason: .socketError(message: lastError))
            return
        }

        if isFinalizingStop {
            finishStoppedSession(promotePendingSegment: true)
            return
        }
        guard isDictating else {
            setRealtimeIndicatorIdle()
            return
        }
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
        let message = "Connection lost. Dictation stopped."
        statusText = message
        lastError = message
        logConnectionFailure(
            message: message,
            technicalDetails:
                "Realtime websocket disconnected unexpectedly during active dictation."
        )
        markRecentConnectionFailureIndicator()
    }

    private func handleStatusEvent(_ message: String) {
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
            realtimeFinalizationLastActivityAt = Date()
        }

        pendingSegmentText.append(processedDelta)
        livePartialText = pendingSegmentText
        if isLiveAutoPasteModeEnabled {
            textInsertion.enqueueRealtimeInsertion(processedDelta)
            if let accessibilityError = textInsertion.lastAccessibilityError {
                lastError = accessibilityError
            }
        }
        statusText = isFinalizingStop ? "Finalizing..." : "Transcribing..."
        refreshOverlayBufferSession()
    }

    private func handleFinalTranscriptEvent(_ text: String) {
        guard acceptsRealtimeEvents else { return }
        let processedText = preprocessIncomingTranscriptChunk(text)
        if isFinalizingStop {
            realtimeFinalizationLastActivityAt = Date()
        }

        let finalizedSegment = resolvedFinalizedSegment(from: processedText)
        let hadLiveDelta = !pendingSegmentText.trimmed.isEmpty
            || !livePartialText.trimmed.isEmpty
        // Text already typed into the field by the live partial path. Derived
        // from the same state the `hadLiveDelta` guard reads (accumulated
        // pending text, with live-partial text as fallback) so it cannot drift
        // from a parallel bookkeeping. Captured before the reset below.
        let liveInsertedText = pendingSegmentText.trimmed.isEmpty
            ? livePartialText
            : pendingSegmentText
        guard !finalizedSegment.isEmpty else {
            livePartialText = ""
            pendingSegmentText = ""
            refreshOverlayBufferSession()
            return
        }

        appendToTranscript(finalizedSegment)
        currentDictationEventText = TextMergingAlgorithms.appendToCurrentDictationEvent(
            segment: finalizedSegment,
            existingText: currentDictationEventText
        )
        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""
        statusText = activeStatusText

        if isLiveAutoPasteModeEnabled {
            if !hadLiveDelta {
                // No partials were typed live: insert the whole segment.
                textInsertion.enqueueRealtimeInsertion(finalizedSegment)
            } else if let liveSuffix = TextMergingAlgorithms.livePasteExtensionSuffix(
                finalText: processedText,
                liveInsertedText: liveInsertedText
            ) {
                // Partials were already typed live and the final is a pure
                // extension of them (e.g. a trailing "." that only arrived in
                // the final): insert only the missing suffix so the trailing
                // addition reaches the field without duplicating earlier text.
                // When the final revises earlier content the helper returns nil
                // and nothing is inserted — live mode cannot rewrite already
                // typed text.
                textInsertion.enqueueRealtimeInsertion(liveSuffix)
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
        realtimeAPIClient.disconnect()
    }

    private func handleErrorEvent(_ message: String) {
        if isConnectingRealtimeSession {
            abortConnectingSession()
            handleConnectFailure(reason: .socketError(message: message))
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

    // MARK: - Segment Promotion

    @discardableResult
    func promotePendingRealtimeTextToLatestSegment() -> String? {
        let pendingSegment = resolvedFinalizedSegment(from: "")
        guard !pendingSegment.isEmpty else { return nil }

        currentDictationEventText = TextMergingAlgorithms.appendToCurrentDictationEvent(
            segment: pendingSegment,
            existingText: currentDictationEventText
        )
        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""

        if isLiveAutoPasteModeEnabled, settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }

        return pendingSegment
    }

    // MARK: - Helpers

    /// Append a finalized segment to the running transcript.
    private func appendToTranscript(_ segment: String) {
        if transcriptText.isEmpty {
            transcriptText = segment
        } else {
            transcriptText += "\n" + segment
        }
    }

    /// Status text appropriate for the current dictation phase.
    private var activeStatusText: String {
        if isDictating { return "Listening..." }
        if isFinalizingStop { return "Finalizing..." }
        return "Ready"
    }

    private func preprocessIncomingTranscriptChunk(_ chunk: String) -> String {
        firstChunkPreprocessor.preprocess(chunk)
    }

    // MARK: - Raw Delta Logging (issue #13 instrumentation)

    /// Emit the raw payload of every received realtime event to `Log.deltas`
    /// (notice level) BEFORE any processing, when the hidden
    /// `SettingsStore.debugLogRealtimeDeltas` toggle is on. Each event within
    /// a session carries a monotonic `sequence` that resets when a new session
    /// connects, so the arrival order of deltas is unambiguous in the log.
    ///
    /// Partial/final transcript payloads are logged via `.debugDescription` so
    /// the exact characters — including any leading/trailing/inner whitespace
    /// and the punctuation placement under investigation — are visible, and
    /// marked `.public` (see `debugLogRealtimeDeltas` docs for the privacy
    /// rationale). No-op when the toggle is off.
    private func logRawRealtimeEventIfEnabled(_ event: RealtimeEvent) {
        guard settings.debugLogRealtimeDeltas else { return }

        // A new realtime session starts the per-session sequence over.
        if case .connected = event {
            realtimeDeltaLogSequence = 0
        }

        let sequence = realtimeDeltaLogSequence
        realtimeDeltaLogSequence &+= 1

        switch event {
        case .connected:
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] session boundary: connected")
            emitDeltaLogRecord(.sessionConnected, sequence: sequence, payload: nil)
        case .disconnected:
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] session boundary: disconnected")
            emitDeltaLogRecord(.sessionDisconnected, sequence: sequence, payload: nil)
        case .partialTranscript(let delta):
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] partial delta: \(delta.debugDescription, privacy: .public)")
            emitDeltaLogRecord(.partialDelta, sequence: sequence, payload: delta)
        case .finalTranscript(let text):
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] final transcript: \(text.debugDescription, privacy: .public)")
            emitDeltaLogRecord(.finalTranscript, sequence: sequence, payload: text)
        case .status(let message):
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] status: \(message, privacy: .public)")
            emitDeltaLogRecord(.status, sequence: sequence, payload: message)
        case .error(let message):
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] error: \(message, privacy: .public)")
            emitDeltaLogRecord(.error, sequence: sequence, payload: message)
        case .transcriptionFinalized:
            Log.deltas.notice(
                "[delta-log seq=\(sequence)] transcription finalized")
            emitDeltaLogRecord(.transcriptionFinalized, sequence: sequence, payload: nil)
        }
    }

    /// Mirror the delta-log emission to the `#if DEBUG` test sink. Defined on
    /// the main type (the sink is invoked inline from production code, like
    /// `TextInsertionService`'s `debugUnicodePoster`), so no compile-time DEBUG
    /// guard is needed here: the sink is nil in release builds.
    private func emitDeltaLogRecord(
        _ kind: DebugRealtimeDeltaLogRecord.Kind, sequence: Int, payload: String?
    ) {
        debugDeltaLogSink?(
            DebugRealtimeDeltaLogRecord(kind: kind, sequence: sequence, payload: payload))
    }

    // MARK: - Finalized Segment Resolution

    func resolvedFinalizedSegment(from finalText: String) -> String {
        let finalizedText = finalText.trimmed
        let bufferedText = pendingSegmentText.trimmed
        let fallbackBufferedText = livePartialText.trimmed
        let pendingText = bufferedText.isEmpty ? fallbackBufferedText : bufferedText

        if finalizedText.isEmpty {
            return pendingText
        }

        if pendingText.isEmpty {
            return finalizedText
        }

        if finalizedText.count > pendingText.count, finalizedText.hasPrefix(pendingText) {
            return finalizedText
        }
        if pendingText.hasSuffix(finalizedText) {
            return pendingText
        }
        if pendingText.hasPrefix(finalizedText) {
            return pendingText
        }

        if let pendingLast = pendingText.last,
            let finalizedFirst = finalizedText.first,
            !pendingLast.isWhitespace,
            !finalizedFirst.isWhitespace
        {
            return pendingText + " " + finalizedText
        }
        return pendingText + finalizedText
    }

    func currentOverlayDisplayText() -> String {
        overlayStreamingCorrectedText(
            OverlayBufferTextAssembler.displayText(
                committedText: currentDictationEventText,
                pendingText: pendingSegmentText,
                fallbackPendingText: livePartialText
            )
        )
    }

    func currentOverlayCommitText() -> String {
        overlayStreamingCorrectedText(
            OverlayBufferTextAssembler.commitText(
                committedText: currentDictationEventText,
                pendingText: pendingSegmentText,
                fallbackPendingText: livePartialText
            )
        )
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
