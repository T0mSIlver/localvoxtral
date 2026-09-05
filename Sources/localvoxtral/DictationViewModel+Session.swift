import AppKit
import Foundation
import Synchronization
import os

extension DictationViewModel {
    // MARK: - Session Lifecycle

    // Session metadata lifecycle:
    // - Set: beginDictationSession(outputMode:) — captures values that should
    //   stay stable for the active session even if Settings are edited before commit finishes.
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

    func clearLatchedSessionMetadata() {
        sessionOutputMode = nil
        sessionStartedAt = nil
        sessionProvider = nil
        sessionModelName = nil
        sessionReplacementDictionary = nil
    }

    /// Live Auto-Paste preflight for Secure Keyboard Entry: a live session
    /// whose every synthetic keystroke would be swallowed SILENTLY (posting
    /// reports success, delivery never happens) must not start — and must be
    /// refused BEFORE managed-backend startup, or a cold backend would run a
    /// lengthy install/download for a doomed session. Fires the refuse UX
    /// (sound + menu bar icon + popover line, from a fresh verdict capture),
    /// resets any overlay panel a prior failed commit intentionally left
    /// visible, and returns true when the start was refused. Overlay Buffer
    /// sessions are never refused: their pipeline still produces text and the
    /// commit falls back to the clipboard (#89 split behavior).
    func refuseLiveStartForSecureInputIfNeeded(
        outputMode requestedOutputMode: DictationOutputMode
    ) -> Bool {
        guard requestedOutputMode == .liveAutoPaste,
              TerminalTargetDetector.isSecureKeyboardEntryEnabled()
        else { return false }
        captureSessionTargetVerdict()
        applyPreCapturedSessionTargetVerdict()
        statusText = StatusStrings.liveDictationBlockedBySecureInput
        overlayBufferCoordinator.reset()
        Log.target.warning(
            "live dictation start refused: Secure Keyboard Entry is enabled"
        )
        clearLatchedSessionMetadata()
        return true
    }

    func beginDictationAfterManagedBackendIfNeeded(outputMode: DictationOutputMode? = nil) {
        let requestedOutputMode = outputMode ?? settings.dictationOutputMode
        if refuseLiveStartForSecureInputIfNeeded(outputMode: requestedOutputMode) {
            return
        }
        let needsManagedDictation = settings.dictationBackendMode == .managedLocal
        let needsManagedPolishing = isManagedPolishingRequired(outputMode: requestedOutputMode)

        guard needsManagedDictation || needsManagedPolishing else {
            isConnectingRealtimeSession = true
            managedStartupTask?.cancel()
            let startupTaskID = UUID()
            managedStartupTaskID = startupTaskID
            managedStartupTask = Task { @MainActor [weak self, startupTaskID] in
                guard let self else { return }
                defer {
                    if self.managedStartupTaskID == startupTaskID {
                        self.managedStartupTask = nil
                        self.managedStartupTaskID = nil
                    }
                }
                // Same staleness pre-check as the managed path below: a start
                // that was cancelled or superseded before this task ran must
                // not enter beginDictationSession at all — its cleanup would
                // otherwise run against the successor's freshly-latched state.
                guard !Task.isCancelled, self.managedStartupTaskID == startupTaskID
                else { return }
                await self.beginDictationSession(outputMode: outputMode)
            }
            return
        }

        isConnectingRealtimeSession = true
        statusText = managedBackendStartupStatusText(
            dictation: needsManagedDictation,
            polishing: needsManagedPolishing
        )

        managedStartupTask?.cancel()
        let startupTaskID = UUID()
        managedStartupTaskID = startupTaskID
        managedStartupTask = Task { @MainActor [weak self, startupTaskID] in
            guard let self else { return }
            let statusUpdates = self.backendManager.statusUpdates
            let statusMirrorTask = Task { @MainActor [weak self, startupTaskID] in
                guard let self else { return }
                for await _ in statusUpdates {
                    if Task.isCancelled || self.managedStartupTaskID != startupTaskID {
                        return
                    }
                    defer { self.debugManagedStatusMirrorEventSink?() }
                    guard (!needsManagedDictation || self.settings.dictationBackendMode == .managedLocal),
                          (!needsManagedPolishing
                              || (self.settings.llmPolishingEnabled
                                  && self.settings.polishingBackendMode == .managedLocal)),
                          self.isConnectingRealtimeSession
                    else { continue }
                    self.statusText = self.managedBackendStartupStatusText(
                        dictation: needsManagedDictation,
                        polishing: needsManagedPolishing
                    )
                }
            }
            await Task.yield()
            defer {
                statusMirrorTask.cancel()
                if self.managedStartupTaskID == startupTaskID {
                    self.managedStartupTask = nil
                    self.managedStartupTaskID = nil
                }
            }
            do {
                try await self.backendManager.ensureReady(
                    dictation: needsManagedDictation,
                    polishing: needsManagedPolishing
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.abortConnectingSession()
                self.handleManagedBackendStartupFailure(error)
                return
            }

            guard !Task.isCancelled,
                  (!needsManagedDictation || self.settings.dictationBackendMode == .managedLocal),
                  (!needsManagedPolishing
                      || (self.settings.llmPolishingEnabled
                          && self.settings.polishingBackendMode == .managedLocal)),
                  self.isConnectingRealtimeSession
            else { return }
            await self.beginDictationSession(outputMode: outputMode)
            // beginDictationSession re-checks secure input and may refuse
            // HERE — long after the initiating gesture ended (a toggle tap
            // ends immediately; a hold may release while the backend boots).
            // With no gesture-end event left, the refusal signals would
            // wedge (Codex finding, round 8). Mirror the refused-tap
            // contract: the sound fired and the popover line stays; the
            // icon and "Blocked" status end with the attempt.
            if !self.isDictationAttemptGestureActive {
                self.clearSecureInputRefusalSignalsIfAttemptEnded()
            }
        }
    }

    func cancelManagedStartupTask() {
        // Cancelling the caller also asks BackendManager to abort its in-flight
        // startup, including any child model downloader process.
        managedStartupTask?.cancel()
        managedStartupTask = nil
        managedStartupTaskID = nil
    }

    private func managedBackendStartupStatusText(dictation: Bool, polishing: Bool) -> String {
        if dictation, case .preparingModel(let progress) = backendManager.speechdStatus {
            return modelDownloadStartupText(kind: "dictation", progress: progress)
        }
        if polishing, case .preparingModel(let progress) = backendManager.polishdStatus {
            return modelDownloadStartupText(kind: "polishing", progress: progress)
        }
        if !dictation, polishing {
            return "Starting polishing backend..."
        }
        return "Starting dictation backend..."
    }

    private func modelDownloadStartupText(kind: String, progress: ModelDownloadProgress) -> String {
        guard let fraction = progress.fraction else {
            // No byte total yet: could be a warm-cache no-op check.
            return "Preparing \(kind) model..."
        }
        return "Downloading \(kind) model (\(Int((fraction * 100).rounded()))%)..."
    }

    private func handleManagedBackendStartupFailure(_ error: Error) {
        let summary = error.localizedDescription.trimmed.isEmpty
            ? String(describing: error)
            : error.localizedDescription
        let technicalDetails: String?
        let popoverError: String
        if let managedError = error as? ManagedBackendManagerError {
            technicalDetails = normalizedFailureDetails(managedError.technicalDetails)
            popoverError = "\(managedError.backendName) failed to start."
        } else {
            technicalDetails = summary
            popoverError = "Managed backend failed to start."
        }
        let message = "Unable to start the managed backend: \(summary)"
        statusText = "Managed backend failed."
        // lastError renders in the menu-bar popover, which never shows long
        // text (AGENTS.md); the full story goes to the alert and the log.
        lastError = popoverError
        #if DEBUG
        debugLastConnectFailureTechnicalDetails = technicalDetails
        #endif
        logConnectionFailure(message: message, technicalDetails: technicalDetails)
        markRecentConnectionFailureIndicator()
        presentConnectionFailureAlert(
            title: "Managed Backend Failed",
            message: message,
            technicalDetails: technicalDetails
        )
    }

    func beginDictationSession(outputMode: DictationOutputMode? = nil) async {
        lastSocketErrorMessage = nil
        // A new session starts: retire any prior "Copy raw transcript"
        // affordance so it never references a stale, unrelated transcript.
        lastPolishChangedRawTranscript = nil
        polishAndCommitTask?.cancel()
        polishAndCommitTask = nil
        stopFinalizationTask?.cancel()
        stopFinalizationTask = nil
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = nil
        cancelConnectTimeout()
        isFinalizingStop = false
        isConnectingRealtimeSession = false
        // Every attempt starts with a fresh secure-input sample: a stale
        // `true` from a previously refused start would keep the warning icon
        // lit through an attempt that exits early for an unrelated reason
        // (invalid endpoint, missing mic) and mask that failure (Codex
        // review finding on #90). The refuse path / verdict apply below
        // re-set it from the fresh sample.
        sessionSecureInputActive = false
        // Same rule for the join badge, and it matters more: a stale `.joined`
        // from the previous dictation would tell the user THIS one is grounded
        // in a session it never resolved. An attempt that exits before the
        // capture runs (invalid endpoint, missing mic) must show nothing.
        sessionClaudeJoinBadge = .hidden
        let requestedOutputMode = outputMode ?? settings.dictationOutputMode
        clearLatchedSessionMetadata()
        sessionOutputMode = requestedOutputMode
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

        // Same timing rationale as the anchor: sample the terminal-like
        // verdict and Secure Keyboard Entry state while the app the user
        // started dictation in is still frontmost, not after connect.
        // Re-checked here as well as at the managed-backend entry: secure
        // input may have turned ON while a cold backend was booting, and
        // direct callers skip that entry point entirely.
        if refuseLiveStartForSecureInputIfNeeded(outputMode: requestedOutputMode) {
            return
        }
        captureSessionTargetVerdict()
        // Same timing rationale again, and the last chance to take it: the
        // overlay takes focus once the socket connects, and screen context must
        // record what the user could see as they chose their words.
        let ownerTaskID = managedStartupTaskID
        isConnectingRealtimeSession = true
        await captureTerminalScreenContextForSession()
        // Both spawn paths register their managedStartupTaskID before this
        // method runs, so a changed (non-nil) ID means a NEWER session start
        // owns the shared capture/metadata now — a cancelled predecessor must
        // not wipe the successor's state, and must not proceed either. A nil
        // ID means the canceller merely cleared the slot: cleanup is ours, and
        // resetting the connecting flag here also heals any cancel path that
        // never called abortConnectingSession.
        let ownsSharedSessionState =
            managedStartupTaskID == ownerTaskID || managedStartupTaskID == nil
        guard !Task.isCancelled, isConnectingRealtimeSession, ownsSharedSessionState else {
            if ownsSharedSessionState {
                discardTerminalScreenCapture()
                clearLatchedSessionMetadata()
                isConnectingRealtimeSession = false
            }
            return
        }
        refreshInsertionScalarTracingForSession()

        audioChunkBuffer.clear()
        livePartialText = ""
        pendingSegmentText = ""
        currentDictationEventText = ""
        firstChunkPreprocessor.reset()
        overlayBufferCoordinator.reset()
        realtimeFinalizationLastActivityAt = nil
        textInsertion.clearPendingText()
        textInsertion.resetDiagnostics()

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
            try microphone.start(
                preferredDeviceID: preferredInputID,
                preferredInputChannel: selectedInputChannel
            ) { chunk in
                chunkBuffer.append(chunk)
            }

            isConnectingRealtimeSession = false
            isDictating = true
            escapeCancelHandler.start()
            applyPreCapturedSessionTargetVerdict()
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
            restartMicrophone: { [weak self] preferredInputID in
                try mic.start(
                    preferredDeviceID: preferredInputID,
                    preferredInputChannel: self?.selectedInputChannel ?? 0
                ) { chunk in
                    chunkBuffer.append(chunk)
                }
            }
        )
    }

    // MARK: - Audio Pipeline

    func restartCommitTask() {
        commitTask?.cancel()
        commitTask = nil

        let interval = TimingConstants.commitInterval
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
            let replacementAppliedText =
                settings.replacementDictionaryEnabled
                ? replacementDictionary.apply(to: originalText)
                : originalText
            // Spoken clipboard-paste macro (Overlay Buffer only): after the
            // replacement dictionary and BEFORE the polish request is built,
            // swap each spoken marker for the env-var-shaped placeholder and
            // read the clipboard once. The placeholder — not the payload —
            // flows through polish and persistence. Both profiles enforce its
            // occurrence count before the real payload is substituted at
            // commit. No marker or setting off: a no-op that never touches the
            // pasteboard.
            let clipboardMacro = applyClipboardPayloadMacroIfEnabled(to: replacementAppliedText)
            let workingText = clipboardMacro.placeholderText
            let clipboardPayload = clipboardMacro.payload
            let payloadProvenanceSummary = clipboardMacro.summary
            let llmConfigurationFailure: (message: String, technicalDetails: String?)? =
                settings.llmPolishingEnabled && polishingConfig == nil
                ? (
                    "Set a valid LLM polishing endpoint URL in Settings.",
                    "Settings value could not be normalized to an HTTP endpoint URL."
                )
                : nil

            // Display the payload-substituted text (placeholder never shown to
            // the user); with no macro this is exactly `workingText`.
            let displayWorkingText = clipboardPayloadSubstituted(
                workingText, payload: clipboardPayload
            )
            if currentDictationEventText != displayWorkingText {
                currentDictationEventText = displayWorkingText
            }
            refreshOverlayBufferSession()

            let capturedSessionStartedAt = sessionStartedAt ?? Date()
            let capturedProvider = sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue
            let capturedModel = sessionModelName ?? settings.effectiveModelName
            let capturedOutputMode = sessionMode.rawValue
            let capturedTargetBundleID = resolveTargetAppBundleID()
            if polishingConfig != nil {
                let polishProfile = selectedPolishProfile(
                    forTargetBundleID: capturedTargetBundleID
                )
                Log.polishing.info(
                    "Polish profile: \(polishProfile.rawValue, privacy: .public)"
                )
                let capturedPolishProfile = polishProfile.rawValue
                let promptTemplates = appConfigStore.loadLLMPromptTemplates(profile: polishProfile)

                statusText = StatusStrings.polishing
                debugLog("LLM polishing started for \(workingText.count) chars")

                // Opt-in clipboard grounding is read HERE, pre-Task, right next
                // to the payload-macro clipboard read above, so both features
                // observe the SAME pasteboard state — the repo-vocabulary await
                // inside the Task can take up to ~2 s, and a copy landing during
                // that window must not make the context ground against different
                // text than the payload macro substitutes. When the setting is
                // off OR the polishing endpoint is not permitted (loopback-only
                // without the trusted-endpoint opt-in), the pasteboard
                // is never read (privacy).
                let capturedClipboardContext: PolishClipboardContext?
                let capturedScreenDecision: TerminalScreenContextDecision
                let capturedClaudeJoin: ClaudeSessionJoin?
                let capturedSocketPaneStart: SocketPaneScreenCapture?
                if let endpointURL = polishingConfig?.endpointURL {
                    capturedClipboardContext = polishClipboardContextIfEnabled(
                        endpointURL: endpointURL
                    )
                    // Reconciled HERE, pre-Task, for the same reason as the
                    // clipboard read above: the stop-time re-read must sample
                    // the screen at commit, not after the repo-vocabulary await
                    // has let ~2 s of agent output scroll past — which would
                    // report every session as mutated.
                    capturedScreenDecision = terminalScreenContextDecision(
                        endpointURL: endpointURL
                    )
                    // AFTER the screen decision, never before: that call is what
                    // asks the authorizer about the join, and consuming it first
                    // would clear it out from under the question and silently
                    // withdraw every raw screen attachment.
                    capturedClaudeJoin = consumeClaudeSessionJoin()
                    capturedSocketPaneStart = consumeSocketPaneStartCapture()
                } else {
                    capturedClipboardContext = nil
                    capturedScreenDecision = .drop(reason: .noStartCapture)
                    capturedClaudeJoin = nil
                    capturedSocketPaneStart = nil
                    // No endpoint: nothing to ground for, and neither the
                    // capture nor the join must survive into a later session's
                    // reconciliation. Nothing will read this join's remote
                    // herdr tunnel either, so it goes now rather than at the
                    // handle's deinit.
                    terminalScreenStartCapture = nil
                    claudeSessionJoin = nil
                    socketPaneStartCapture = nil
                    closeRemoteHerdrForwards()
                }

                // Repo vocabulary rides in the `{{replacement_dictionary}}`
                // slot; a user template without that placeholder (removing it is
                // explicitly supported) silently drops the section in
                // renderTemplate, so the whole vocabulary path — AX read, git
                // subprocess, provenance — is skipped up front when the ACTIVE
                // template can't carry it.
                let templateCarriesDictionarySlot =
                    promptTemplates.supportsReplacementDictionary
                // A repo match also votes against every other grounding source.
                // Even without a render slot, keep that vote when another source
                // can pre-apply an exact spelling; otherwise a contested span can
                // be edited unopposed. With no slot and no independent source,
                // the repo result has no consumer and the expensive pipeline is
                // skipped entirely.
                let needsRepoGroundingForConflictSafety =
                    capturedClipboardContext != nil
                    || capturedScreenDecision.vocabularyGroundingText != nil
                    || capturedClaudeJoin != nil

                polishAndCommitTask = Task { @MainActor [weak self] in
                    guard let self else { return }

                    // A herdr- or cmux-joined dictation swaps the AX screen
                    // decision for the JOINED pane's clean per-pane socket
                    // read. FIRST await in the Task, before the
                    // repo-vocabulary hop, for the same reason the AX
                    // reconcile runs pre-Task: the stop re-read must sample
                    // the pane at commit, not after ~2 s of agent output has
                    // scrolled past. Everything downstream (render demand,
                    // vocab grounding, the rendered block, provenance) reads
                    // this decision, so the swap is complete or not at all —
                    // on any pane-read failure it IS `capturedScreenDecision`,
                    // which for these joins is vocabulary-only at best (the
                    // authorizer still refuses raw AX attachment).
                    var screenDecision = capturedScreenDecision
                    if capturedSocketPaneStart != nil,
                       let endpointURL = polishingConfig?.endpointURL {
                        screenDecision = await SocketPaneScreenContext.reconcileAtStop(
                            start: capturedSocketPaneStart,
                            join: capturedClaudeJoin,
                            resolver: self.claudeSessionJoinResolver,
                            fallback: capturedScreenDecision,
                            settingEnabled: self.settings.terminalScreenContextEnabled,
                            endpointURL: endpointURL,
                            isAccessibilityTrusted: self.textInsertion.isAccessibilityTrusted,
                            trustedEndpointEnabled:
                                self.settings.polishContextTrustedEndpointEnabled
                        )
                    }
                    // The stop-side pane read above was the LAST reader of a
                    // remote herdr join's `ssh -L`; everything downstream works
                    // from text already in hand. Closed through the view model,
                    // which OWNS the handle — the join was consumed pre-Task,
                    // so closing "the join's" tunnel here would leave the owner
                    // holding a closed handle it still had to forget.
                    self.closeRemoteHerdrForwards()

                    // The polish request is assembled HERE, inside the Task, so
                    // the opt-in repo-vocabulary indexing — whose git subprocess
                    // runs OFF the main actor with a 2 s timeout — can complete
                    // before the request is built without stalling the commit. On
                    // timeout / no repo / feature off it is a fast no-op and the
                    // request is byte-identical to the no-vocabulary path.
                    var replacementDictionarySection = replacementDictionaryPrompt
                    var repoVocabularyOutcome = RepoVocabularyMatcher.GroundingOutcome.empty
                    if (templateCarriesDictionarySlot || needsRepoGroundingForConflictSafety),
                       let endpointURL = polishingConfig?.endpointURL,
                       let outcome = await self.repoVocabularyGroundingIfEnabled(
                           endpointURL: endpointURL,
                           transcript: workingText
                       )
                    {
                        repoVocabularyOutcome = outcome
                    }

                    // Clipboard vocabulary is grounded in the already
                    // privacy-gated clipboard text (feature toggle ON + permitted
                    // endpoint + never concealed/transient — all enforced when
                    // it was captured; nil context means none of it runs).
                    //
                    // Matching runs over the COMPLETE retained text, never the
                    // rendered excerpt: a term the user copied grounds the
                    // transcript whether or not it survived excerpt selection.
                    // Grounding is input-side and costs no prompt characters,
                    // so it has no reason to inherit the render budget.
                    //
                    // Both the matching and the excerpt selection happen here,
                    // together, and move OFF the main actor when the buffer is
                    // large enough to be worth the hop — see
                    // `PolishContextPreparation`. The render budget is resolved
                    // first because it is also the inline/detached threshold.
                    //
                    // ONE allocation across ALL populated sources, not one per
                    // source: they share a single request's prompt, so they must
                    // share a single budget. Two sources each allocating from
                    // `totalCharacterBudget` would each believe they had all of
                    // it and together spend double.
                    //
                    // Only text that can actually RENDER declares a demand. The
                    // screen demands nothing unless the decision is `.render`
                    // (see below): `vocabularyOnly` and `drop` cost no prompt
                    // characters, and letting them reserve some would starve the
                    // clipboard of budget to render nothing with.
                    let screenRenderDemand: Int = {
                        guard case let .render(excerpt, _, _) = screenDecision else { return 0 }
                        return excerpt.count
                    }()

                    // The joined Claude session's repository. Collected inside
                    // the Task, like the repo vocabulary above and for the same
                    // reason: its git subprocesses and file reads run OFF the
                    // main actor under their own deadline, so a slow repo yields
                    // a smaller snapshot rather than a late commit. Every gate
                    // (setting, permitted endpoint, live join, LOCAL workspace)
                    // is inside `claudeRepoSnapshotIfEnabled`, ahead of the
                    // collector — an unjoined pane means no filesystem call at
                    // all, not a collector that reads and then discards.
                    var claudeRepoSnapshot: ClaudeRepoSnapshot?
                    if let endpointURL = polishingConfig?.endpointURL {
                        claudeRepoSnapshot = await self.claudeRepoSnapshotIfEnabled(
                            join: capturedClaudeJoin,
                            endpointURL: endpointURL,
                            transcript: workingText
                        )
                    }
                    guard !Task.isCancelled else { return }

                    // The session block's text (workspace, the PRIOR prompt, the
                    // files the agent touched, and a remote session's tool
                    // excerpts) is flat, so it rides the shared preparation like
                    // the clipboard and the screen.
                    //
                    // Gated through `claudeSessionTextIfEnabled` on ALL THREE of
                    // the repo block's gates — current setting, currently permitted
                    // endpoint, this exact join still live — not just the
                    // setting. Both blocks attach the session's content, and
                    // consenting to one is consenting to both; it follows that
                    // withdrawing consent, or a session dying mid-sentence, must
                    // stop both too. Checking only the setting here meant a dead
                    // session's PRIOR PROMPT still rode to whatever endpoint was
                    // configured, including a remote one.
                    var claudeSessionText = ""
                    if let endpointURL = polishingConfig?.endpointURL {
                        claudeSessionText = self.claudeSessionTextIfEnabled(
                            join: capturedClaudeJoin,
                            endpointURL: endpointURL
                        )
                    }

                    // Only RENDERABLE material declares a demand — the repo's
                    // demand is what it could show, never `groundingText.count`.
                    // That string is mostly `trackedPaths`, which ground but
                    // never render, so counting it made a monorepo bid hundreds
                    // of thousands of characters for content it would not
                    // attach, and take that space from sources that would. It is
                    // also computed off-actor: it walks the harvest, and this is
                    // the `@MainActor` commit path.
                    var repoRenderDemand = 0
                    if let claudeRepoSnapshot {
                        repoRenderDemand = await ClaudeRepoContextPreparation.renderDemand(
                            snapshot: claudeRepoSnapshot
                        )
                    }

                    let allocation = PolishContextBudget.allocate(demands: [
                        .repository: repoRenderDemand,
                        .terminal: screenRenderDemand,
                        .claude: claudeSessionText.count,
                        .clipboard: capturedClipboardContext?.retainedCharacterCount ?? 0,
                    ])
                    let clipboardRenderBudget = allocation[.clipboard] ?? 0
                    let screenRenderBudget = allocation[.terminal] ?? 0
                    let repoRenderBudget = allocation[.repository] ?? 0
                    let claudeRenderBudget = allocation[.claude] ?? 0

                    // Prepared exactly like every other source: matching over
                    // the COMPLETE harvest, rendering within the grant. The gap
                    // is widest here — a monorepo's tracked path list alone can
                    // exceed the whole prompt budget — which is precisely why
                    // grounding must not inherit the render budget. Every
                    // harvested term votes; only what fits is shown.
                    var claudeRepoPreparation = ClaudeRepoContextPreparation.empty
                    if let claudeRepoSnapshot {
                        claudeRepoPreparation = await ClaudeRepoContextPreparation.prepared(
                            snapshot: claudeRepoSnapshot,
                            transcript: workingText,
                            renderBudget: repoRenderBudget
                        )
                    }
                    let claudeRepoOutcome = claudeRepoPreparation.grounding

                    var claudeSessionPreparation = PolishContextPreparation.empty
                    if !claudeSessionText.isEmpty {
                        claudeSessionPreparation = await PolishContextPreparation.prepared(
                            text: claudeSessionText,
                            transcript: workingText,
                            renderBudget: claudeRenderBudget
                        )
                    }
                    let claudeSessionOutcome = claudeSessionPreparation.grounding

                    var clipboardPreparation = PolishContextPreparation.empty
                    if let clipboardContext = capturedClipboardContext {
                        clipboardPreparation = await PolishContextPreparation.prepared(
                            text: clipboardContext.retainedText,
                            transcript: workingText,
                            renderBudget: clipboardRenderBudget
                        )
                    }
                    let clipboardVocabularyOutcome = clipboardPreparation.grounding

                    // Terminal screen context. Grounded in the screen the user
                    // was looking at when they started speaking, which both
                    // surviving reconciliation outcomes preserve — `.render`
                    // may also show it to the model, `.vocabularyOnly` withholds
                    // the excerpt but the terms the user could SEE while
                    // choosing their words are still the right spellings to
                    // match against. `.drop` yields nil and none of this runs.
                    //
                    // Matching runs over the COMPLETE sanitized screen, never
                    // the excerpt: the budget can cut the rendered excerpt to
                    // nothing (or bar it entirely) and the full screen still
                    // grounds the transcript, exactly as it does for the
                    // clipboard.
                    var screenPreparation = PolishContextPreparation.empty
                    if let screenText = screenDecision.vocabularyGroundingText {
                        screenPreparation = await PolishContextPreparation.prepared(
                            text: screenText,
                            transcript: workingText,
                            renderBudget: screenRenderBudget
                        )
                    }
                    let screenVocabularyOutcome = screenPreparation.grounding

                    guard !Task.isCancelled else { return }

                    // Sources matched independently; the merge is what resolves
                    // them against each other (agreement collapses, conflicting
                    // spans abstain, a fallback guess yields to a solid hit).
                    // Every side carries REAL provenance — a repo aligned-fallback
                    // guess yields to a clipboard exact hit on the same span,
                    // and vice versa.
                    //
                    // The terminal votes HERE, in the same single merge, rather
                    // than appending its entries downstream. That is the whole
                    // point: a span the screen and the clipboard read differently
                    // must ABSTAIN, and a span they agree on must collapse to one
                    // entry. A source that appends after the merge has silently
                    // opted out of both rules and pre-applies its own reading of
                    // a contested span unopposed — editing words the user did not
                    // say.
                    //
                    // The Claude repo and session sources vote HERE too, in the
                    // same single merge, for exactly the reason the terminal
                    // does. They are the strongest sources on the list — a file
                    // the agent just edited is better evidence of a spelling
                    // than anything on the clipboard — but "strongest" is not
                    // "unopposed": when the repo and the clipboard read the same
                    // heard span as two DIFFERENT terms, neither is pre-applied,
                    // because pre-applying the wrong bytes edits the user's words
                    // into something they did not say. Both `.repository`
                    // candidates share one bucket by design: the terminal-cwd
                    // vocabulary and the joined session's repo are both "the repo
                    // the speaker is working in", and they render under one
                    // header.
                    let merged = PolishContextGrounding.merge([
                        PolishContextGrounding.Candidate(
                            source: .repository,
                            entries: repoVocabularyOutcome.entries,
                            isFallbackOnly: repoVocabularyOutcome.isFallbackOnly,
                            phoneticEntries: repoVocabularyOutcome.phoneticEntries,
                            verificationEntries: repoVocabularyOutcome.verificationCandidates
                        ),
                        PolishContextGrounding.Candidate(
                            source: .repository,
                            entries: claudeRepoOutcome.entries,
                            isFallbackOnly: claudeRepoOutcome.isFallbackOnly,
                            phoneticEntries: claudeRepoOutcome.phoneticEntries,
                            verificationEntries: claudeRepoOutcome.verificationCandidates
                        ),
                        PolishContextGrounding.Candidate(
                            source: .terminal,
                            entries: screenVocabularyOutcome.entries,
                            isFallbackOnly: screenVocabularyOutcome.isFallbackOnly,
                            phoneticEntries: screenVocabularyOutcome.phoneticEntries,
                            verificationEntries: screenVocabularyOutcome.verificationCandidates
                        ),
                        PolishContextGrounding.Candidate(
                            source: .claude,
                            entries: claudeSessionOutcome.entries,
                            isFallbackOnly: claudeSessionOutcome.isFallbackOnly,
                            phoneticEntries: claudeSessionOutcome.phoneticEntries,
                            verificationEntries: claudeSessionOutcome.verificationCandidates
                        ),
                        PolishContextGrounding.Candidate(
                            source: .clipboard,
                            entries: clipboardVocabularyOutcome.entries,
                            isFallbackOnly: clipboardVocabularyOutcome.isFallbackOnly,
                            phoneticEntries: clipboardVocabularyOutcome.phoneticEntries,
                            verificationEntries: clipboardVocabularyOutcome.verificationCandidates
                        ),
                    ])
                    let repoVocabularyEntries = merged.entries(from: .repository)
                    let clipboardVocabularyEntries = merged.entries(from: .clipboard)
                    let screenVocabularyEntries = merged.entries(from: .terminal)
                    let claudeVocabularyEntries = merged.entries(from: .claude)
                    let repoVocabularyCount = repoVocabularyEntries.count
                    let clipboardVocabularyCount = clipboardVocabularyEntries.count
                    let screenVocabularyCount = screenVocabularyEntries.count
                    let claudeVocabularyCount = claudeVocabularyEntries.count

                    // Sections are rendered from the MERGED entries, never the
                    // per-source matches: a span the merge abstained on must
                    // not survive as a prompt hint the model could apply by
                    // hand. Appended to the replacement-dictionary section so
                    // the entries land in the `{{replacement_dictionary}}` slot
                    // both profiles already carry — dynamic-suffix side of the
                    // prompt-cache split, never the cached prefix.
                    if !repoVocabularyEntries.isEmpty, templateCarriesDictionarySlot {
                        replacementDictionarySection = RepoVocabularyMatcher.appendedPromptSection(
                            base: replacementDictionarySection,
                            entries: repoVocabularyEntries
                        )
                        Log.polishing.info(
                            "Repo vocabulary attached: \(repoVocabularyCount, privacy: .public) entries"
                        )
                    }

                    if !clipboardVocabularyEntries.isEmpty, templateCarriesDictionarySlot {
                        replacementDictionarySection =
                            RepoVocabularyMatcher.appendedPromptSection(
                                base: replacementDictionarySection,
                                entries: clipboardVocabularyEntries,
                                header: RepoVocabularyMatcher.clipboardVocabularyHeader
                            )
                    }
                    if clipboardVocabularyCount > 0 {
                        // Counts only — entity content is clipboard content.
                        Log.polishing.info(
                            "Clipboard vocabulary attached: clipboard-vocab:\(clipboardVocabularyCount, privacy: .public)"
                        )
                    }

                    // Rendered from the MERGED entries like every other source —
                    // a span the merge abstained on must not reappear here as a
                    // prompt hint. Hint entries need the dictionary slot;
                    // pre-application does not.
                    if !screenVocabularyEntries.isEmpty, templateCarriesDictionarySlot {
                        replacementDictionarySection =
                            RepoVocabularyMatcher.appendedPromptSection(
                                base: replacementDictionarySection,
                                entries: screenVocabularyEntries,
                                header: RepoVocabularyMatcher.terminalScreenVocabularyHeader
                            )
                    }
                    if screenVocabularyCount > 0 {
                        // Counts only — entity content is screen content.
                        Log.polishing.info(
                            "Terminal screen vocabulary attached: screen-vocab:\(screenVocabularyCount, privacy: .public)"
                        )
                    }

                    if !claudeVocabularyEntries.isEmpty, templateCarriesDictionarySlot {
                        replacementDictionarySection =
                            RepoVocabularyMatcher.appendedPromptSection(
                                base: replacementDictionarySection,
                                entries: claudeVocabularyEntries,
                                header: RepoVocabularyMatcher.claudeSessionVocabularyHeader
                            )
                    }
                    if claudeVocabularyCount > 0 {
                        // Counts only — entity content is session content.
                        Log.polishing.info(
                            "Claude session vocabulary attached: claude-vocab:\(claudeVocabularyCount, privacy: .public)"
                        )
                    }

                    // Render from the MERGED pairs only: a span the merge
                    // pre-applied or abstained-and-dropped must not reappear.
                    // These remain untrusted suggestions for the model to
                    // verify against context, deliberately never pre-applied.
                    if !merged.verificationPairs.isEmpty && templateCarriesDictionarySlot {
                        replacementDictionarySection =
                            RepoVocabularyMatcher.appendedVerificationSection(
                                base: replacementDictionarySection,
                                pairs: merged.verificationPairs
                            )
                        Log.polishing.info(
                            "Verification candidates attached: \(merged.verificationPairs.count, privacy: .public)"
                        )
                    }

                    guard !Task.isCancelled else { return }

                    // Exact repo/clipboard bytes and their ASR spans have
                    // already been selected by the deterministic matcher. Put
                    // those bytes into the working text before the single LLM
                    // call instead of relying on a generative model to copy a
                    // prompt hint exactly. The same mappings remain in the
                    // prompt as provenance/context. Boundary checks make this
                    // a no-op if a recorded span is no longer independently
                    // replaceable.
                    // `merged.all`, never a concatenation of the per-source
                    // entries: the merge is what already resolved agreement and
                    // conflict ACROSS sources, and re-assembling its inputs by
                    // hand would reintroduce exactly the duplicates and
                    // contested spans it dropped. Terminal entries are in here
                    // because the terminal is a candidate in the merge above.
                    let groundingEntries = merged.all
                    let groundedWorkingText: String
                    if clipboardPayload != nil {
                        // The payload placeholder is a commit-control token,
                        // not dictation. Ground every surrounding segment but
                        // keep each placeholder byte-exact so its integrity
                        // count and final substitution cannot be bypassed by a
                        // vocabulary term with the same normalized body.
                        groundedWorkingText = workingText
                            .components(separatedBy: ClipboardPayloadMacro.placeholder)
                            .map {
                                RepoVocabularyMatcher.preapplying(
                                    entries: groundingEntries,
                                    to: $0
                                )
                            }
                            .joined(separator: ClipboardPayloadMacro.placeholder)
                    } else {
                        groundedWorkingText = RepoVocabularyMatcher.preapplying(
                            entries: groundingEntries,
                            to: workingText
                        )
                    }
                    if groundedWorkingText != workingText {
                        Log.polishing.info(
                            "Technical grounding pre-applied: repo=\(repoVocabularyCount, privacy: .public), terminal=\(screenVocabularyCount, privacy: .public), claude=\(claudeVocabularyCount, privacy: .public), clipboard=\(clipboardVocabularyCount, privacy: .public)"
                        )
                    }

                    var userPrompts = promptTemplates.renderedUserPrompts(
                        inputText: groundedWorkingText,
                        replacementDictionary: replacementDictionarySection
                    )
                    // Reference-context blocks are prepended to the FINAL user
                    // message, letting the polish model fix near-miss spelling
                    // of technical terms against what the user copied and what
                    // was on their screen.
                    //
                    // ONE `attaching` call with the blocks ordered by
                    // `allocationRank` (terminal, then clipboard). The composer
                    // owns the two invariants for every source: context rides
                    // INSIDE the last message (a separate message between prefix
                    // and suffix invalidated polishd's single-slot checkpoint on
                    // every request, and the cold 4B re-prefill blew the polish
                    // client timeout — field, 2026-07-11), and it is prepended
                    // so the transcript stays LAST. Two sequential prepends keep
                    // both invariants too, but silently REVERSE source order —
                    // the array is the form that cannot get that wrong.
                    //
                    // Both excerpts were already selected off-actor above: at or
                    // below its grant a source is attached verbatim; above it,
                    // the excerpt is the transcript-relevant selection rather
                    // than the head of the buffer.
                    //
                    // The screen block is nil unless the decision is `.render`,
                    // which requires the captured pane to be positively joined
                    // to one live Claude session — so plain, unjoined Ghostty
                    // scrollback contributes vocabulary only and never an
                    // excerpt.
                    let repoBlock = claudeRepoSnapshot?.contextBlock(
                        excerpt: claudeRepoPreparation.excerpt,
                        renderBudget: repoRenderBudget
                    )
                    let screenBlock = screenDecision.contextBlock(
                        excerpt: screenPreparation.excerpt,
                        renderBudget: screenRenderBudget
                    )
                    let claudeBlock = capturedClaudeJoin?.snapshot.claudeContextBlock(
                        excerpt: claudeSessionPreparation.excerpt,
                        renderBudget: claudeRenderBudget
                    )
                    let clipboardBlock = capturedClipboardContext?.contextBlock(
                        excerpt: clipboardPreparation.excerpt,
                        renderBudget: clipboardRenderBudget
                    )
                    // Ordered by `allocationRank` — repository, terminal, claude,
                    // clipboard — the same fixed order the budget allocated in.
                    let contextBlocks = [repoBlock, screenBlock, claudeBlock, clipboardBlock]
                        .compactMap { $0 }
                    if !contextBlocks.isEmpty {
                        userPrompts = PolishContextBlock.attaching(contextBlocks, to: userPrompts)
                    }
                    if let clipboardBlock {
                        Log.polishing.info(
                            "Polish clipboard context attached: \(clipboardBlock.summary, privacy: .public)"
                        )
                    }
                    if let screenBlock {
                        Log.polishing.info(
                            "Polish terminal screen context attached: \(screenBlock.summary, privacy: .public)"
                        )
                    }
                    if let repoBlock {
                        // Count-only by construction: the summary is the
                        // collector's provenance line, which is numbers and
                        // fixed slugs. Repository contents never reach a log.
                        Log.polishing.info(
                            "Polish Claude repository context attached: \(repoBlock.summary, privacy: .public)"
                        )
                    }
                    if let claudeBlock {
                        Log.polishing.info(
                            "Polish Claude session context attached: \(claudeBlock.summary, privacy: .public)"
                        )
                    }

                    // Provenance stays count-only. The screen is recorded only
                    // when it actually contributed (an excerpt, terms, or both)
                    // — a dropped capture is not worth a summary line. Ordered
                    // clipboard-then-screen to match the existing session-record
                    // format.
                    var capturedPolishContextSummary: String? = clipboardBlock?.summary
                    if screenVocabularyCount > 0 || screenBlock != nil {
                        // The block's summary when one was rendered (it reports
                        // the TRIMMED count); the decision's otherwise.
                        let screenSummary =
                            screenBlock?.summary ?? screenDecision.provenanceSummary
                        capturedPolishContextSummary = capturedPolishContextSummary
                            .map { "\($0) \(screenSummary)" } ?? screenSummary
                    }

                    let polishingRequest = LLMPolishingRequest(
                        inputText: groundedWorkingText,
                        systemPrompt: promptTemplates.systemContent,
                        userPrompts: userPrompts
                    )

                    var processedTextForPersistence: String? =
                        workingText != originalText ? workingText : nil
                    var polishingDuration: Double? = nil
                    var sessionStatus: DictationSessionStatus = .completed
                    var llmConnectionFailure: (message: String, technicalDetails: String?)?
                    #if LOCALVOXTRAL_DOGFOOD
                    // The model's raw reply and the (placeholder-bearing)
                    // committed text, hoisted out of the do-block for the
                    // capture record below. Placeholder-bearing on purpose: the
                    // clipboard PAYLOAD follows the session-record rule and
                    // never enters a persisted record.
                    var dogfoodPolishedOutput: String?
                    var dogfoodCommittedText: String?
                    #endif

                    if let config = polishingConfig, !workingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        do {
                            let result = try await self.llmPolishingService.polish(
                                request: polishingRequest,
                                configuration: config
                            )
                            polishingDuration = result.durationSeconds

                            // Trust the polishing model for both prompt profiles.
                            // Human evaluation found deterministic token repair
                            // could undo useful formatting and reconstruction.
                            // Placeholder-count integrity for an explicit paste
                            // macro remains independent below.
                            var committedText = result.polishedText

                            // Placeholder-count integrity stays independent of
                            // trusting model text: a duplicated placeholder
                            // would paste the payload twice, while dropping one
                            // of two would lose a requested paste. Compare
                            // standalone counts against the grounded pre-polish
                            // text; on mismatch, discard the polish and keep
                            // that placeholder-bearing text.
                            if clipboardPayload != nil {
                                let expectedPlaceholders =
                                    ClipboardPayloadMacro.standalonePlaceholderCount(
                                        in: groundedWorkingText
                                    )
                                let actualPlaceholders =
                                    ClipboardPayloadMacro.standalonePlaceholderCount(
                                        in: committedText
                                    )
                                if actualPlaceholders != expectedPlaceholders {
                                    committedText = groundedWorkingText
                                    Log.polishing.warning(
                                        "Clipboard payload macro: polish changed placeholder count (\(expectedPlaceholders, privacy: .public) -> \(actualPlaceholders, privacy: .public)); polish discarded"
                                    )
                                }
                            }

                            // Persist the PLACEHOLDER-bearing committed text —
                            // the clipboard payload must never enter the session
                            // record. Substitution happens only for the display/
                            // commit copy below.
                            processedTextForPersistence =
                                committedText != originalText ? committedText : nil
                            #if LOCALVOXTRAL_DOGFOOD
                            dogfoodPolishedOutput = result.polishedText
                            dogfoodCommittedText = committedText
                            #endif

                            guard !Task.isCancelled else { return }

                            self.currentDictationEventText = self.clipboardPayloadSubstituted(
                                committedText, payload: clipboardPayload
                            )
                            // Polish-changed iff the guarded/verified committed
                            // text differs from the pre-grounding working text.
                            // This intentionally counts an evidence-backed
                            // deterministic spelling correction even when the
                            // model otherwise returns its input unchanged.
                            // Drives the overlay badge (during hold) and the
                            // "Copy raw transcript" popover affordance.
                            let polishChanged = committedText != workingText
                            self.overlayBufferCoordinator.markPolished(polishChanged)
                            // Retain the RAW (pre-everything) transcript for the
                            // one-line popover copy affordance — but only when the
                            // commit visibly changed it, so a no-op polish leaves
                            // no stale affordance. Persisted `rawText` uses the
                            // same `originalText`.
                            self.lastPolishChangedRawTranscript =
                                (polishChanged && originalText != committedText)
                                ? originalText : nil
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
                                    // Name the endpoint the request was ACTUALLY
                                    // sent to — in managed mode the external-URL
                                    // setting (its untouched placeholder default,
                                    // typically :8080) was never used, and naming
                                    // it sent field debugging to the wrong
                                    // process (2026-07-11).
                                    self.llmPolishingConnectionTechnicalDetails(
                                        details,
                                        endpointURL: config.endpointURL
                                    )
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
                        commitSucceeded: commitSucceeded,
                        polishProfile: capturedPolishProfile,
                        polishContextSummary: self.mergedPolishProvenanceSummary(
                            context: capturedPolishContextSummary,
                            payload: payloadProvenanceSummary,
                            vocabulary: {
                                let parts = [
                                    repoVocabularyCount > 0
                                        ? "vocab:\(repoVocabularyCount)" : nil,
                                    clipboardVocabularyCount > 0
                                        ? "clipboard-vocab:\(clipboardVocabularyCount)" : nil,
                                ].compactMap { $0 }
                                return parts.isEmpty ? nil : parts.joined(separator: "+")
                            }()
                        )
                    )

                    #if LOCALVOXTRAL_DOGFOOD
                    // AFTER the commit and the session record: capture latency
                    // can only ever land on the tail of this task, never on the
                    // user's paste. `writeDogfoodCaptureIfArmed` checks the
                    // runtime opt-in before doing any work.
                    await self.writeDogfoodCaptureIfArmed(
                        DogfoodCaptureInputs(
                        session: DogfoodCaptureRecord.Session(
                            targetBundleID: capturedTargetBundleID,
                            targetKind: self.sessionTargetIsTerminalLike
                                ? "terminal-like" : "other",
                            outputMode: capturedOutputMode,
                            promptProfile: capturedPolishProfile,
                            endpointClass: polishingConfig.map {
                                DogfoodCaptureBuilder.endpointClass(of: $0.endpointURL)
                            },
                            polishModel: polishingConfig?.model
                        ),
                        join: capturedClaudeJoin,
                        // Filled from the tap inside writeDogfoodCaptureIfArmed.
                        joinAbstentions: [],
                        screenDecision: screenDecision,
                        // Value inequality is the swap signal: only the herdr
                        // reconcile above ever reassigns `screenDecision`, and
                        // a failed pane.read returns the fallback (equal). A
                        // successful pane.read that happens to EQUAL the
                        // fallback mislabels only the route — the decision and
                        // cause still tell the true story. Intentional.
                        socketPaneSwapApplied: capturedSocketPaneStart != nil
                            && screenDecision != capturedScreenDecision,
                        targetBundleID: capturedTargetBundleID,
                        demands: [
                            .repository: repoRenderDemand,
                            .terminal: screenRenderDemand,
                            .claude: claudeSessionText.count,
                            .clipboard: capturedClipboardContext?.retainedCharacterCount ?? 0,
                        ],
                        grants: allocation,
                        rendered: [
                            .repository: repoBlock != nil
                                ? claudeRepoPreparation.excerpt.count : 0,
                            .terminal: screenBlock != nil
                                ? screenPreparation.excerpt.count : 0,
                            .claude: claudeBlock != nil
                                ? claudeSessionPreparation.excerpt.count : 0,
                            .clipboard: clipboardBlock != nil
                                ? clipboardPreparation.excerpt.count : 0,
                        ],
                        repoVocabularyHarvest: nil,
                        repoVocabularyOutcome: repoVocabularyOutcome,
                        claudeRepoSnapshot: claudeRepoSnapshot,
                        claudeRepoOutcome: claudeRepoOutcome,
                        claudeRepoRenderedExcerpt: repoBlock != nil
                            ? claudeRepoPreparation.excerpt : nil,
                        claudeSessionText: claudeSessionText.isEmpty ? nil : claudeSessionText,
                        claudeSessionOutcome: claudeSessionOutcome,
                        claudeSessionRenderedExcerpt: claudeBlock != nil
                            ? claudeSessionPreparation.excerpt : nil,
                        clipboardRetainedText: capturedClipboardContext?.retainedText,
                        clipboardOutcome: clipboardVocabularyOutcome,
                        clipboardRenderedExcerpt: clipboardBlock != nil
                            ? clipboardPreparation.excerpt : nil,
                        screenOutcome: screenVocabularyOutcome,
                        screenRenderedExcerpt: screenBlock != nil
                            ? screenPreparation.excerpt : nil,
                        text: DogfoodCaptureRecord.Text(
                            rawTranscript: originalText,
                            workingText: workingText,
                            groundedText: groundedWorkingText,
                            systemPrompt: polishingRequest.systemPrompt,
                            userPrompts: polishingRequest.userPrompts,
                            polishedOutput: dogfoodPolishedOutput,
                            committedText: dogfoodCommittedText
                        ),
                        polishSeconds: polishingDuration
                        ),
                        commitOutcome: overlayCommitOutcome,
                        // Substituted for MEASUREMENT only (the watch window
                        // scales with what was inserted); the record keeps the
                        // placeholder-bearing text above.
                        committedTextForWatch: self.clipboardPayloadSubstituted(
                            dogfoodCommittedText ?? groundedWorkingText,
                            payload: clipboardPayload
                        )
                    )
                    #endif

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
                // Persist the PLACEHOLDER-bearing working text, never the
                // payload; the payload lives only in the substituted commit copy.
                polishedText: workingText != originalText ? workingText : nil,
                polishingDuration: nil,
                provider: capturedProvider,
                model: capturedModel,
                outputMode: capturedOutputMode,
                targetAppBundleID: capturedTargetBundleID,
                status: llmConfigurationFailure == nil ? .sttCompleted : .llmFailed,
                commitSucceeded: commitSucceeded,
                polishContextSummary: payloadProvenanceSummary
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
        // Terminal-like targets always begin a live session even with the
        // dictionary disabled: the hold-back stream's newline/tab sanitization
        // must protect the terminal regardless of replacements.
        guard settings.replacementDictionaryEnabled || sessionTargetIsTerminalLike else {
            textInsertion.endLiveReplacementSession()
            return
        }

        overlayBufferCoordinator.captureLiveCommitTargetAppPID()
        let dictionary = replacementDictionaryForCurrentSession()
        textInsertion.beginLiveReplacementSession(
            dictionary: dictionary,
            preferredAppPID: overlayBufferCoordinator.commitTargetAppPID,
            isTerminalLikeTarget: sessionTargetIsTerminalLike
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
        // Every stop funnels through here. The commit path has already
        // consumed the capture by now (it reconciles synchronously, before
        // spawning the polish Task), so this is a no-op there — it exists to
        // catch the stop paths that never reach the commit block at all: empty
        // transcript, polishing disabled, cancelled overlay.
        discardTerminalScreenCapture()
        clearLatchedSessionMetadata()
        setRealtimeIndicatorIdle()
        livePartialText = ""
        pendingSegmentText = ""
        switch overlayCommitOutcome {
        case .failed?:
            statusText = "Insert failed."
        case .copiedToClipboard?:
            statusText = StatusStrings.overlayCopiedToClipboard
        default:
            statusText = "Ready"
        }

        textInsertion.stopInsertionRetryTask()
        textInsertion.logDiagnostics()
        textInsertion.endLiveReplacementSession()

        if sessionMode == .liveAutoPaste, textInsertion.hasPendingInsertionText {
            lastError = "Some realtime text could not be inserted into the focused app."
            textInsertion.clearPendingText()
        }

        // Dismiss policy: a FAILED commit keeps its panel (the buffered text
        // may exist nowhere else); the secure-input clipboard fallback shows
        // its message for a readable hold and then dismisses — the text is
        // safe on the clipboard, and a panel that outlives the session read
        // as stuck in the field (owner feedback on #90).
        let dismissVisibility: TimeInterval?
        if !shouldCommitOverlay {
            dismissVisibility = TimingConstants.overlayFinalWordVisibilityMinimum
        } else {
            switch overlayCommitOutcome {
            case .failed?:
                dismissVisibility = nil
            case .copiedToClipboard?:
                dismissVisibility = TimingConstants.overlayClipboardFallbackVisibility
            default:
                dismissVisibility = TimingConstants.overlayFinalWordVisibilityMinimum
            }
        }
        if let dismissVisibility {
            overlayBufferCoordinator.dismissAfterHold(minimumVisibility: dismissVisibility)
        }

        if currentErrorToken == .websocketReceiveFailed {
            lastError = nil
        }
        // The Secure Keyboard Entry warning describes state sampled at session
        // start; a finished session must not leave it wedged in the popover —
        // nor keep the menu bar warning icon lit. (A REFUSED live start never
        // reaches this teardown; its icon clears when the shortcut release
        // ends the attempt gesture, and the popover line at the next start.)
        if currentErrorToken == .secureKeyboardEntryActive {
            lastError = nil
        }
        sessionSecureInputActive = false
        sessionClaudeJoinBadge = .hidden
        firstChunkPreprocessor.reset()
    }

    func resolveTargetAppBundleID() -> String? {
        #if DEBUG
        if let override = debugResolveTargetAppBundleIDOverride {
            return override()
        }
        #endif
        guard let pid = overlayBufferCoordinator.commitTargetAppPID else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Reads a capped clipboard excerpt for polish grounding, but ONLY when the
    /// opt-in setting is on AND the polishing endpoint is loopback. Both guards
    /// short-circuit BEFORE the reader resolves, so a disabled toggle or a
    /// remote endpoint means the pasteboard is never touched at all (privacy:
    /// no read). The endpoint gate keeps the Settings promise honest: the
    /// polishing endpoint is user-configurable and may point at a cloud
    /// provider, which must never receive clipboard content.
    func polishClipboardContextIfEnabled(endpointURL: URL) -> PolishClipboardContext? {
        guard settings.polishClipboardContextEnabled else { return nil }
        guard PolishContextClipboardReader.isPermittedContextEndpoint(
            endpointURL,
            trustedEndpointEnabled: settings.polishContextTrustedEndpointEnabled
        ) else {
            Log.polishing.info(
                "Polish clipboard context skipped: polishing endpoint is not permitted (loopback-only without the trusted-endpoint opt-in)"
            )
            return nil
        }
        return PolishContextClipboardReader.readClipboardContext(
            from: resolvePolishContextPasteboardReader()
        )
    }

    private func resolvePolishContextPasteboardReader() -> any PasteboardReading {
        #if DEBUG
        if let override = debugPolishContextPasteboardReaderOverride {
            return override()
        }
        #endif
        return SystemPasteboardReader()
    }

    /// Result of the spoken clipboard-paste macro over the (replacement-applied)
    /// working text: `placeholderText` carries the placeholder in place of each
    /// marker when the macro fired (else it is the input unchanged), `payload`
    /// is the sanitized clipboard string to substitute back at commit (nil when
    /// the macro did not fire), and `summary` is the count-only provenance note
    /// for the session record (nil when the macro did not fire).
    struct ClipboardPayloadMacroOutcome {
        let placeholderText: String
        let payload: String?
        let summary: String?
    }

    /// Applies the spoken clipboard-paste macro to `text` when the setting is on
    /// AND a marker phrase is present. Reads the clipboard exactly ONCE (through
    /// the shared `PolishContextClipboardReader` readability rules — concealed/
    /// transient/empty are skipped). An unreadable clipboard leaves the
    /// transcript unchanged and logs one content-free line. When the setting is
    /// off or no marker was spoken, the pasteboard is never touched.
    func applyClipboardPayloadMacroIfEnabled(to text: String) -> ClipboardPayloadMacroOutcome {
        guard settings.clipboardPayloadMacroEnabled else {
            return ClipboardPayloadMacroOutcome(placeholderText: text, payload: nil, summary: nil)
        }
        guard !ClipboardPayloadMacro.detectMarkers(in: text).isEmpty else {
            return ClipboardPayloadMacroOutcome(placeholderText: text, payload: nil, summary: nil)
        }
        guard let payload = PolishContextClipboardReader.readableSanitizedString(
            from: resolveClipboardPayloadPasteboardReader()
        ) else {
            Log.polishing.info(
                "Clipboard payload macro: marker spoken but clipboard unreadable; transcript left unchanged"
            )
            return ClipboardPayloadMacroOutcome(placeholderText: text, payload: nil, summary: nil)
        }
        let replaced = ClipboardPayloadMacro.replaceMarkersWithPlaceholder(in: text)
        Log.polishing.info(
            "Clipboard payload macro fired: \(replaced.count, privacy: .public) marker(s), payload:\(payload.count, privacy: .public)ch"
        )
        return ClipboardPayloadMacroOutcome(
            placeholderText: replaced.text,
            payload: payload,
            summary: "payload:\(payload.count)ch"
        )
    }

    /// Substitutes the clipboard payload back into `text` (replacing the macro
    /// placeholder). A no-op when the macro did not fire (`payload == nil`).
    func clipboardPayloadSubstituted(_ text: String, payload: String?) -> String {
        guard let payload else { return text }
        return ClipboardPayloadMacro.substitutePayload(in: text, payload: payload)
    }

    /// Combines the clipboard polish-context, payload-macro, and repo-vocabulary
    /// provenance notes into the single `polishContextSummary` record field
    /// (counts only): `clipboard:24ch+payload:1532ch+vocab:3`, any subset, or nil.
    func mergedPolishProvenanceSummary(
        context: String?,
        payload: String?,
        vocabulary: String? = nil
    ) -> String? {
        let parts = [context, payload, vocabulary].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "+")
    }

    /// Overall deadline on the detached vocabulary pipeline. The git wait is
    /// internally bounded, but a `fileExists` stat on a stale network mount in
    /// the cwd resolution can block indefinitely — and the polish Task awaits
    /// this, so without a deadline that session's commit would wedge at
    /// "Polishing…". Vocabulary is best-effort; the commit is not.
    static let repoVocabularyPipelineDeadline: Duration = .seconds(3)

    /// Opt-in repo-vocabulary grounding: harvests file names / path components /
    /// the branch from the git repo in the focused terminal and returns the
    /// transcript-relevant ones as replacement entries — but ONLY when the
    /// setting is on AND the polishing endpoint is permitted — loopback, or any
    /// endpoint under the explicit trusted-endpoint opt-in (repo file names
    /// never ride to an endpoint the user has not consented to, same privacy
    /// stance as clipboard context). Both gates short-circuit before any AX read or subprocess.
    /// Only the AX title and captured-app identity reads happen on the main
    /// actor (with a 0.5 s AX messaging timeout); everything blocking-ish — FS
    /// stats on the title/process CWD candidates (possibly a stale network
    /// mount), the process-table/CWD reads, the git subprocess (2 s timeout),
    /// and the n-gram match over a possibly-20k-term vocabulary — runs in one
    /// detached hop RACED against
    /// `repoVocabularyPipelineDeadline`, so no blocked syscall can ever wedge
    /// the commit. A single-flight gate caps the cost of abandonment at one
    /// blocked pool thread: while an abandoned pipeline is still wedged,
    /// subsequent commits fast-skip vocabulary instead of stacking more
    /// blocked threads until the pool (and the deadline itself) starves.
    /// Returns nil (silent skip) when off, remote, no trustworthy terminal
    /// repo signal, no transcript-relevant match, deadline expiry, or in-flight
    /// skip.
    func repoVocabularyGroundingIfEnabled(
        endpointURL: URL,
        transcript: String
    ) async -> RepoVocabularyMatcher.GroundingOutcome? {
        guard settings.repoVocabularyEnabled else { return nil }
        guard PolishContextClipboardReader.isPermittedContextEndpoint(
            endpointURL,
            trustedEndpointEnabled: settings.polishContextTrustedEndpointEnabled
        ) else {
            Log.polishing.info("Repo vocabulary skipped: polishing endpoint is not local")
            return nil
        }
        #if DEBUG
        if let override = debugRepoVocabularyEntriesOverride {
            return override(transcript)
        }
        #endif
        guard repoVocabularyPipelineInFlight.acquire() else {
            Log.polishing.info("Repo vocabulary skipped: a previous pipeline is still in flight")
            return nil
        }
        guard let pipelineTask = makeRepoVocabularyPipelineTask(transcript: transcript) else {
            repoVocabularyPipelineInFlight.release()
            return nil
        }

        let deadlineSleep = resolveRepoVocabularyDeadlineSleep()
        // Race via a resume-once continuation, NOT a task group: a group
        // awaits ALL its children before returning, and the pipeline child —
        // awaiting a possibly-forever-blocked task's value, which is not
        // cancellation-responsive — would wedge the group (and the commit)
        // in exactly the case the deadline exists for. The losing side is
        // abandoned; its late resumeOnce call is a guarded no-op.
        let raceOutcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<RepoVocabularyRaceOutcome, Never>) in
            let resumed = Mutex(false)
            let resumeOnce: @Sendable (RepoVocabularyRaceOutcome) -> Void = { outcome in
                let shouldResume = resumed.withLock { alreadyResumed in
                    if alreadyResumed { return false }
                    alreadyResumed = true
                    return true
                }
                if shouldResume { continuation.resume(returning: outcome) }
            }
            // The continuation propagates no priority to the race children
            // (unlike the previous direct `await .value`, which escalated the
            // pipeline to the awaiting task's priority). Deliberate for the
            // pipeline — vocabulary is best-effort background work — but the
            // deadline's whole job is timeliness, so it runs `.userInitiated`
            // to keep its resumption from being starved under CPU pressure.
            Task.detached(priority: .utility) { [gate = repoVocabularyPipelineInFlight] in
                let entries = await pipelineTask.value
                // Release the single-flight gate only when the pipeline truly
                // finished — on the abandonment path this runs arbitrarily
                // late, and until then new commits fast-skip vocabulary.
                gate.release()
                resumeOnce(.pipeline(entries))
            }
            Task.detached(priority: .userInitiated) {
                await deadlineSleep()
                resumeOnce(.deadlineExpired)
            }
        }

        switch raceOutcome {
        case .pipeline(let entries):
            return entries
        case .deadlineExpired:
            // Abandonment is safe by construction: the detached pipeline only
            // ever RETURNS a value — it never mutates view-model state — so
            // when it eventually completes its result is simply discarded.
            // (Its only shared side effects are inserting into the
            // Mutex-guarded RepoVocabularyCache, which only makes a later
            // session faster, and releasing the single-flight gate.) Until it
            // completes it holds the gate, so a genuinely wedged pipeline
            // costs at most ONE blocked pool thread across any number of
            // subsequent commits.
            Log.polishing.info("Repo vocabulary skipped: pipeline exceeded deadline")
            return nil
        }
    }

    /// The detached focused-title/terminal-PID -> cwd -> index -> match
    /// pipeline as a task. A title is optional because foreground terminal
    /// programs commonly overwrite it; the captured terminal app PID enables
    /// the conservative descendant-CWD fallback. Split out so the deadline
    /// race above stays readable and the DEBUG pipeline seam replaces exactly
    /// the detached section (keeping the race in play for deadline tests).
    private func makeRepoVocabularyPipelineTask(
        transcript: String
    ) -> Task<RepoVocabularyMatcher.GroundingOutcome?, Never>? {
        #if DEBUG
        if let override = debugRepoVocabularyPipelineOverride {
            return Self.detachedRepoVocabularyPipeline { await override(transcript) }
        }
        #endif
        guard let terminalApplicationPID = overlayBufferCoordinator.commitTargetAppPID else {
            Log.polishing.info("Repo vocabulary: no terminal application PID available")
            return nil
        }
        let title = TerminalWorkingDirectoryResolver.windowTitle(
            forApplicationPID: terminalApplicationPID
        )
        let targetBundleID = resolveTargetAppBundleID()
        let processFallbackPID: pid_t?
        if let targetBundleID,
           TerminalTargetDetector.isTerminalLikeBundleID(targetBundleID)
            || appConfigStore.loadTerminalAppBundleIDs().contains(targetBundleID)
        {
            processFallbackPID = terminalApplicationPID
        } else {
            // Descendant CWDs only have the intended meaning for terminal
            // emulators. Other apps (IDEs especially) may own build helpers in
            // unrelated repos; never treat those as a focused-terminal signal.
            processFallbackPID = nil
        }
        let cache = repoVocabularyCache
        return Self.detachedRepoVocabularyPipeline {
            await RepoVocabularyService.entries(
                forWindowTitle: title,
                terminalApplicationPID: processFallbackPID,
                transcript: transcript,
                cache: cache
            )
        }
    }

    /// The detached pipeline task, with the ONE dogfood obligation both the
    /// live pipeline and the DEBUG override seam must share: in a dogfood
    /// build, the body runs under the tap generation read at creation time
    /// (synchronously, in the caller's main-actor context — ordered against
    /// `beginSession`). Task-locals do not cross `Task.detached`, so the
    /// binding happens inside the closure; see `DogfoodCaptureTap.noteGeneration`
    /// for why an abandoned pipeline's late harvest note must be rejectable.
    /// Routing the seam through here too is what makes the binding testable —
    /// a pipeline path that skipped it would accept stale notes unchecked.
    private static func detachedRepoVocabularyPipeline(
        _ body: @escaping @Sendable () async -> RepoVocabularyMatcher.GroundingOutcome?
    ) -> Task<RepoVocabularyMatcher.GroundingOutcome?, Never> {
        #if LOCALVOXTRAL_DOGFOOD
        let dogfoodGeneration = DogfoodCaptureTap.shared.currentGeneration
        return Task.detached(priority: .utility) {
            await DogfoodCaptureTap.$noteGeneration.withValue(dogfoodGeneration) {
                await body()
            }
        }
        #else
        return Task.detached(priority: .utility) { await body() }
        #endif
    }

    private func resolveRepoVocabularyDeadlineSleep() -> @Sendable () async -> Void {
        #if DEBUG
        if let override = debugRepoVocabularyDeadlineSleepOverride {
            return override
        }
        #endif
        return {
            try? await Task.sleep(for: Self.repoVocabularyPipelineDeadline)
        }
    }

    private func resolveClipboardPayloadPasteboardReader() -> any PasteboardReading {
        #if DEBUG
        if let override = debugClipboardPayloadPasteboardReaderOverride {
            return override()
        }
        #endif
        return SystemPasteboardReader()
    }

    /// Polishing prompt profile for a stop-commit: `.agent` iff the user has the
    /// agent profile enabled AND the captured target bundle ID is terminal-like
    /// (built-in terminal allowlist, or the user's `terminal_apps.toml` list).
    /// Mirrors the live-mode target combination (allowlist + user bundle IDs);
    /// the AX-probe verdict is deliberately not consulted here — the polish
    /// switch keys off the app identity, not the focused field's writability.
    func selectedPolishProfile(forTargetBundleID bundleID: String?) -> PolishPromptProfile {
        guard settings.agentPolishProfileEnabled else { return .standard }
        guard let bundleID, !bundleID.isEmpty else { return .standard }
        if TerminalTargetDetector.isTerminalLikeBundleID(bundleID) { return .agent }
        if appConfigStore.loadTerminalAppBundleIDs().contains(bundleID) { return .agent }
        return .standard
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
        commitSucceeded: Bool,
        polishProfile: String? = nil,
        polishContextSummary: String? = nil
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
            commitSucceeded: commitSucceeded,
            polishProfile: polishProfile,
            polishContextSummary: polishContextSummary
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

            await self.resolveConnectTimeout(timeoutSeconds: timeout)
        }
    }

    func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        isResolvingConnectTimeout = false
    }

    func abortConnectingSession(disconnectSocket: Bool = true) {
        // An aborted connect never reaches stopped-session cleanup, so a remote
        // herdr tunnel opened at start would otherwise stay up with nothing
        // left to read from it (review finding 4). Every abort route — the
        // connect timeout, a mic-start failure, a thrown connect, the escape
        // cancel — funnels through here.
        closeRemoteHerdrForwards()
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
        stopMicrophoneIfInitialized()
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

    func resolveConnectTimeout(
        timeoutSeconds: TimeInterval,
        sleepFor: (TimeInterval) async -> Void = DictationViewModel.sleepForConnectTimeoutSocketErrorGrace
    ) async {
        guard isConnectingRealtimeSession else { return }

        if let lastSocketErrorMessage, !lastSocketErrorMessage.trimmed.isEmpty {
            abortConnectingSession()
            handleConnectFailure(reason: .socketError(message: lastSocketErrorMessage))
            return
        }

        isResolvingConnectTimeout = true
        await sleepFor(TimingConstants.connectTimeoutSocketErrorGrace)
        isResolvingConnectTimeout = false

        guard !Task.isCancelled, isConnectingRealtimeSession else { return }

        if let lastSocketErrorMessage, !lastSocketErrorMessage.trimmed.isEmpty {
            abortConnectingSession()
            handleConnectFailure(reason: .socketError(message: lastSocketErrorMessage))
            return
        }

        abortConnectingSession()
        handleConnectFailure(reason: .timedOut(timeoutSeconds: timeoutSeconds))
    }

    private static func sleepForConnectTimeoutSocketErrorGrace(_ duration: TimeInterval) async {
        try? await Task.sleep(for: .seconds(duration))
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

    /// Whether this process is running as (or under) an XCTest host, decided
    /// from BOTH available signals: the XCTest runtime being loaded, and the
    /// `XCTestConfigurationFilePath` environment variable xctest sets for the
    /// processes it launches. The class check alone misses a child process the
    /// harness spawned without linking XCTest into it; either signal alone
    /// means "no modal UI here, ever". Pure and injectable so the truth table
    /// is assertable from inside a test process (where both signals are live).
    nonisolated static func isTestProcess(
        hasXCTestClass: Bool = NSClassFromString("XCTestCase") != nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        hasXCTestClass || environment["XCTestConfigurationFilePath"] != nil
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

        // NSApp is nil in processes without an NSApplication (unit tests,
        // headless tools); an alert cannot be presented there and force-
        // unwrapping aborts the process (field flake: a leaked connect-timeout
        // timer SIGTRAPed the test runner mid-suite).
        guard NSApp != nil else {
            Log.dictation.error("connection-failure alert skipped: no NSApplication in this process")
            return
        }
        // The nil guard above is NOT sufficient in a test process: any earlier
        // test that touches NSApplication.shared initializes NSApp for the rest
        // of the suite, and runModal() then stops the whole run dead waiting
        // for a click that never comes (xctest sample 2026-07-19: this frame
        // parked in _DPSBlockUntilNextEventMatchingListInMode mid-suite).
        guard !Self.isTestProcess() else {
            Log.dictation.error("connection-failure alert skipped: XCTest process")
            return
        }
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

    /// The endpoint the ACTIVE polishing configuration resolves to — in
    /// managed mode that is the managed polishd URL, never the external-URL
    /// setting (whose untouched placeholder default used to be reported here
    /// and misdirected field debugging, 2026-07-11). Falls back to the raw
    /// setting text only when no configuration resolves at all.
    private func sanitizedLLMPolishingEndpointForLogging() -> String {
        if let configured = settings.llmPolishingConfiguration?.endpointURL {
            return sanitizedURLForLogging(configured)
        }
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

    /// Failure details for the alert/`lastError`, naming `endpointURL` — the
    /// endpoint the failing request was actually sent to, captured from the
    /// request's own configuration (Settings may have changed since).
    func llmPolishingConnectionTechnicalDetails(
        _ details: String,
        endpointURL: URL
    ) -> String {
        let endpoint = sanitizedURLForLogging(endpointURL)
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
        // The badge travels WITH the start: the join is resolved before the
        // socket connects and this runs after it, so it is always already
        // known — and passing it in is what stops a later setter from being
        // ordered wrong against the reset that starting a session performs.
        overlayBufferCoordinator.startSession(
            preResolvedAnchor: anchor,
            claudeJoin: sessionClaudeJoinBadge
        )
        if sessionSecureInputActive {
            // The overlay is the surface the user is actually watching while
            // buffering — warn there, not just in the (closed) popover. The
            // commit re-checks secure input and falls back to the clipboard.
            overlayBufferCoordinator.showSecureInputWarning()
        }
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

/// Winner of the repo-vocabulary race in `repoVocabularyGroundingIfEnabled`:
/// either the detached pipeline finished (with or without entries) or the
/// deadline expired first and the pipeline was abandoned.
private enum RepoVocabularyRaceOutcome: Sendable {
    case pipeline(RepoVocabularyMatcher.GroundingOutcome?)
    case deadlineExpired
}
