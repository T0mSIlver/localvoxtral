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
        // A session with no socket is on no connection, so anything the socket
        // it just gave up still emits is refused from here on (#417).
        sessionConnectionGeneration = .none
        sessionOutputMode = nil
        sessionStartedAt = nil
        sessionProvider = nil
        sessionModelName = nil
        sessionReplacementDictionary = nil
        sessionRealtimeConfiguration = nil
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
                // Someone else cancelled the work this session was waiting on —
                // the Engines pane's Pause/Cancel buttons, or a settings change
                // that stops the backend — and this task was not cancelled with
                // it. That is a user action, not a backend failure: unwind the
                // connect without an alert. The abort above still has to run,
                // or `isConnectingRealtimeSession` stays latched and blocks
                // every later start.
                if error is CancellationError {
                    self.statusText = StatusStrings.ready
                    return
                }
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
            if !self.shortcuts.isDictationAttemptGestureActive {
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
        logConnectionFailure(message: message, technicalDetails: technicalDetails)
        markRecentConnectionFailureIndicator()
        presentConnectionFailureAlert(
            title: "Managed backend failed",
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
        cancelRealtimeReconnect()
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
        sessionReplacementDictionary = loadEffectiveReplacementDictionary()
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
        // The bearer token is part of the same snapshot as endpoint and model:
        // `trimmedAPIKey` resolves by the CURRENT dictation mode, and the
        // screen-context capture below suspends (AppleScript, ssh) long enough
        // for Settings to flip the mode. Read at connect time, an External URL
        // session would carry the Mistral key to the user's own server, or a
        // Mistral session the external key to api.mistral.ai (GLM review,
        // 2026-09-16). One mode, one snapshot: client, endpoint, model, key.
        let apiKey = settings.trimmedAPIKey
        // Pick THIS session's client before anything else touches one: from
        // here to the stop, every send, poll and disconnect goes to the latched
        // client, whatever Settings does in the meantime.
        latchActiveRealtimeClient()
        // Reset the realtime client from any prior session before reconnecting.
        activeRealtimeClient.disconnect()
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
                context.discardTerminalScreenCapture()
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

        #if DEBUG
        // Lets a test mutate Settings at the one point a real session can be
        // interrupted (after the capture awaits, before the socket opens).
        await debugBeforeConnectHookForTesting?()
        #endif

        // Latched, not rebuilt: a mid-session reconnect (#380) dials exactly
        // what this session opened with, even if Settings moved on since.
        let configuration = RealtimeSessionConfiguration(
            endpoint: endpoint,
            apiKey: apiKey,
            model: model
        )
        sessionRealtimeConfiguration = configuration

        do {
            try activeRealtimeClient.connect(configuration: configuration)
            // Read back with no suspension in between, so the socket this call
            // opened cannot report in before the session knows its name.
            sessionConnectionGeneration = activeRealtimeClient.connectionGeneration
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
            try startSessionAudioCapture(preferredDeviceID: preferredInputID) { chunk in
                chunkBuffer.append(chunk)
            }

            isConnectingRealtimeSession = false
            isDictating = true
            // Here, not at connect: a connect that times out or is refused
            // must never leave other audio down. Both output modes duck.
            audioDucking.duckForSessionStart()
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
            // The monitor's recovery restarts the microphone, which would mix
            // the room into a session that is fed from a file.
            if capturesFromMicrophone {
                healthMonitor.start(microphone: microphone, callbacks: makeHealthMonitorCallbacks())
            }
        } catch {
            statusText = "Failed to start dictation."
            lastError = error.localizedDescription
            isConnectingRealtimeSession = false
            isDictating = false
            escapeCancelHandler.stop()
            healthMonitor.stop()
            stopSessionAudioCapture()
            audioDucking.restoreAfterSession()
            activeRealtimeClient.disconnect()
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
            stopForUnavailableInput: { [weak self] in
                self?.stopDictationForUnavailableMicrophone()
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
        let client = activeRealtimeClient
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
        let client = activeRealtimeClient
        let chunkBuffer = audioChunkBuffer
        let debugLoggingEnabled = debugLoggingEnabled
        audioSendTask = Task(priority: .utility) {
            var emptyBufferTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }

                // Read before draining: between the socket dying and the
                // `.disconnected` event cancelling this task, a tick that
                // drained would hand its chunk to a client that discards it —
                // and that audio is exactly what a reconnect replays (#380).
                guard client.isConnected else { continue }

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
        activeRealtimeClient.sendAudioChunk(chunk)
    }

    // MARK: - Stop Finalization

    func scheduleStopFinalization() {
        stopFinalizationTask?.cancel()
        stopFinalizationTask = Task { [weak self] in
            guard let self else { return }
            guard self.isFinalizingStop else { return }

            if !self.activeRealtimeClient.isConnected {
                self.debugLog("socket already disconnected before final commit; finishing stop")
                self.finishStoppedSession(promotePendingSegment: true)
                return
            }
            let startedAt = Date()
            self.realtimeFinalizationLastActivityAt = startedAt
            self.activeRealtimeClient.sendCommit(final: true)
            while self.isFinalizingStop {
                if !self.activeRealtimeClient.isConnected {
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
                    self.activeRealtimeClient.disconnect()
                    self.finishStoppedSession(promotePendingSegment: true)
                    return
                }

                if elapsed >= TimingConstants.finalizationMinimumOpen,
                   inactivity >= TimingConstants.finalizationInactivityThreshold
                {
                    self.debugLog(
                        "realtime finalization idle for \(String(format: "%.2f", inactivity))s; disconnecting"
                    )
                    self.activeRealtimeClient.disconnect()
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
        cancelRealtimeReconnect()

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
            // The polisher never sees replacement_dictionary.toml (owner
            // ruling 2026-09-18): its `matches` are predictions of recognizer
            // errors, and the model is better off with the user's terms in the
            // About-you block. The file's rules still apply locally below.
            // The `{{replacement_dictionary}}` slot stays: the vocabulary
            // sections ride in it.
            let replacementDictionaryPrompt = ""
            let originalText = currentDictationEventText
            let replacementAppliedText =
                (sessionReplacementDictionary ?? loadEffectiveReplacementDictionary())?
                    .apply(to: originalText) ?? originalText
            // Spoken clipboard-paste macro (Overlay Buffer only): after the
            // replacement dictionary and BEFORE the polish request is built,
            // swap each spoken marker for the env-var-shaped placeholder and
            // read the clipboard once. The placeholder — not the payload —
            // flows through polish and persistence. Both profiles enforce its
            // occurrence count before the real payload is substituted at
            // commit. No marker or setting off: a no-op that never touches the
            // pasteboard.
            let clipboardMacro = StopCommitCoordinator.clipboardPayloadMacro(
                applyingTo: replacementAppliedText,
                settings: settings,
                pasteboardReader: dependencies.pasteboardReader
            )
            let workingText = clipboardMacro.placeholderText
            let clipboardPayload = clipboardMacro.payload
            let payloadProvenanceSummary = clipboardMacro.summary
            // In Mistral mode the endpoint is pinned, so the only way to get no
            // configuration is a missing key — and "set a valid endpoint URL"
            // would send the user hunting for a field that is not on the pane.
            let llmConfigurationFailure: (message: String, technicalDetails: String?)? =
                settings.llmPolishingEnabled && polishingConfig == nil
                ? (
                    settings.polishingBackendMode == .mistralAPI
                        ? "Mistral API key missing. Add it in Settings → Engines."
                        : "Set a valid LLM polishing endpoint URL in Settings.",
                    settings.polishingBackendMode == .mistralAPI
                        ? "No Mistral API key is configured; the polish request was not sent."
                        : "Settings value could not be normalized to an HTTP endpoint URL."
                )
                : nil

            // Display the payload-substituted text (placeholder never shown to
            // the user); with no macro this is exactly `workingText`.
            let displayWorkingText = StopCommitCoordinator.substitutingPayload(
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
                    .withSpeakerProfile(settings.polishSpeakerProfile, terms: settings.polishSpeakerTerms)

                statusText = StatusStrings.polishing
                debugLog("LLM polishing started for \(workingText.count) chars")

                // The world as it was at stop: clipboard, screen, join and
                // pane, sampled together before the task's awaits.
                let capture = StopCommitCoordinator.capture(
                    endpointURL: polishingConfig?.endpointURL,
                    settings: settings,
                    context: context,
                    pasteboardReader: dependencies.pasteboardReader
                )

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
                    capture.clipboardContext != nil
                    || capture.screenDecision.vocabularyGroundingText != nil
                    || capture.claudeJoin != nil

                polishAndCommitTask = Task { @MainActor [weak self] in
                    guard let self else { return }

                    // Everything the request is built from, gathered in one
                    // step with the same off-actor hops and checkpoints; nil
                    // means the commit was cancelled at one of them.
                    guard let material = await PolishContextGatherer.gather(PolishContextGatherer.Input(
                        settings: self.settings,
                        textInsertion: self.textInsertion,
                        context: self.context,
                        repoVocabularyGrounding: self.repoVocabularyGrounding,
                        learnedTermStore: self.learnedTermStore,
                        endpointURL: polishingConfig?.endpointURL,
                        workingText: workingText,
                        capturedScreenDecision: capture.screenDecision,
                        capturedSocketPaneStart: capture.socketPaneStart,
                        capturedClaudeJoin: capture.claudeJoin,
                        capturedClipboardContext: capture.clipboardContext,
                        templateCarriesDictionarySlot: templateCarriesDictionarySlot,
                        needsRepoGroundingForConflictSafety: needsRepoGroundingForConflictSafety
                    )) else { return }
                    let screenDecision = material.screenDecision
                    let claudeRepoSnapshot = material.claudeRepoSnapshot
                    let clipboardRenderBudget = material.clipboardRenderBudget
                    let screenRenderBudget = material.screenRenderBudget
                    let repoRenderBudget = material.repoRenderBudget
                    let claudeRenderBudget = material.claudeRenderBudget
                    let claudeRepoPreparation = material.claudeRepoPreparation
                    let claudeSessionPreparation = material.claudeSessionPreparation
                    let clipboardPreparation = material.clipboardPreparation
                    let screenPreparation = material.screenPreparation
                    let learnedProject = material.learnedProject
                    let merged = material.merged

                    guard !Task.isCancelled else { return }

                    // What this dictation taught, remembered for the next one
                    // in the same project. Recorded from the MERGED entries
                    // and nowhere else: a span the merge abstained on is not
                    // evidence of a spelling, and a verification pair is a
                    // question put to the model, not an answer.
                    self.recordLearnedTerms(merged: merged, project: learnedProject)

                    // Sections, pre-application, prompts, blocks and provenance
                    // are one pure step over the merged material; the request
                    // it builds is pinned by PolishRequestGoldenTests.
                    let assembly = PolishRequestAssembler.assemble(PolishRequestAssembler.Input(
                        merged: merged,
                        templateCarriesDictionarySlot: templateCarriesDictionarySlot,
                        replacementDictionaryPrompt: replacementDictionaryPrompt,
                        workingText: workingText,
                        clipboardPayload: clipboardPayload,
                        promptTemplates: promptTemplates,
                        screenDecision: screenDecision,
                        claudeRepoSnapshot: claudeRepoSnapshot,
                        claudeRepoPreparation: claudeRepoPreparation,
                        claudeSessionPreparation: claudeSessionPreparation,
                        clipboardPreparation: clipboardPreparation,
                        screenPreparation: screenPreparation,
                        capturedClaudeJoin: capture.claudeJoin,
                        capturedClipboardContext: capture.clipboardContext,
                        repoRenderBudget: repoRenderBudget,
                        screenRenderBudget: screenRenderBudget,
                        claudeRenderBudget: claudeRenderBudget,
                        clipboardRenderBudget: clipboardRenderBudget
                    ))
                    let polishingRequest = assembly.request
                    let groundedWorkingText = assembly.groundedWorkingText
                    let capturedPolishContextSummary = assembly.polishContextSummary
                    let repoVocabularyCount = assembly.repoVocabularyCount
                    let clipboardVocabularyCount = assembly.clipboardVocabularyCount

                    var processedTextForPersistence: String? =
                        workingText != originalText ? workingText : nil
                    var polishingDuration: Double? = nil
                    var sessionStatus: DictationSessionStatus = .completed
                    var llmConnectionFailure: PolishOutcomeClassifier.Failure?
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
                            //
                            // Placeholder-count integrity stays independent of
                            // that trust: a duplicated placeholder would paste
                            // the payload twice, while dropping one of two
                            // would lose a requested paste. It is the classifier
                            // that compares standalone counts against the
                            // grounded pre-polish text and, on mismatch,
                            // discards the polish and returns that
                            // placeholder-bearing text.
                            let committedText = PolishOutcomeClassifier.committedText(
                                polished: result.polishedText,
                                groundedWorkingText: groundedWorkingText,
                                clipboardPayload: clipboardPayload
                            )

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

                            self.currentDictationEventText = StopCommitCoordinator.substitutingPayload(
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
                            llmConnectionFailure = PolishOutcomeClassifier.failure(
                                for: error,
                                endpointURL: config.endpointURL
                            )
                            Log.polishing.error(
                                "LLM polishing failed: \(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }

                    guard !Task.isCancelled else { return }

                    let overlayCommit = StopCommitCoordinator.commit(
                        overlay: self.overlayBufferCoordinator,
                        textInsertion: self.textInsertion,
                        autoCopyEnabled: self.settings.autoCopyEnabled
                    )
                    if let failureMessage = overlayCommit.failureMessage {
                        self.lastError = failureMessage
                    }

                    self.completeStoppedSessionCleanup(
                        sessionMode: sessionMode,
                        overlayCommitOutcome: overlayCommit.outcome,
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
                        commitSucceeded: overlayCommit.succeeded,
                        polishProfile: capturedPolishProfile,
                        polishContextSummary: self.mergedPolishProvenanceSummary(
                            context: capturedPolishContextSummary,
                            payload: payloadProvenanceSummary,
                            vocabulary: StopCommitCoordinator.vocabularyProvenance(
                                repoVocabularyCount: repoVocabularyCount,
                                clipboardVocabularyCount: clipboardVocabularyCount
                            )
                        )
                    )

                    #if LOCALVOXTRAL_DOGFOOD
                    // AFTER the commit and the session record: capture latency
                    // can only ever land on the tail of this task, never on the
                    // user's paste. `writeDogfoodCaptureIfArmed` checks the
                    // runtime opt-in before doing any work.
                    await self.writeDogfoodCaptureIfArmed(
                        StopCommitCoordinator.dogfoodCaptureInputs(
                            material: material,
                            assembly: assembly,
                            capture: capture,
                            targetBundleID: capturedTargetBundleID,
                            targetIsTerminalLike: self.sessionTargetIsTerminalLike,
                            outputMode: capturedOutputMode,
                            promptProfile: capturedPolishProfile,
                            polishingEndpointURL: polishingConfig?.endpointURL,
                            polishModel: polishingConfig?.model,
                            rawTranscript: originalText,
                            workingText: workingText,
                            polishedOutput: dogfoodPolishedOutput,
                            committedText: dogfoodCommittedText,
                            polishSeconds: polishingDuration
                        ),
                        commitOutcome: overlayCommit.outcome,
                        // Substituted for MEASUREMENT only (the watch window
                        // scales with what was inserted); the record keeps the
                        // placeholder-bearing text above.
                        committedTextForWatch: StopCommitCoordinator.substitutingPayload(
                            dogfoodCommittedText ?? groundedWorkingText,
                            payload: clipboardPayload
                        )
                    )
                    #endif

                    if let llmConnectionFailure {
                        self.handleLLMPolishingConnectionFailure(
                            title: llmConnectionFailure.title,
                            message: llmConnectionFailure.message,
                            technicalDetails: llmConnectionFailure.technicalDetails
                        )
                    }
                }
                return
            }

            // Non-polishing overlay commit path
            let overlayCommit = StopCommitCoordinator.commit(
                overlay: overlayBufferCoordinator,
                textInsertion: textInsertion,
                autoCopyEnabled: settings.autoCopyEnabled
            )
            if let failureMessage = overlayCommit.failureMessage {
                lastError = failureMessage
            }

            completeStoppedSessionCleanup(
                sessionMode: sessionMode,
                overlayCommitOutcome: overlayCommit.outcome,
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
                commitSucceeded: overlayCommit.succeeded,
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
        // The user's terms carry casing rules even with the dictionary toggle
        // off. Nothing to apply and not a terminal keeps the no-session path:
        // no hold-back, no delay.
        let dictionary = replacementDictionaryForCurrentSession()
        guard dictionary != nil || sessionTargetIsTerminalLike else {
            textInsertion.endLiveReplacementSession()
            return
        }

        overlayBufferCoordinator.captureLiveCommitTargetAppPID()
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
        context.discardTerminalScreenCapture()
        clearLatchedSessionMetadata()
        if holdFailureIndicatorUntilStopCompletes {
            holdFailureIndicatorUntilStopCompletes = false
            markRecentConnectionFailureIndicator()
        } else {
            setRealtimeIndicatorIdle()
        }
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
        guard let pid = overlayBufferCoordinator.commitTargetAppPID else { return nil }
        return dependencies.bundleIdentifier(pid)
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

    /// The repository vocabulary for this commit, through the injected or
    /// production grounding.
    func repoVocabularyGroundingIfEnabled(
        endpointURL: URL,
        transcript: String,
        repositoryRoot: RepoVocabularyRootBox? = nil
    ) async -> RepoVocabularyMatcher.GroundingOutcome? {
        await PolishContextGatherer.repoVocabularyGroundingIfEnabled(
            settings: settings,
            grounding: repoVocabularyGrounding,
            endpointURL: endpointURL,
            transcript: transcript,
            repositoryRoot: repositoryRoot
        )
    }

    /// Folds one dictation's resolved spellings into the learned terms.
    ///
    /// Cheap enough for the commit path: an in-memory merge. The file write is
    /// the store's own background work.
    /// A nil `project` means the app could not establish which project this
    /// dictation belongs to, and nothing is learned from it — see
    /// `LearnedTermProjectResolver.resolve`.
    func recordLearnedTerms(
        merged: PolishContextGrounding.Merged,
        project: LearnedTermProjectResolver.Identity?
    ) {
        guard let learnedTermStore, let project else { return }
        let observations = PolishContextSource.allCases.flatMap { source in
            merged.entries(from: source).map {
                LearnedTermObservation(term: $0.replaceWith, source: source)
            }
        }
        guard !observations.isEmpty else { return }
        learnedTermStore.record(observations, project: project)
    }


    /// Polishing prompt profile for a stop-commit: `.agent` iff the user has the
    /// agent profile enabled AND the captured target bundle ID is terminal-like
    /// (built-in terminal allowlist, or the user's Settings → Terminals list —
    /// the successor of `terminal_apps.toml`). Mirrors the live-mode target
    /// combination (allowlist + user bundle IDs); the AX-probe verdict is
    /// deliberately not consulted here — the polish switch keys off the app
    /// identity, not the focused field's writability.
    func selectedPolishProfile(forTargetBundleID bundleID: String?) -> PolishPromptProfile {
        guard settings.agentPolishProfileEnabled else { return .standard }
        guard let bundleID, !bundleID.isEmpty else { return .standard }
        if TerminalTargetDetector.isTerminalLikeBundleID(bundleID) { return .agent }
        if settings.userTerminalAppBundleIDs.contains(bundleID) { return .agent }
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
        dependencies.onSessionRecord?(record)
        let retention = settings.dictationHistoryRetention
        guard retention.savesDictations else {
            Log.persistence.debug("Dictation history is off: not saving this dictation")
            // Turning history off deleted what was there. If that write
            // failed, this is what tries again.
            applyDictationHistoryRetention(now: record.finishedAt)
            return
        }
        sessionStore?.save(record)
        if let cutoff = retention.cutoff(now: record.finishedAt) {
            sessionStore?.trim(olderThan: cutoff)
        }
        termSuggestionCadence?.dictationSaved()
    }

    /// Brings the store in line with the retention setting: at launch, and
    /// when the setting changes. `off` deletes everything there is.
    func applyDictationHistoryRetention(now: Date = Date()) {
        let retention = settings.dictationHistoryRetention
        if !retention.savesDictations {
            // A pass already reading the history would send it to the hosted
            // model after the user said not to keep it.
            termSuggestions.stop()
        }
        guard let cutoff = retention.cutoff(now: now) else { return }
        sessionStore?.trim(olderThan: cutoff)
    }

    func replacementDictionaryForCurrentSession() -> ReplacementDictionary? {
        if let sessionReplacementDictionary {
            return sessionReplacementDictionary
        }
        let dictionary = loadEffectiveReplacementDictionary()
        sessionReplacementDictionary = dictionary
        return dictionary
    }

    /// Everything applied to the transcript without a model: the file's rules
    /// when exact replacement is on, then the casing rules of the user's
    /// terms. Nil when there is nothing to apply.
    func loadEffectiveReplacementDictionary() -> ReplacementDictionary? {
        let fileEntries = settings.replacementDictionaryEnabled
            ? appConfigStore.loadReplacementDictionary()
            : ReplacementDictionary(entries: [])
        let effective = fileEntries.adding(speakerTerms: settings.polishSpeakerTerms)
        return effective.entries.isEmpty ? nil : effective
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
        context.closeRemoteHerdrForwards()
        cancelConnectTimeout()
        cancelRealtimeReconnect()
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = nil
        shortcuts.clearPushToTalkShortcutSessionAttempt()
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
        audioDucking.restoreAfterSession()
        realtimeFinalizationLastActivityAt = nil
        firstChunkPreprocessor.reset()
        textInsertion.endLiveReplacementSession()
        overlayBufferCoordinator.reset()
        if disconnectSocket {
            activeRealtimeClient.disconnect()
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

    /// The mic the dictation was capturing from was unplugged. The text
    /// captured so far still finalizes and commits; the menu bar icon stays
    /// red through that and for the usual failure window after it.
    func stopDictationForUnavailableMicrophone() {
        Log.dictation.error(
            "Selected microphone became unavailable during dictation; dictation stopped. Reconnect it or select another input."
        )
        stopDictation(reason: "selected input unavailable")
        lastError = Self.microphoneDisconnectedMessage
        holdFailureIndicatorUntilStopCompletes = isFinalizingStop
        markRecentConnectionFailureIndicator()
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

    func handleLLMPolishingConnectionFailure(
        title: String = "LLM Polishing Connection Failed",
        message: String,
        technicalDetails: String? = nil
    ) {
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
            title: title,
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
        dependencies.connectionFailurePresenter.present(
            title: title,
            message: message,
            technicalDetails: technicalDetails
        )
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

    /// Strips credentials, query, and fragment from a URL for safe logging.
    private func sanitizedURLForLogging(_ url: URL) -> String {
        URLLogSanitizer.sanitized(url)
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

    func startStopFinalizationWatchdog() {
        finalizationWatchdogTask?.cancel()
        let timeout: TimeInterval = TimingConstants.stopFinalizationTimeout + 2.0

        finalizationWatchdogTask = Task { [weak self] in
            let startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TimingConstants.finalizationPollInterval))
                guard let self else { return }
                guard self.isFinalizingStop else { return }

                if !self.activeRealtimeClient.isConnected {
                    self.debugLog("watchdog observed disconnected socket during finalization; finishing stop")
                    self.finishStoppedSession(promotePendingSegment: true)
                    return
                }

                if Date().timeIntervalSince(startedAt) >= timeout {
                    self.debugLog("finalization watchdog fired after \(timeout)s; forcing stop cleanup")
                    self.activeRealtimeClient.disconnect()
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

