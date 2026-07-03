import AppKit
import Foundation
import os

extension DictationViewModel {
    // MARK: - Session Lifecycle

    // Session metadata lifecycle:
    // - Set: beginDictationSession() — captures values that should stay stable for
    //   the active session even if Settings are edited before commit finishes.
    // - Cleared: finishStoppedSession(), abortConnectingSession(), and early-return
    //   error paths in beginDictationSession() where no session was established.
    // All session exit paths MUST clear these fields to nil.

    @discardableResult
    func cancelPolishingForNewSessionIfNeeded() -> Bool {
        guard polishAndCommitTask != nil else { return false }
        debugLog("cancel in-flight polishing to start a new dictation session")
        polishAndCommitTask?.cancel()
        polishAndCommitTask = nil

        completeStoppedSessionCleanup(
            sessionMode: sessionOutputMode ?? settings.dictationOutputMode,
            overlayCommitOutcome: nil,
            shouldCommitOverlay: false
        )
        // Do not carry old overlay state into a freshly requested session.
        overlayBufferCoordinator.reset()
        return true
    }

    private func clearLatchedSessionMetadata() {
        sessionOutputMode = nil
        sessionStartedAt = nil
        sessionProvider = nil
        sessionModelName = nil
        sessionReplacementDictionary = nil
    }

    func beginDictationSession() {
        lastSocketErrorMessage = nil
        polishAndCommitTask?.cancel()
        polishAndCommitTask = nil
        stopFinalizationTask?.cancel()
        stopFinalizationTask = nil
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = nil
        cancelConnectTimeout()
        isFinalizingStop = false
        isConnectingRealtimeSession = false
        clearLatchedSessionMetadata()
        sessionOutputMode = settings.dictationOutputMode
        sessionStartedAt = Date()
        sessionReplacementDictionary = settings.replacementDictionaryEnabled
            ? appConfigStore.loadReplacementDictionary()
            : nil
        setRealtimeIndicatorIdle()

        let provider = settings.realtimeProvider
        guard let endpoint = settings.resolvedWebSocketURL(for: provider) else {
            handleConnectFailure(reason: .invalidEndpoint)
            clearLatchedSessionMetadata()
            return
        }

        if !selectedInputDeviceID.isEmpty,
           !availableInputDevices.contains(where: { $0.id == selectedInputDeviceID })
        {
            statusText = "Selected microphone unavailable."
            lastError = "Selected microphone is unavailable. Reconnect it or choose another input."
            clearLatchedSessionMetadata()
            return
        }

        let model = settings.effectiveModelName(for: provider)
        // Reset the realtime client from any prior session before reconnecting.
        realtimeAPIClient.disconnect()
        let preferredInputID = selectedInputDeviceID.isEmpty ? nil : selectedInputDeviceID
        sessionProvider = provider
        sessionModelName = model

        // Fail fast on Live Auto-Paste without Accessibility trust: transcribed
        // text would have nowhere to go. Refresh trust once (the user may have
        // just granted it), then warn + prompt before opening the socket. We do
        // NOT abort — the keyboard-event fallback can still type into some apps,
        // and the prompt's polling clears the warning once Accessibility lands.
        // The warning is surfaced both as the status line and the red error in
        // the popover, so it can't be missed before the user speaks.
        let accessibilityBlockedAtStart: Bool
        if isLiveAutoPasteModeEnabled, !textInsertion.isAccessibilityTrusted {
            textInsertion.refreshAccessibilityTrustState()
            accessibilityBlockedAtStart = !textInsertion.isAccessibilityTrusted
        } else {
            accessibilityBlockedAtStart = false
        }
        if accessibilityBlockedAtStart {
            statusText = StatusStrings.pasteBlockedByAccessibilityPermission
            lastError = Self.liveAutoPasteAccessibilityWarningMessage
            textInsertion.requestAccessibilityPermissionIfNeeded()
            debugLog("live auto-paste started without accessibility trust; surfacing warning")
        }

        // Capture the AX anchor now, while the user's text field still has focus.
        // By the time the WebSocket connects and startOverlayBufferSession() runs,
        // our app may have taken focus and the original AX element will be gone.
        preResolvedOverlayAnchor = isOverlayBufferModeEnabled
            ? overlayBufferCoordinator.resolveAnchorNow()
            : nil

        audioChunkBuffer.clear()
        livePartialText = ""
        pendingSegmentText = ""
        currentDictationEventText = ""
        firstChunkPreprocessor.reset()
        overlayBufferCoordinator.reset()
        realtimeFinalizationLastActivityAt = nil
        textInsertion.clearPendingText()
        textInsertion.resetDiagnostics()

        isConnectingRealtimeSession = true
        // Keep the Accessibility warning as the status line when it applies, so
        // the warning isn't clobbered by the generic "Connecting..." text.
        if !accessibilityBlockedAtStart {
            statusText = "Connecting to realtime backend..."
        }
        debugLog(
            "beginDictationSession endpoint=\(endpoint.absoluteString) model=\(model) input=\(preferredInputID ?? "default")"
        )

        do {
            try realtimeAPIClient.connect(configuration: .init(
                endpoint: endpoint,
                apiKey: settings.trimmedAPIKey,
                model: model
            ))
            scheduleConnectTimeout()
        } catch {
            abortConnectingSession(disconnectSocket: false)
            handleConnectFailure(reason: .connectThrew(rawError: error.localizedDescription))
            debugLog("beginDictationSession failed error=\(error.localizedDescription)")
        }
    }

    func startAudioCaptureAfterConnection() {
        let preferredInputID = selectedInputDeviceID.isEmpty ? nil : selectedInputDeviceID
        do {
            let chunkBuffer = audioChunkBuffer
            try microphone.start(preferredDeviceID: preferredInputID) { chunk in
                chunkBuffer.append(chunk)
            }

            isConnectingRealtimeSession = false
            isDictating = true
            escapeCancelHandler.start()
            statusText = "Listening..."
            restartAudioSendTask()
            restartCommitTask()
            if isLiveAutoPasteModeEnabled {
                textInsertion.restartInsertionRetryTask { [weak self] in
                    self?.acceptsRealtimeEvents ?? false
                }
            } else {
                textInsertion.stopInsertionRetryTask()
            }
            if isOverlayBufferModeEnabled {
                startOverlayBufferSession()
            } else {
                overlayBufferCoordinator.reset()
                configureLiveAutoPasteReplacementCorrectorForSession()
            }
            healthMonitor.start(microphone: microphone, callbacks: makeHealthMonitorCallbacks())
        } catch {
            statusText = "Failed to start dictation."
            lastError = error.localizedDescription
            isConnectingRealtimeSession = false
            isDictating = false
            escapeCancelHandler.stop()
            healthMonitor.stop()
            microphone.stop()
            realtimeAPIClient.disconnect()
            setRealtimeIndicatorIdle()
            Log.dictation.error("Failed to start microphone after realtime connect: \(error.localizedDescription, privacy: .public)")
            debugLog("startAudioCaptureAfterConnection failed error=\(error.localizedDescription)")
        }
    }

    func makeHealthMonitorCallbacks() -> AudioCaptureHealthMonitor.Callbacks {
        let chunkBuffer = audioChunkBuffer
        let mic = microphone
        return AudioCaptureHealthMonitor.Callbacks(
            refreshMicrophoneInputs: { [weak self] in
                self?.refreshMicrophoneInputs()
            },
            stopDictation: { [weak self] reason in
                self?.stopDictation(reason: reason)
            },
            isDictating: { [weak self] in
                self?.isDictating ?? false
            },
            selectedInputDeviceID: { [weak self] in
                self?.selectedInputDeviceID ?? ""
            },
            availableInputDevices: { [weak self] in
                self?.availableInputDevices ?? []
            },
            setStatus: { [weak self] status in
                self?.statusText = status
            },
            setError: { [weak self] error in
                self?.lastError = error
            },
            restartMicrophone: { preferredInputID in
                try mic.start(preferredDeviceID: preferredInputID) { chunk in
                    chunkBuffer.append(chunk)
                }
            }
        )
    }

    // MARK: - Audio Pipeline

    func restartCommitTask() {
        commitTask?.cancel()
        commitTask = nil

        let interval = min(1.0, max(0.1, settings.commitIntervalSeconds))
        let client = realtimeAPIClient
        guard client.supportsPeriodicCommit else { return }
        commitTask = Task(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                client.sendCommit(final: false)
            }
        }
    }

    func restartAudioSendTask() {
        audioSendTask?.cancel()

        let interval = TimingConstants.audioSendInterval
        let client = realtimeAPIClient
        let chunkBuffer = audioChunkBuffer
        let debugLoggingEnabled = debugLoggingEnabled
        audioSendTask = Task(priority: .utility) {
            var emptyBufferTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }

                let bufferedChunk = chunkBuffer.takeAll()
                guard !bufferedChunk.isEmpty else {
                    emptyBufferTicks += 1
                    if debugLoggingEnabled, emptyBufferTicks % 20 == 0 {
                        Log.dictation.debug("audio send loop has no buffered chunks")
                    }
                    continue
                }
                emptyBufferTicks = 0
                client.sendAudioChunk(bufferedChunk)
            }
        }
    }

    func flushBufferedAudio() {
        let chunk = audioChunkBuffer.takeAll()
        guard !chunk.isEmpty else { return }
        realtimeAPIClient.sendAudioChunk(chunk)
    }

    // MARK: - Stop Finalization

    func scheduleStopFinalization() {
        stopFinalizationTask?.cancel()
        stopFinalizationTask = Task { [weak self] in
            guard let self else { return }
            guard self.isFinalizingStop else { return }

            if !self.realtimeAPIClient.isConnected {
                self.debugLog("socket already disconnected before final commit; finishing stop")
                self.finishStoppedSession(promotePendingSegment: true)
                return
            }
            let startedAt = Date()
            self.realtimeFinalizationLastActivityAt = startedAt
            self.realtimeAPIClient.sendCommit(final: true)
            while self.isFinalizingStop {
                if !self.realtimeAPIClient.isConnected {
                    self.debugLog("socket disconnected during finalization; finishing stop")
                    self.finishStoppedSession(promotePendingSegment: true)
                    return
                }

                let now = Date()
                let elapsed = now.timeIntervalSince(startedAt)
                let lastActivity = self.realtimeFinalizationLastActivityAt ?? startedAt
                let inactivity = now.timeIntervalSince(lastActivity)

                if elapsed >= TimingConstants.stopFinalizationTimeout {
                    self.debugLog("stop finalization timeout (\(TimingConstants.stopFinalizationTimeout)s); forcing disconnect")
                    self.realtimeAPIClient.disconnect()
                    self.finishStoppedSession(promotePendingSegment: true)
                    return
                }

                if elapsed >= TimingConstants.finalizationMinimumOpen,
                   inactivity >= TimingConstants.finalizationInactivityThreshold
                {
                    self.debugLog(
                        "realtime finalization idle for \(String(format: "%.2f", inactivity))s; disconnecting"
                    )
                    self.realtimeAPIClient.disconnect()
                    self.finishStoppedSession(promotePendingSegment: true)
                    return
                }

                try? await Task.sleep(for: .seconds(TimingConstants.finalizationPollInterval))
            }
        }
    }

    func finishStoppedSession(promotePendingSegment: Bool) {
        guard !isCompletingStoppedSession else {
            debugLog("finishStoppedSession ignored; cleanup already in progress")
            return
        }
        isCompletingStoppedSession = true

        stopFinalizationTask?.cancel()
        stopFinalizationTask = nil
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = nil
        cancelConnectTimeout()

        let sessionMode = sessionOutputMode ?? settings.dictationOutputMode
        let shouldCommitOverlay = sessionMode == .overlayBuffer

        if promotePendingSegment, !wasCancelled {
            _ = promotePendingRealtimeTextToLatestSegment()
        }

        // Cancelled overlay — dismiss immediately, no commit
        if shouldCommitOverlay, wasCancelled {
            overlayBufferCoordinator.reset()
            completeStoppedSessionCleanup(
                sessionMode: sessionMode,
                overlayCommitOutcome: nil,
                shouldCommitOverlay: true
            )
            return
        }

        if shouldCommitOverlay, !wasCancelled {
            let polishingConfig = settings.llmPolishingConfiguration
            let shouldLoadReplacementDictionary =
                settings.replacementDictionaryEnabled || polishingConfig != nil
            let replacementDictionary: ReplacementDictionary
            if settings.replacementDictionaryEnabled,
               let sessionReplacementDictionary
            {
                replacementDictionary = sessionReplacementDictionary
            } else {
                replacementDictionary = shouldLoadReplacementDictionary
                    ? appConfigStore.loadReplacementDictionary()
                    : ReplacementDictionary(entries: [])
            }
            let replacementDictionaryPrompt = replacementDictionary.renderedPromptSection()
            let originalText = currentDictationEventText
            let workingText =
                settings.replacementDictionaryEnabled
                ? replacementDictionary.apply(to: originalText)
                : originalText
            let llmConfigurationFailure: (message: String, technicalDetails: String?)? =
                settings.llmPolishingEnabled && polishingConfig == nil
                ? (
                    "Set a valid LLM polishing endpoint URL in Settings.",
                    "Settings value could not be normalized to an HTTP endpoint URL."
                )
                : nil

            if currentDictationEventText != workingText {
                currentDictationEventText = workingText
            }
            refreshOverlayBufferSession()

            let capturedSessionStartedAt = sessionStartedAt ?? Date()
            let capturedProvider = sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue
            let capturedModel = sessionModelName ?? settings.effectiveModelName
            let capturedOutputMode = sessionMode.rawValue
            let capturedTargetBundleID = resolveTargetAppBundleID()
            if polishingConfig != nil {
                let promptTemplates = appConfigStore.loadLLMPromptTemplates()
                let polishingRequest = LLMPolishingRequest(
                    inputText: workingText,
                    systemPrompt: promptTemplates.systemContent,
                    userPrompts: promptTemplates.renderedUserPrompts(
                        inputText: workingText,
                        replacementDictionary: replacementDictionaryPrompt
                    )
                )

                statusText = StatusStrings.polishing
                debugLog("LLM polishing started for \(workingText.count) chars")

                polishAndCommitTask = Task { @MainActor [weak self] in
                    guard let self else { return }

                    var processedTextForPersistence: String? =
                        workingText != originalText ? workingText : nil
                    var polishingDuration: Double? = nil
                    var sessionStatus: DictationSessionStatus = .completed
                    var llmConnectionFailure: (message: String, technicalDetails: String?)?

                    if let config = polishingConfig, !workingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        do {
                            let result = try await self.llmPolishingService.polish(
                                request: polishingRequest,
                                configuration: config
                            )
                            processedTextForPersistence =
                                result.polishedText != originalText ? result.polishedText : nil
                            polishingDuration = result.durationSeconds

                            guard !Task.isCancelled else { return }

                            self.currentDictationEventText = result.polishedText
                            self.refreshOverlayBufferSession()
                            Log.polishing.info(
                                "LLM polishing succeeded in \(String(format: "%.2f", result.durationSeconds))s"
                            )
                        } catch {
                            guard !Task.isCancelled else { return }
                            sessionStatus = .llmFailed
                            if case .networkError(let details) = error as? LLMPolishingError {
                                llmConnectionFailure = (
                                    "Unable to connect to the configured LLM polishing endpoint.",
                                    self.llmPolishingConnectionTechnicalDetails(details)
                                )
                            }
                            Log.polishing.error(
                                "LLM polishing failed: \(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }

                    guard !Task.isCancelled else { return }

                    let overlayCommitOutcome = self.overlayBufferCoordinator.commitIfNeeded(
                        using: self.textInsertion,
                        autoCopyEnabled: self.settings.autoCopyEnabled
                    )
                    let commitSucceeded: Bool
                    if case .failed(let failureMessage) = overlayCommitOutcome {
                        commitSucceeded = false
                        self.lastError = failureMessage
                    } else {
                        commitSucceeded = true
                    }

                    self.completeStoppedSessionCleanup(
                        sessionMode: sessionMode,
                        overlayCommitOutcome: overlayCommitOutcome,
                        shouldCommitOverlay: true
                    )

                    self.saveSessionRecord(
                        startedAt: capturedSessionStartedAt,
                        rawText: originalText,
                        polishedText: processedTextForPersistence,
                        polishingDuration: polishingDuration,
                        provider: capturedProvider,
                        model: capturedModel,
                        outputMode: capturedOutputMode,
                        targetAppBundleID: capturedTargetBundleID,
                        status: sessionStatus,
                        commitSucceeded: commitSucceeded
                    )

                    if let llmConnectionFailure {
                        self.handleLLMPolishingConnectionFailure(
                            message: llmConnectionFailure.message,
                            technicalDetails: llmConnectionFailure.technicalDetails
                        )
                    }
                }
                return
            }

            // Non-polishing overlay commit path
            let overlayCommitOutcome = overlayBufferCoordinator.commitIfNeeded(
                using: textInsertion,
                autoCopyEnabled: settings.autoCopyEnabled
            )
            let commitSucceeded: Bool
            if case .failed(let failureMessage) = overlayCommitOutcome {
                commitSucceeded = false
                lastError = failureMessage
            } else {
                commitSucceeded = true
            }

            completeStoppedSessionCleanup(
                sessionMode: sessionMode,
                overlayCommitOutcome: overlayCommitOutcome,
                shouldCommitOverlay: true
            )

            saveSessionRecord(
                startedAt: capturedSessionStartedAt,
                rawText: originalText,
                polishedText: workingText != originalText ? workingText : nil,
                polishingDuration: nil,
                provider: capturedProvider,
                model: capturedModel,
                outputMode: capturedOutputMode,
                targetAppBundleID: capturedTargetBundleID,
                status: llmConfigurationFailure == nil ? .sttCompleted : .llmFailed,
                commitSucceeded: commitSucceeded
            )

            if let llmConfigurationFailure {
                handleLLMPolishingConnectionFailure(
                    message: llmConfigurationFailure.message,
                    technicalDetails: llmConfigurationFailure.technicalDetails
                )
            }
            return
        }

        // Non-overlay path (live auto-paste)
        let capturedSessionStartedAt = sessionStartedAt ?? Date()
        let capturedProvider = sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue
        let capturedModel = sessionModelName ?? settings.effectiveModelName
        let capturedOutputMode = sessionMode.rawValue
        textInsertion.flushFinalLiveReplacementCorrections()
        completeStoppedSessionCleanup(
            sessionMode: sessionMode,
            overlayCommitOutcome: nil,
            shouldCommitOverlay: false
        )

        saveSessionRecord(
            startedAt: capturedSessionStartedAt,
            rawText: currentDictationEventText,
            polishedText: nil,
            polishingDuration: nil,
            provider: capturedProvider,
            model: capturedModel,
            outputMode: capturedOutputMode,
            targetAppBundleID: nil,
            status: .sttCompleted,
            commitSucceeded: true
        )
    }

    func configureLiveAutoPasteReplacementCorrectorForSession() {
        guard isLiveAutoPasteModeEnabled else {
            textInsertion.endLiveReplacementSession()
            return
        }
        guard settings.replacementDictionaryEnabled else {
            textInsertion.endLiveReplacementSession()
            return
        }

        overlayBufferCoordinator.captureLiveCommitTargetAppPID()
        let dictionary = replacementDictionaryForCurrentSession()
        textInsertion.beginLiveReplacementSession(
            dictionary: dictionary,
            preferredAppPID: overlayBufferCoordinator.commitTargetAppPID
        )
    }

    private func completeStoppedSessionCleanup(
        sessionMode: DictationOutputMode,
        overlayCommitOutcome: OverlayBufferCommitOutcome?,
        shouldCommitOverlay: Bool
    ) {
        wasCancelled = false
        isFinalizingStop = false
        isConnectingRealtimeSession = false
        isCompletingStoppedSession = false
        realtimeFinalizationLastActivityAt = nil
        polishAndCommitTask = nil
        clearLatchedSessionMetadata()
        setRealtimeIndicatorIdle()
        livePartialText = ""
        pendingSegmentText = ""
        if case .failed = overlayCommitOutcome {
            statusText = "Insert failed."
        } else {
            statusText = "Ready"
        }

        textInsertion.stopInsertionRetryTask()
        textInsertion.logDiagnostics()
        textInsertion.endLiveReplacementSession()

        if sessionMode == .liveAutoPaste, textInsertion.hasPendingInsertionText {
            lastError = "Some realtime text could not be inserted into the focused app."
            textInsertion.clearPendingText()
        }

        let didOverlayCommitFail: Bool
        if case .failed = overlayCommitOutcome {
            didOverlayCommitFail = true
        } else {
            didOverlayCommitFail = false
        }

        if !shouldCommitOverlay || !didOverlayCommitFail {
            overlayBufferCoordinator.dismissAfterHold(
                minimumVisibility: TimingConstants.overlayFinalWordVisibilityMinimum
            )
        }

        if currentErrorToken == .websocketReceiveFailed {
            lastError = nil
        }
        firstChunkPreprocessor.reset()
    }

    func resolveTargetAppBundleID() -> String? {
        guard let pid = overlayBufferCoordinator.commitTargetAppPID else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private func saveSessionRecord(
        startedAt: Date,
        rawText: String,
        polishedText: String?,
        polishingDuration: Double?,
        provider: String,
        model: String,
        outputMode: String,
        targetAppBundleID: String?,
        status: DictationSessionStatus,
        commitSucceeded: Bool
    ) {
        let trimmedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawText.isEmpty else {
            // Intentionally skip empty sessions: they produce no useful transcript payload.
            Log.persistence.debug("Skipping persistence for empty dictation session")
            return
        }
        let record = DictationSessionRecord(
            startedAt: startedAt,
            finishedAt: Date(),
            rawText: rawText,
            polishedText: polishedText,
            polishingDurationSeconds: polishingDuration,
            provider: provider,
            model: model,
            outputMode: outputMode,
            targetAppBundleID: targetAppBundleID,
            status: status,
            commitSucceeded: commitSucceeded
        )
        debugSavedSessionRecordSink?(record)
        sessionStore?.save(record)
    }

    func replacementDictionaryForCurrentSession() -> ReplacementDictionary? {
        guard settings.replacementDictionaryEnabled else { return nil }
        if let sessionReplacementDictionary {
            return sessionReplacementDictionary
        }
        let dictionary = appConfigStore.loadReplacementDictionary()
        sessionReplacementDictionary = dictionary
        return dictionary
    }

    // MARK: - Connect Timeout

    func scheduleConnectTimeout() {
        cancelConnectTimeout()
        let timeout = TimingConstants.connectTimeout
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, self.isConnectingRealtimeSession else { return }

            abortConnectingSession()
            handleConnectFailure(reason: .timedOut(timeoutSeconds: timeout))
        }
    }

    func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    func abortConnectingSession(disconnectSocket: Bool = true) {
        cancelConnectTimeout()
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = nil
        clearPushToTalkShortcutSessionAttempt()
        isConnectingRealtimeSession = false
        isDictating = false
        // An aborted connect never reaches stopped-session cleanup, so the
        // cancellation flag must be cleared here or it leaks into the next
        // session and silently skips its overlay commit.
        wasCancelled = false
        escapeCancelHandler.stop()
        isAwaitingMicrophonePermission = false
        isCompletingStoppedSession = false
        polishAndCommitTask = nil
        clearLatchedSessionMetadata()
        microphone.stop()
        realtimeFinalizationLastActivityAt = nil
        firstChunkPreprocessor.reset()
        textInsertion.endLiveReplacementSession()
        overlayBufferCoordinator.reset()
        if disconnectSocket {
            realtimeAPIClient.disconnect()
        }
        healthMonitor.stop()
    }

    // MARK: - Indicator State

    func setRealtimeIndicatorIdle() {
        recentFailureResetTask?.cancel()
        recentFailureResetTask = nil
        realtimeSessionIndicatorState = .idle
    }

    func setRealtimeIndicatorConnected() {
        recentFailureResetTask?.cancel()
        recentFailureResetTask = nil
        realtimeSessionIndicatorState = .connected
    }

    func markRecentConnectionFailureIndicator() {
        recentFailureResetTask?.cancel()
        realtimeSessionIndicatorState = .recentFailure
        let indicatorDuration = TimingConstants.recentFailureIndicatorDuration
        recentFailureResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(indicatorDuration))
            guard let self else { return }
            guard self.realtimeSessionIndicatorState == .recentFailure else { return }
            guard !self.isConnectingRealtimeSession, !self.isDictating, !self.isFinalizingStop else { return }
            self.realtimeSessionIndicatorState = .idle
            self.recentFailureResetTask = nil
        }
    }

    // MARK: - Connection Failure

    /// Call-site context for a realtime backend connection failure. Each case
    /// carries just enough information for `handleConnectFailure(reason:)` to
    /// classify the failure and build a clear, endpoint-naming message via
    /// `RealtimeConnectionFailureClassifier`.
    enum RealtimeConnectFailureReason: Sendable {
        /// The configured endpoint could not be resolved to a ws/wss URL.
        case invalidEndpoint
        /// `RealtimeClient.connect(_:)` threw synchronously.
        case connectThrew(rawError: String)
        /// The connect timeout fired before the socket opened.
        case timedOut(timeoutSeconds: TimeInterval)
        /// The socket emitted an `.error`/`.disconnected` event while connecting.
        case socketError(message: String?)
        /// The system network path was lost while opening the socket.
        case networkLost
    }

    func handleConnectFailure(reason: RealtimeConnectFailureReason) {
        let endpointDescription = sanitizedRealtimeEndpointForMessage()

        let kind: RealtimeConnectionFailureKind
        var timeoutSeconds: TimeInterval? = nil
        var rawError: String? = nil

        switch reason {
        case .invalidEndpoint:
            kind = .invalidEndpoint

        case .connectThrew(let errorText):
            kind = classifyConnectError(errorText)
            rawError = errorText.trimmed.isEmpty ? nil : errorText

        case .timedOut(let seconds):
            kind = .timedOut
            timeoutSeconds = seconds
            rawError = connectTimeoutTechnicalDetails(timeoutSeconds: seconds)

        case .socketError(let message):
            kind = RealtimeConnectionFailureClassifier.classify(socketErrorMessage: message)
            if let message, !message.trimmed.isEmpty {
                rawError = message
            }
        case .networkLost:
            kind = .networkLost
        }

        let description = RealtimeConnectionFailureClassifier.describe(
            kind: kind,
            endpointDescription: endpointDescription,
            timeoutSeconds: timeoutSeconds,
            rawError: rawError
        )

        statusText = description.status
        // Surface the actionable, endpoint-naming message as the primary error so
        // it is visible in the popover; keep the raw system error for logs/alert.
        lastError = description.message
        #if DEBUG
        debugLastConnectFailureTechnicalDetails = description.technicalDetails
        #endif
        logConnectionFailure(
            message: description.message,
            technicalDetails: description.technicalDetails
        )
        markRecentConnectionFailureIndicator()
        presentConnectionFailureAlert(
            message: description.message,
            technicalDetails: description.technicalDetails
        )
    }

    private func classifyConnectError(_ rawError: String) -> RealtimeConnectionFailureKind {
        let lowercased = rawError.lowercased()
        if lowercased.contains("must use")
            || lowercased.contains("ws://")
            || lowercased.contains("wss://")
            || lowercased.contains("endpoint must")
        {
            return .invalidEndpoint
        }
        return RealtimeConnectionFailureClassifier.classify(socketErrorMessage: rawError)
    }

    func handleLLMPolishingConnectionFailure(message: String, technicalDetails: String? = nil) {
        let trimmedMessage = message.trimmed
        let resolvedMessage =
            trimmedMessage.isEmpty
            ? "Unable to establish LLM polishing connection."
            : trimmedMessage
        let resolvedDetails = normalizedFailureDetails(technicalDetails)

        statusText = "LLM polishing failed."
        lastError = resolvedDetails ?? resolvedMessage
        logLLMPolishingConnectionFailure(
            message: resolvedMessage,
            technicalDetails: resolvedDetails
        )
        markRecentConnectionFailureIndicator()
        presentConnectionFailureAlert(
            title: "LLM Polishing Connection Failed",
            message: resolvedMessage
        )
    }

    func presentConnectionFailureAlert(
        title: String = "Realtime Connection Failed",
        message: String,
        technicalDetails: String? = nil
    ) {
        guard !message.isEmpty else { return }
        guard !isShowingConnectionFailureAlert else { return }

        isShowingConnectionFailureAlert = true
        defer { isShowingConnectionFailureAlert = false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        // Show the actionable message first; append the raw system error on a new
        // line when present so a wrong port or NSError code is visible at a glance.
        if let technicalDetails, !technicalDetails.trimmed.isEmpty,
           technicalDetails.trimmed != message.trimmed
        {
            alert.informativeText = "\(message)\n\n\(technicalDetails)"
        } else {
            alert.informativeText = message
        }
        if let appIcon = NSApplication.shared.applicationIconImage.copy() as? NSImage {
            appIcon.size = NSSize(width: 20, height: 20)
            alert.icon = appIcon
        }

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Console")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            openSystemConsole()
        }
    }

    func logConnectionFailure(message: String, technicalDetails: String?) {
        let provider = settings.realtimeProvider.displayName
        let endpoint = sanitizedRealtimeEndpointForLogging()
        if let technicalDetails {
            Log.dictation.error(
                "Realtime connection failure [provider: \(provider, privacy: .public), endpoint: \(endpoint, privacy: .public)] \(message, privacy: .public) details: \(technicalDetails, privacy: .public)"
            )
        } else {
            Log.dictation.error(
                "Realtime connection failure [provider: \(provider, privacy: .public), endpoint: \(endpoint, privacy: .public)] \(message, privacy: .public)"
            )
        }
    }

    func logLLMPolishingConnectionFailure(message: String, technicalDetails: String?) {
        let endpoint = sanitizedLLMPolishingEndpointForLogging()
        if let technicalDetails {
            Log.polishing.error(
                "LLM polishing connection failure [endpoint: \(endpoint, privacy: .public)] \(message, privacy: .public) details: \(technicalDetails, privacy: .public)"
            )
        } else {
            Log.polishing.error(
                "LLM polishing connection failure [endpoint: \(endpoint, privacy: .public)] \(message, privacy: .public)"
            )
        }
    }

    // MARK: - Helpers

    private func openSystemConsole() {
        guard let consoleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            return
        }
        _ = NSWorkspace.shared.open(consoleURL)
    }

    /// Strips credentials, query, and fragment from a URL for safe logging.
    private func sanitizedURLForLogging(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private func sanitizedRealtimeEndpointForLogging() -> String {
        guard let endpoint = settings.resolvedWebSocketURL(for: settings.realtimeProvider) else {
            return "<invalid endpoint>"
        }
        return sanitizedURLForLogging(endpoint)
    }

    /// Sanitized resolved endpoint (scheme + host + port + path) for inclusion in
    /// user-facing failure messages. Reuses the logging sanitizer so the message
    /// and the log line always agree on what was attempted.
    private func sanitizedRealtimeEndpointForMessage() -> String {
        sanitizedRealtimeEndpointForLogging()
    }

    private func sanitizedLLMPolishingEndpointForLogging() -> String {
        let endpointText = settings.llmPolishingEndpointURL.trimmed
        guard !endpointText.isEmpty,
              let endpoint = URL(string: endpointText)
        else {
            return "<invalid endpoint>"
        }
        return sanitizedURLForLogging(endpoint)
    }

    private func normalizedFailureDetails(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    private func connectTimeoutTechnicalDetails(timeoutSeconds: TimeInterval) -> String {
        let endpoint = sanitizedRealtimeEndpointForLogging()
        return "No connection response received in \(Int(timeoutSeconds)) seconds for endpoint \(endpoint)."
    }

    private func llmPolishingConnectionTechnicalDetails(_ details: String) -> String {
        let endpoint = sanitizedLLMPolishingEndpointForLogging()
        let normalizedDetails = details.trimmed
        if normalizedDetails.isEmpty {
            return "Unable to connect to endpoint \(endpoint)."
        }
        return "\(normalizedDetails) [endpoint: \(endpoint)]"
    }

    func startStopFinalizationWatchdog() {
        finalizationWatchdogTask?.cancel()
        let timeout: TimeInterval = TimingConstants.stopFinalizationTimeout + 2.0

        finalizationWatchdogTask = Task { [weak self] in
            let startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TimingConstants.finalizationPollInterval))
                guard let self else { return }
                guard self.isFinalizingStop else { return }

                if !self.realtimeAPIClient.isConnected {
                    self.debugLog("watchdog observed disconnected socket during finalization; finishing stop")
                    self.finishStoppedSession(promotePendingSegment: true)
                    return
                }

                if Date().timeIntervalSince(startedAt) >= timeout {
                    self.debugLog("finalization watchdog fired after \(timeout)s; forcing stop cleanup")
                    self.realtimeAPIClient.disconnect()
                    self.finishStoppedSession(promotePendingSegment: true)
                    return
                }
            }
        }
    }

    // MARK: - Overlay Buffer

    private func startOverlayBufferSession() {
        let anchor = preResolvedOverlayAnchor
        preResolvedOverlayAnchor = nil
        overlayBufferCoordinator.startSession(preResolvedAnchor: anchor)
    }

    func beginOverlayFinalization() {
        guard isOverlayBufferModeEnabled else { return }
        overlayBufferCoordinator.beginFinalizing(
            displayBufferText: currentOverlayDisplayText(),
            commitBufferText: currentOverlayCommitText()
        )
    }

    func refreshOverlayBufferSession() {
        guard isOverlayBufferModeEnabled else { return }
        overlayBufferCoordinator.refresh(
            displayBufferText: currentOverlayDisplayText(),
            commitBufferText: currentOverlayCommitText()
        )
    }
}
