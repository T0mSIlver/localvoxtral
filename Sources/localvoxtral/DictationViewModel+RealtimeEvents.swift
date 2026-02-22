import Foundation
import os

extension DictationViewModel {
    // MARK: - Realtime Event Routing

    func handle(event: RealtimeEvent, source: ActiveClientSource) {
        guard source == activeClientSource else { return }

        switch event {
        case .connected:
            cancelConnectTimeout()
            setRealtimeIndicatorConnected()
            if isConnectingRealtimeSession {
                startAudioCaptureAfterConnection()
                return
            }
            if isDictating {
                statusText = "Listening..."
            } else if isFinalizingStop {
                statusText = "Finalizing..."
            } else {
                statusText = "Ready"
            }

        case .disconnected:
            cancelConnectTimeout()
            if isConnectingRealtimeSession {
                abortConnectingSession(disconnectSocket: false)
                let failureMessage = (lastError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? (lastError ?? "Unable to establish realtime connection.")
                    : "Unable to establish realtime connection."
                handleConnectFailure(
                    status: "Failed to connect.",
                    message: "Unable to establish realtime connection.",
                    technicalDetails: failureMessage
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
            logConnectionFailure(message: message, technicalDetails: "Realtime websocket disconnected unexpectedly during active dictation.")
            markRecentConnectionFailureIndicator()

        case .status(let message):
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

            if normalized.contains("session") || normalized.contains("connected") || normalized.contains("disconnected") {
                statusText = "Listening..."
            } else {
                statusText = message
            }

        case .partialTranscript(let delta):
            guard acceptsRealtimeEvents, !delta.isEmpty else { return }
            if source == .mlxAudio {
                handleMlxPartialTranscript(delta)
                return
            }
            if isFinalizingStop {
                realtimeFinalizationLastActivityAt = Date()
            }

            pendingSegmentText.append(delta)
            livePartialText = pendingSegmentText
            if settings.autoPasteIntoInputFieldEnabled {
                textInsertion.enqueueRealtimeInsertion(delta)
                if let accessibilityError = textInsertion.lastAccessibilityError {
                    lastError = accessibilityError
                }
            }
            statusText = isFinalizingStop ? "Finalizing..." : "Transcribing..."

        case .finalTranscript(let text):
            guard acceptsRealtimeEvents else { return }
            if source == .mlxAudio {
                handleMlxFinalTranscript(text)
                return
            }
            if isFinalizingStop {
                realtimeFinalizationLastActivityAt = Date()
            }

            let finalizedSegment = resolvedFinalizedSegment(from: text)
            let hadLiveDelta = !pendingSegmentText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                || !livePartialText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            guard !finalizedSegment.isEmpty else {
                livePartialText = ""
                pendingSegmentText = ""
                return
            }

            if transcriptText.isEmpty {
                transcriptText = finalizedSegment
            } else {
                transcriptText += "\n" + finalizedSegment
            }

            currentDictationEventText = TextMergingAlgorithms.appendToCurrentDictationEvent(
                segment: finalizedSegment,
                existingText: currentDictationEventText
            )
            lastFinalSegment = currentDictationEventText
            livePartialText = ""
            pendingSegmentText = ""
            statusText = isDictating ? "Listening..." : (isFinalizingStop ? "Finalizing..." : "Ready")

            let shouldInsertFinal = !hadLiveDelta && settings.autoPasteIntoInputFieldEnabled
            if shouldInsertFinal {
                textInsertion.enqueueRealtimeInsertion(finalizedSegment)
                if let accessibilityError = textInsertion.lastAccessibilityError {
                    lastError = accessibilityError
                }
            }

            if settings.autoCopyEnabled {
                copyLatestSegment(updateStatus: false)
            }

        case .error(let message):
            let normalized = message.lowercased()
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
                if normalized.contains("websocket receive failed")
                    || normalized.contains("cancelled")
                    || normalized.contains("socket is not connected")
                {
                    statusText = "Ready"
                    return
                }

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
    }

    // MARK: - mlx-audio Transcript Handling

    func handleMlxPartialTranscript(_ delta: String) {
        let mergedHypothesis = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            delta.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !mergedHypothesis.isEmpty else { return }
        let insertionMode: MlxInsertionMode = settings.autoPasteIntoInputFieldEnabled ? .realtime : .none
        let result = mlxStabilizer.commitHypothesis(
            mergedHypothesis,
            isFinal: false,
            insertionMode: insertionMode
        )
        currentDictationEventText = mlxStabilizer.committedEventText
        pendingSegmentText = result.unstableTail
        livePartialText = result.unstableTail

        if settings.autoPasteIntoInputFieldEnabled, let accessibilityError = textInsertion.lastAccessibilityError {
            lastError = accessibilityError
        }
        statusText = isFinalizingStop ? "Finalizing..." : "Transcribing..."
    }

    func handleMlxFinalTranscript(_ text: String) {
        let hypothesis = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !hypothesis.isEmpty else {
            livePartialText = ""
            pendingSegmentText = ""
            mlxStabilizer.resetSegment()
            return
        }

        let insertionMode: MlxInsertionMode
        if settings.autoPasteIntoInputFieldEnabled {
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

        let finalizedDelta = mlxStabilizer.consumeCommittedSinceLastFinal()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalizedDelta.isEmpty {
            if transcriptText.isEmpty {
                transcriptText = finalizedDelta
            } else {
                transcriptText += "\n" + finalizedDelta
            }
        }

        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""
        mlxStabilizer.resetSegment()
        statusText = isDictating ? "Listening..." : (isFinalizingStop ? "Finalizing..." : "Ready")

        if settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }
    }

    // MARK: - Segment Promotion

    @discardableResult
    func promotePendingMlxTextToLatestSegment() -> String? {
        let promotion = mlxStabilizer.promotePendingText()
        currentDictationEventText = mlxStabilizer.committedEventText

        if !promotion.allCommitted.isEmpty {
            if transcriptText.isEmpty {
                transcriptText = promotion.allCommitted
            } else {
                transcriptText += "\n" + promotion.allCommitted
            }
        }

        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""
        mlxStabilizer.resetSegment()

        if settings.autoCopyEnabled {
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

        if settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }

        return pendingSegment
    }

    // MARK: - Finalized Segment Resolution

    func resolvedFinalizedSegment(from finalText: String) -> String {
        let finalizedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bufferedText = pendingSegmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBufferedText = livePartialText.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
