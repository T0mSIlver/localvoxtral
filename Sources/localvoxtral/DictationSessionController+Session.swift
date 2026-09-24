import AppKit
import Foundation
import Synchronization
import os

extension DictationSessionController {
    // MARK: - Session Lifecycle

    // Session metadata lifecycle:
    // - Set: prepareDictationSession(outputMode:) — captures values that should
    //   stay stable for the active session even if Settings are edited before commit finishes.
    // - Cleared: finishStoppedSession(), abortConnectingSession(), and early-return
    //   error paths in prepareDictationSession() where no session was established.
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
                await self?.mirrorManagedStartupStatus(
                    statusUpdates,
                    startupTaskID: startupTaskID,
                    dictation: needsManagedDictation,
                    polishing: needsManagedPolishing
                )
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

    /// Shows the managed backends' progress (a model download, a start) on
    /// the status line while a start waits for them. Ends when the start it
    /// belongs to ends or is superseded.
    private func mirrorManagedStartupStatus(
        _ statusUpdates: AsyncStream<ManagedBackendStatusUpdate>,
        startupTaskID: UUID,
        dictation needsManagedDictation: Bool,
        polishing needsManagedPolishing: Bool
    ) async {
        for await _ in statusUpdates {
            if Task.isCancelled || managedStartupTaskID != startupTaskID {
                return
            }
            guard (!needsManagedDictation || settings.dictationBackendMode == .managedLocal),
                  (!needsManagedPolishing
                      || (settings.llmPolishingEnabled
                          && settings.polishingBackendMode == .managedLocal)),
                  isConnectingRealtimeSession
            else { continue }
            statusText = managedBackendStartupStatusText(
                dictation: needsManagedDictation,
                polishing: needsManagedPolishing
            )
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

    /// A session start: prepare, then connect. Nothing suspends between the
    /// two halves, so the socket dials exactly the configuration the start
    /// snapshotted.
    func beginDictationSession(outputMode: DictationOutputMode? = nil) async {
        guard let configuration = await prepareDictationSession(outputMode: outputMode) else {
            return
        }
        connectDictationSession(configuration)
    }

    /// Everything a start does before the socket opens: the resets, the
    /// settings snapshot the connect dials (endpoint, key, model), the checks
    /// that can refuse the start, and the samples taken while the app the
    /// user dictates into is still frontmost. Nil means the start ended here,
    /// after reporting why and cleaning up.
    func prepareDictationSession(
        outputMode: DictationOutputMode? = nil
    ) async -> RealtimeSessionConfiguration? {
        let requestedOutputMode = outputMode ?? settings.dictationOutputMode
        resetForNewSessionAttempt(outputMode: requestedOutputMode)

        let provider = settings.realtimeProvider
        guard let endpoint = settings.resolvedWebSocketURL(for: provider) else {
            handleConnectFailure(reason: .invalidEndpoint)
            clearLatchedSessionMetadata()
            return nil
        }

        if !selectedInputDeviceID.isEmpty,
           !availableInputDevices.contains(where: { $0.id == selectedInputDeviceID })
        {
            statusText = "Selected microphone unavailable."
            lastError = "Selected microphone is unavailable. Reconnect it or choose another input."
            clearLatchedSessionMetadata()
            return nil
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

        let accessibilityBlockedAtStart = surfaceLiveAutoPasteAccessibilityWarningIfNeeded()

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
            return nil
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
            return nil
        }
        refreshInsertionScalarTracingForSession()

        audio.audioChunkBuffer.clear()
        transcript.resetForNewSession()
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

        return RealtimeSessionConfiguration(
            endpoint: endpoint,
            apiKey: apiKey,
            model: model
        )
    }

    /// Opens the socket for a prepared start, and arms its timeout. It dials
    /// exactly the configuration it is handed and checks nothing, so its
    /// callers are `beginDictationSession` and the one test that needs the
    /// gap between the halves.
    func connectDictationSession(_ configuration: RealtimeSessionConfiguration) {
        // Latched, not rebuilt: a mid-session reconnect (#380) dials exactly
        // what this session opened with, even if Settings moved on since.
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

    /// Clears what the previous attempt left behind, and latches this one's
    /// output mode, start time and replacement dictionary.
    private func resetForNewSessionAttempt(outputMode requestedOutputMode: DictationOutputMode) {
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
        clearLatchedSessionMetadata()
        sessionOutputMode = requestedOutputMode
        sessionStartedAt = Date()
        sessionReplacementDictionary = StopCommitCoordinator.effectiveReplacementDictionary(
            settings: settings,
            appConfigStore: appConfigStore
        )
        setRealtimeIndicatorIdle()
    }

    /// Fail fast on Live Auto-Paste without Accessibility trust: transcribed
    /// text would have nowhere to go. Refresh trust once (the user may have
    /// just granted it), then warn + prompt before opening the socket. We do
    /// NOT abort — the keyboard-event fallback can still type into some apps,
    /// and the prompt's polling clears the warning once Accessibility lands.
    /// The warning is surfaced both as the status line and the red error in
    /// the popover, so it can't be missed before the user speaks.
    /// Returns whether the warning is up.
    private func surfaceLiveAutoPasteAccessibilityWarningIfNeeded() -> Bool {
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
        return accessibilityBlockedAtStart
    }

    func startAudioCaptureAfterConnection() {
        let preferredInputID = selectedInputDeviceID.isEmpty ? nil : selectedInputDeviceID
        do {
            let chunkBuffer = audio.audioChunkBuffer
            try audio.startSessionAudioCapture(preferredDeviceID: preferredInputID) { chunk in
                chunkBuffer.append(chunk)
            }

            isConnectingRealtimeSession = false
            isDictating = true
            // Here, not at connect: a connect that times out or is refused
            // must never leave other audio down. Both output modes duck.
            audio.audioDucking.duckForSessionStart()
            escapeCancelHandler.start()
            applyPreCapturedSessionTargetVerdict()
            statusText = "Listening..."
            audio.restartAudioSendTask(
                client: activeRealtimeClient,
                debugLoggingEnabled: debugLoggingEnabled,
                sleep: dependencies.clock.sleep
            )
            audio.restartCommitTask(client: activeRealtimeClient, sleep: dependencies.clock.sleep)
            if isLiveAutoPasteModeEnabled {
                textInsertion.restartInsertionRetryTask { [weak self] in
                    self?.acceptsRealtimeEvents ?? false
                }
            } else {
                textInsertion.stopInsertionRetryTask()
            }
            armSilenceAutoStopIfEnabled()
            if isOverlayBufferModeEnabled {
                startOverlayBufferSession()
            } else {
                overlayBufferCoordinator.reset()
                configureLiveAutoPasteReplacementCorrectorForSession()
            }
            // The monitor's recovery restarts the microphone, which would mix
            // the room into a session that is fed from a file.
            if audio.capturesFromMicrophone {
                audio.healthMonitor.start(
                    microphone: audio.microphone,
                    callbacks: makeHealthMonitorCallbacks()
                )
            }
        } catch {
            statusText = "Failed to start dictation."
            lastError = error.localizedDescription
            isConnectingRealtimeSession = false
            isDictating = false
            escapeCancelHandler.stop()
            audio.healthMonitor.stop()
            audio.stopSessionAudioCapture()
            audio.audioDucking.restoreAfterSession()
            activeRealtimeClient.disconnect()
            setRealtimeIndicatorIdle()
            Log.dictation.error("Failed to start microphone after realtime connect: \(error.localizedDescription, privacy: .public)")
            debugLog("startAudioCaptureAfterConnection failed error=\(error.localizedDescription)")
        }
    }

    func makeHealthMonitorCallbacks() -> AudioCaptureHealthMonitor.Callbacks {
        let chunkBuffer = audio.audioChunkBuffer
        let mic = audio.microphone
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
            let clock = self.dependencies.clock
            let startedAt = clock.now()
            self.realtimeFinalizationLastActivityAt = startedAt
            self.activeRealtimeClient.sendCommit(final: true)
            while self.isFinalizingStop {
                if !self.activeRealtimeClient.isConnected {
                    self.debugLog("socket disconnected during finalization; finishing stop")
                    self.finishStoppedSession(promotePendingSegment: true)
                    return
                }

                let now = clock.now()
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

                await clock.sleep(.seconds(TimingConstants.finalizationPollInterval))
            }
        }
    }

    // MARK: - Connect Timeout

    func scheduleConnectTimeout() {
        cancelConnectTimeout()
        let timeout = TimingConstants.connectTimeout
        let clock = dependencies.clock
        connectTimeoutTask = Task { [weak self] in
            await clock.sleep(.seconds(timeout))
            guard let self, self.isConnectingRealtimeSession else { return }

            await self.resolveConnectTimeout(
                timeoutSeconds: timeout,
                sleepFor: { await clock.sleep(.seconds($0)) }
            )
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
        disarmSilenceAutoStop()
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
        audio.stopMicrophoneIfInitialized()
        audio.audioDucking.restoreAfterSession()
        realtimeFinalizationLastActivityAt = nil
        firstChunkPreprocessor.reset()
        textInsertion.endLiveReplacementSession()
        overlayBufferCoordinator.reset()
        if disconnectSocket {
            activeRealtimeClient.disconnect()
        }
        audio.healthMonitor.stop()
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
        recentFailureResetTask = Task { [weak self, clock = dependencies.clock] in
            await clock.sleep(.seconds(indicatorDuration))
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
        sleepFor: (TimeInterval) async -> Void
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

        finalizationWatchdogTask = Task { [weak self, clock = dependencies.clock] in
            let startedAt = clock.now()
            while !Task.isCancelled {
                await clock.sleep(.seconds(TimingConstants.finalizationPollInterval))
                guard let self else { return }
                guard self.isFinalizingStop else { return }

                if !self.activeRealtimeClient.isConnected {
                    self.debugLog("watchdog observed disconnected socket during finalization; finishing stop")
                    self.finishStoppedSession(promotePendingSegment: true)
                    return
                }

                if clock.now().timeIntervalSince(startedAt) >= timeout {
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

