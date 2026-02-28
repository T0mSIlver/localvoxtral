import Foundation
import os

extension DictationViewModel {
    // MARK: - Realtime Event Routing

    func handle(event: RealtimeEvent, source: ActiveClientSource) {
        guard source == activeClientSource else {
            // During stop-finalization, be permissive with disconnect routing.
            // Some backends can close on a different callback path than expected.
            if isFinalizingStop, case .disconnected = event {
                handleDisconnectedEvent()
            }
            return
        }

        switch event {
        case .connected:
            handleConnectedEvent()
        case .disconnected:
            handleDisconnectedEvent()
        case .status(let message):
            handleStatusEvent(message)
        case .partialTranscript(let delta):
            handlePartialTranscriptEvent(delta, source: source)
        case .finalTranscript(let text):
            handleFinalTranscriptEvent(text, source: source)
        case .error(let message):
            handleErrorEvent(message)
        }
    }

    // MARK: - Event Handlers

    private func handleConnectedEvent() {
        cancelConnectTimeout()
        setRealtimeIndicatorConnected()
        if isConnectingRealtimeSession {
            startAudioCaptureAfterConnection()
            return
        }
        statusText = activeStatusText
    }

    private func handleDisconnectedEvent() {
        cancelConnectTimeout()
        if isConnectingRealtimeSession {
            abortConnectingSession(disconnectSocket: false)
            handleConnectFailure(
                status: "Failed to connect.",
                message: "Unable to establish realtime connection.",
                technicalDetails: lastError?.trimmed.isEmpty == false
                    ? lastError : nil
            )
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

    private func handlePartialTranscriptEvent(_ delta: String, source: ActiveClientSource) {
        guard acceptsRealtimeEvents else { return }
        let processedDelta = preprocessIncomingTranscriptChunk(delta)
        guard !processedDelta.isEmpty else { return }
        if source == .mlxAudio {
            handleMlxPartialTranscript(processedDelta)
            return
        }
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

    private func handleFinalTranscriptEvent(_ text: String, source: ActiveClientSource) {
        guard acceptsRealtimeEvents else { return }
        let processedText = preprocessIncomingTranscriptChunk(text)
        if source == .mlxAudio {
            handleMlxFinalTranscript(processedText)
            return
        }
        if isFinalizingStop {
            realtimeFinalizationLastActivityAt = Date()
        }

        let finalizedSegment = resolvedFinalizedSegment(from: processedText)
        let hadLiveDelta = !pendingSegmentText.trimmed.isEmpty
            || !livePartialText.trimmed.isEmpty
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

        if !hadLiveDelta, isLiveAutoPasteModeEnabled {
            textInsertion.enqueueRealtimeInsertion(finalizedSegment)
            if let accessibilityError = textInsertion.lastAccessibilityError {
                lastError = accessibilityError
            }
        }

        if isLiveAutoPasteModeEnabled, settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }
        refreshOverlayBufferSession()
    }

    private func handleErrorEvent(_ message: String) {
        if isConnectingRealtimeSession {
            abortConnectingSession()
            handleConnectFailure(
                status: "Failed to connect.",
                message: "Unable to establish realtime connection.",
                technicalDetails: message
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

    // MARK: - mlx-audio Transcript Handling

    func handleMlxPartialTranscript(_ delta: String) {
        let mergedHypothesis = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            delta.trimmed
        )
        guard !mergedHypothesis.isEmpty else { return }
        let insertionMode: MlxInsertionMode =
            isLiveAutoPasteModeEnabled ? .realtime : .none
        let result = mlxStabilizer.commitHypothesis(
            mergedHypothesis,
            isFinal: false,
            insertionMode: insertionMode
        )
        currentDictationEventText = mlxStabilizer.committedEventText
        pendingSegmentText = result.unstableTail
        livePartialText = result.unstableTail

        if isLiveAutoPasteModeEnabled,
            let accessibilityError = textInsertion.lastAccessibilityError
        {
            lastError = accessibilityError
        }
        statusText = isFinalizingStop ? "Finalizing..." : "Transcribing..."
        refreshOverlayBufferSession()
    }

    func handleMlxFinalTranscript(_ text: String) {
        let hypothesis = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            text.trimmed
        )
        guard !hypothesis.isEmpty else {
            livePartialText = ""
            pendingSegmentText = ""
            mlxStabilizer.resetSegment()
            return
        }

        let insertionMode: MlxInsertionMode
        if isLiveAutoPasteModeEnabled {
            insertionMode = isFinalizingStop ? .finalized : .realtime
        } else {
            insertionMode = .none
        }

        _ = mlxStabilizer.commitHypothesis(
            hypothesis,
            isFinal: true,
            insertionMode: insertionMode
        )
        currentDictationEventText = mlxStabilizer.committedEventText

        let finalizedDelta = mlxStabilizer.consumeCommittedSinceLastFinal().trimmed
        if !finalizedDelta.isEmpty {
            appendToTranscript(finalizedDelta)
        }

        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""
        mlxStabilizer.resetSegment()
        statusText = activeStatusText

        if isLiveAutoPasteModeEnabled, settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }
        refreshOverlayBufferSession()
    }

    // MARK: - Segment Promotion

    @discardableResult
    func promotePendingMlxTextToLatestSegment() -> String? {
        let promotion = mlxStabilizer.promotePendingText()
        currentDictationEventText = mlxStabilizer.committedEventText

        if !promotion.allCommitted.isEmpty {
            appendToTranscript(promotion.allCommitted)
        }

        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""
        mlxStabilizer.resetSegment()

        if isLiveAutoPasteModeEnabled, settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }

        return promotion.newlyPromotedTail
    }

    @discardableResult
    func promotePendingRealtimeTextToLatestSegment() -> String? {
        let pendingSegment = resolvedFinalizedSegment(from: "")
        guard !pendingSegment.isEmpty else { return nil }

        currentDictationEventText = TextMergingAlgorithms.appendToCurrentDictationEvent(
            segment: pendingSegment,
            existingText: currentDictationEventText
        )
        lastFinalSegment = currentDictationEventText

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

    func currentOverlayBufferedText() -> String {
        OverlayBufferTextAssembler.displayText(
            committedText: currentDictationEventText,
            pendingText: pendingSegmentText,
            fallbackPendingText: livePartialText
        )
    }
}
