import AppKit
import Foundation
import os

extension DictationViewModel {
    // MARK: - Session Lifecycle

    func beginDictationSession() {
        stopFinalizationTask?.cancel()
        stopFinalizationTask = nil
        cancelConnectTimeout()
        isFinalizingStop = false
        isConnectingRealtimeSession = false
        setRealtimeIndicatorIdle()

        let provider = settings.realtimeProvider
        guard let endpoint = settings.resolvedWebSocketURL(for: provider) else {
            let message = "Set a valid `ws://` or `wss://` endpoint for the selected backend in Settings."
            handleConnectFailure(
                status: "Invalid endpoint URL.",
                message: message,
                technicalDetails: "Settings value could not be normalized to a websocket endpoint URL."
            )
            return
        }

        if !selectedInputDeviceID.isEmpty,
           !availableInputDevices.contains(where: { $0.id == selectedInputDeviceID })
        {
            statusText = "Selected microphone unavailable."
            lastError = "Selected microphone is unavailable. Reconnect it or choose another input."
            return
        }

        let model = settings.effectiveModelName(for: provider)
        let client = selectedRealtimeClient()
        let source = selectedClientSource()
        inactiveRealtimeClient(for: source).disconnect()
        let preferredInputID = selectedInputDeviceID.isEmpty ? nil : selectedInputDeviceID

        audioChunkBuffer.clear()
        livePartialText = ""
        pendingSegmentText = ""
        currentDictationEventText = ""
        mlxStabilizer.reset()
        realtimeFinalizationLastActivityAt = nil
        textInsertion.clearPendingText()
        textInsertion.resetDiagnostics()

        isConnectingRealtimeSession = true
        activeClientSource = source
        statusText = "Connecting to realtime backend..."
        debugLog(
            "beginDictationSession endpoint=\(endpoint.absoluteString) model=\(model) input=\(preferredInputID ?? "default")"
        )

        do {
            try client.connect(configuration: .init(
                endpoint: endpoint,
                apiKey: settings.trimmedAPIKey,
                model: model,
                transcriptionDelayMilliseconds: provider == .mlxAudio
                    ? settings.mlxAudioTranscriptionDelayMilliseconds
                    : nil
            ))
            scheduleConnectTimeout()
        } catch {
            abortConnectingSession(disconnectSocket: false)
            handleConnectFailure(
                status: "Failed to connect.",
                message: "Unable to start the realtime connection.",
                technicalDetails: error.localizedDescription
            )
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
            statusText = "Listening..."
            restartAudioSendTask()
            restartCommitTask()
            if settings.autoPasteIntoInputFieldEnabled {
                textInsertion.restartInsertionRetryTask { [weak self] in
                    self?.acceptsRealtimeEvents ?? false
                }
            } else {
                textInsertion.stopInsertionRetryTask()
            }
            healthMonitor.start(microphone: microphone, callbacks: makeHealthMonitorCallbacks())
        } catch {
            statusText = "Failed to start dictation."
            lastError = error.localizedDescription
            isConnectingRealtimeSession = false
            isDictating = false
            healthMonitor.stop()
            microphone.stop()
            activeRealtimeClient().disconnect()
            activeClientSource = nil
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
        let client = activeRealtimeClient()
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

        let interval = audioSendInterval
        let client = activeRealtimeClient()
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
        activeRealtimeClient().sendAudioChunk(chunk)
    }

    // MARK: - Stop Finalization

    func scheduleStopFinalization() {
        stopFinalizationTask?.cancel()
        stopFinalizationTask = Task { [weak self] in
            guard let self else { return }
            if self.activeClientSource == .mlxAudio {
                await self.sendTrailingSilenceForMlxAudio()
            }
            guard self.isFinalizingStop else { return }

            if self.activeClientSource != .mlxAudio {
                let startedAt = Date()
                self.realtimeFinalizationLastActivityAt = startedAt
                self.activeRealtimeClient().sendCommit(final: true)
                while self.isFinalizingStop {
                    let now = Date()
                    let elapsed = now.timeIntervalSince(startedAt)
                    let lastActivity = self.realtimeFinalizationLastActivityAt ?? startedAt
                    let inactivity = now.timeIntervalSince(lastActivity)

                    if elapsed >= self.stopFinalizationTimeoutSeconds {
                        self.debugLog("stop finalization timeout (\(self.stopFinalizationTimeoutSeconds)s); forcing disconnect")
                        self.activeRealtimeClient().disconnect()
                        self.finishStoppedSession(promotePendingSegment: true)
                        return
                    }

                    if elapsed >= self.realtimeFinalizationMinimumOpenSeconds,
                       inactivity >= self.realtimeFinalizationInactivitySeconds
                    {
                        self.debugLog(
                            "realtime finalization idle for \(String(format: "%.2f", inactivity))s; disconnecting"
                        )
                        self.activeRealtimeClient().disconnect()
                        self.finishStoppedSession(promotePendingSegment: true)
                        return
                    }

                    try? await Task.sleep(for: .seconds(self.finalizationPollIntervalSeconds))
                }
                return
            }

            let timeout = self.mlxStopFinalizationTimeoutSeconds
            try? await Task.sleep(for: .seconds(timeout))
            guard self.isFinalizingStop else { return }
            self.debugLog("stop finalization timeout (\(timeout)s); forcing disconnect")
            self.activeRealtimeClient().disconnect()
            self.finishStoppedSession(promotePendingSegment: true)
        }
    }

    func sendTrailingSilenceForMlxAudio() async {
        guard activeClientSource == .mlxAudio else { return }
        let frameCount = max(1, Int(16_000 * mlxTrailingSilenceChunkDurationSeconds))
        let silenceChunk = Data(count: frameCount * MemoryLayout<Int16>.size)
        let iterations = max(1, Int(ceil(mlxTrailingSilenceDurationSeconds / mlxTrailingSilenceChunkDurationSeconds)))
        debugLog("send mlx trailing silence chunks=\(iterations)")
        for _ in 0 ..< iterations {
            guard isFinalizingStop, activeClientSource == .mlxAudio else { return }
            activeRealtimeClient().sendAudioChunk(silenceChunk)
            try? await Task.sleep(for: .seconds(mlxTrailingSilenceChunkDurationSeconds))
        }
    }

    func finishStoppedSession(promotePendingSegment: Bool) {
        stopFinalizationTask?.cancel()
        stopFinalizationTask = nil
        cancelConnectTimeout()

        let wasMlxAudio = activeClientSource == .mlxAudio

        if promotePendingSegment {
            let promoted = wasMlxAudio
                ? promotePendingMlxTextToLatestSegment()
                : promotePendingRealtimeTextToLatestSegment()

            if wasMlxAudio, let promoted, !promoted.isEmpty {
                if settings.autoPasteIntoInputFieldEnabled {
                    if !textInsertion.insertTextUsingAccessibilityOnly(promoted) {
                        _ = textInsertion.pasteUsingCommandV(promoted)
                    }
                }
            }
        }

        isFinalizingStop = false
        isConnectingRealtimeSession = false
        realtimeFinalizationLastActivityAt = nil
        setRealtimeIndicatorIdle()
        livePartialText = ""
        pendingSegmentText = ""
        mlxStabilizer.resetSegment()
        statusText = "Ready"
        activeClientSource = nil

        textInsertion.stopInsertionRetryTask()
        textInsertion.logDiagnostics()

        if textInsertion.hasPendingInsertionText {
            lastError = "Some realtime text could not be inserted into the focused app."
            textInsertion.clearPendingText()
        }

        if lastError?.localizedCaseInsensitiveContains("websocket receive failed") == true {
            lastError = nil
        }
    }

    // MARK: - Connect Timeout

    func scheduleConnectTimeout() {
        cancelConnectTimeout()
        let timeout = connectTimeoutSeconds
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, self.isConnectingRealtimeSession else { return }

            abortConnectingSession()
            let message = "Could not connect to realtime backend within \(Int(timeout)) seconds."
            handleConnectFailure(
                status: "Connection timed out.",
                message: message,
                technicalDetails: connectTimeoutTechnicalDetails(timeoutSeconds: timeout)
            )
        }
    }

    func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    func abortConnectingSession(disconnectSocket: Bool = true) {
        cancelConnectTimeout()
        isConnectingRealtimeSession = false
        isDictating = false
        isAwaitingMicrophonePermission = false
        microphone.stop()
        realtimeFinalizationLastActivityAt = nil
        if disconnectSocket {
            activeRealtimeClient().disconnect()
        }
        activeClientSource = nil
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
        let indicatorDuration = recentFailureIndicatorSeconds
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

    func handleConnectFailure(status: String, message: String, technicalDetails: String? = nil) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMessage = trimmedMessage.isEmpty ? "Unable to establish realtime connection." : trimmedMessage
        let resolvedDetails = normalizedFailureDetails(technicalDetails)

        statusText = status
        lastError = resolvedDetails ?? resolvedMessage
        logConnectionFailure(message: resolvedMessage, technicalDetails: resolvedDetails)
        markRecentConnectionFailureIndicator()
        presentConnectionFailureAlert(message: resolvedMessage)
    }

    func presentConnectionFailureAlert(message: String) {
        guard !message.isEmpty else { return }
        guard !isShowingConnectionFailureAlert else { return }

        isShowingConnectionFailureAlert = true
        defer { isShowingConnectionFailureAlert = false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Realtime Connection Failed"
        alert.informativeText = message
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

    // MARK: - Client Selection

    func selectedClientSource() -> ActiveClientSource {
        switch settings.realtimeProvider {
        case .realtimeAPI:
            return .realtimeAPI
        case .mlxAudio:
            return .mlxAudio
        }
    }

    func selectedRealtimeClient() -> RealtimeClient {
        switch selectedClientSource() {
        case .realtimeAPI:
            return realtimeAPIClient
        case .mlxAudio:
            return mlxAudioRealtimeClient
        }
    }

    func activeRealtimeClient() -> RealtimeClient {
        switch activeClientSource {
        case .realtimeAPI:
            return realtimeAPIClient
        case .mlxAudio:
            return mlxAudioRealtimeClient
        case nil:
            return selectedRealtimeClient()
        }
    }

    func inactiveRealtimeClient(for source: ActiveClientSource) -> RealtimeClient {
        switch source {
        case .realtimeAPI:
            return mlxAudioRealtimeClient
        case .mlxAudio:
            return realtimeAPIClient
        }
    }

    // MARK: - Helpers

    private func openSystemConsole() {
        guard let consoleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            return
        }
        _ = NSWorkspace.shared.open(consoleURL)
    }

    private func sanitizedRealtimeEndpointForLogging() -> String {
        guard let endpoint = settings.resolvedWebSocketURL(for: settings.realtimeProvider) else {
            return "<invalid endpoint>"
        }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint.absoluteString
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? endpoint.absoluteString
    }

    private func normalizedFailureDetails(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func connectTimeoutTechnicalDetails(timeoutSeconds: TimeInterval) -> String {
        let endpoint = sanitizedRealtimeEndpointForLogging()
        return "No connection response received in \(Int(timeoutSeconds)) seconds for endpoint \(endpoint)."
    }
}
