import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import os

@MainActor
@Observable
final class DictationViewModel {
    private enum ActiveClientSource {
        case openAICompatible
        case mlxAudio
    }

    private(set) var isDictating = false
    private(set) var isFinalizingStop = false
    private(set) var transcriptText = ""
    private(set) var livePartialText = ""
    private(set) var statusText = "Ready"
    private(set) var lastError: String?
    private(set) var lastFinalSegment = ""
    private(set) var availableInputDevices: [MicrophoneInputDevice] = []
    private(set) var selectedInputDeviceID = ""

    var isAccessibilityTrusted: Bool { textInsertion.isAccessibilityTrusted }

    let settings: SettingsStore
    let textInsertion = TextInsertionService()

    private let microphone = MicrophoneCaptureService()
    private let networkMonitor = NetworkMonitor()
    private let openAIRealtimeClient = RealtimeWebSocketClient()
    private let mlxAudioRealtimeClient = MlxAudioRealtimeWebSocketClient()
    private var activeClientSource: ActiveClientSource?
    private let audioChunkBuffer = AudioChunkBuffer()
    private let healthMonitor = AudioCaptureHealthMonitor()
    private let audioSendInterval: TimeInterval = 0.1
    private var commitTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var stopFinalizationTask: Task<Void, Never>?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var isAwaitingMicrophonePermission = false
    private var pendingRealtimeFinalizationText = ""
    private var currentDictationEventText = ""
    private let mlxTrailingSilenceDurationSeconds: TimeInterval = 1.6
    private let mlxTrailingSilenceChunkDurationSeconds: TimeInterval = 0.1
    private let stopFinalizationTimeoutSeconds: TimeInterval = 7.0
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

    private var lifecycleObservers: [NSObjectProtocol] = []
    private static let hotKeySignature = OSType(0x53565854) // SVXT
    private static weak var hotKeyTarget: DictationViewModel?

    init(settings: SettingsStore) {
        self.settings = settings

        openAIRealtimeClient.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event, source: .openAICompatible)
            }
        }

        mlxAudioRealtimeClient.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event, source: .mlxAudio)
            }
        }

        microphone.onConfigurationChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.healthMonitor.handleConfigurationChange()
            }
        }

        microphone.onInputDevicesChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.healthMonitor.handleInputDevicesChanged()
            }
        }

        microphone.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastError = message
            }
        }

        textInsertion.onAccessibilityTrustChanged = { [weak self] in
            guard let self else { return }
            if self.lastError == TextInsertionService.accessibilityErrorMessage {
                self.lastError = nil
            }
            if !self.isDictating,
               self.statusText == "Waiting for Accessibility permission."
                || self.statusText == "Paste blocked by Accessibility permission."
            {
                self.statusText = "Ready"
            }
        }

        networkMonitor.onChange = { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.handleNetworkChange(connected: connected)
            }
        }
        networkMonitor.start()

        Self.hotKeyTarget = self
        registerGlobalHotkey()
        textInsertion.refreshAccessibilityTrustState()
        refreshMicrophoneInputs()
        registerLifecycleObservers()
    }

    @MainActor
    deinit {
        Self.hotKeyTarget = nil
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        commitTask?.cancel()
        audioSendTask?.cancel()
        stopFinalizationTask?.cancel()
        textInsertion.stopAllTasks()
        healthMonitor.cancelTasks()
        microphone.stop()
        networkMonitor.stop()
        openAIRealtimeClient.disconnect()
        mlxAudioRealtimeClient.disconnect()
        unregisterGlobalHotkey()
    }

    private func registerGlobalHotkey() {
        unregisterGlobalHotkey()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef else { return noErr }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == DictationViewModel.hotKeySignature,
                      hotKeyID.id == 1
                else {
                    return noErr
                }

                DispatchQueue.main.async {
                    DictationViewModel.hotKeyTarget?.toggleDictation()
                }

                return noErr
            },
            1,
            &eventType,
            nil,
            &hotKeyHandlerRef
        )

        guard installStatus == noErr else {
            statusText = "Failed to register global hotkey handler."
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey) | UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            statusText = "Failed to register global hotkey."
            unregisterGlobalHotkey()
        }
    }

    private func unregisterGlobalHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default

        // Stop dictation when the system is about to sleep — no finalization
        // since the network connection will be lost.
        let sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isDictating else { return }
                self.stopDictation(reason: "system sleep", finalizeRemainingAudio: false)
            }
        }

        // Stop dictation when the app is about to terminate.
        let terminateObserver = nc.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isDictating else { return }
                self.stopDictation(reason: "app terminating", finalizeRemainingAudio: false)
            }
        }

        lifecycleObservers = [sleepObserver, terminateObserver]
    }

    private func handleNetworkChange(connected: Bool) {
        if connected {
            debugLog("network restored")
            // Only update status if we're idle — don't overwrite active dictation status.
            if !isDictating, !isFinalizingStop,
               statusText == "Network lost. Dictation stopped."
                || statusText == "No network connection."
            {
                statusText = "Ready"
                lastError = nil
            }
        } else {
            debugLog("network lost")
            if isDictating {
                // Network is gone — no point trying to finalize over a dead connection.
                stopDictation(reason: "network lost", finalizeRemainingAudio: false)
                statusText = "Network lost. Dictation stopped."
                lastError = "Network connection was lost during dictation."
            } else if isFinalizingStop {
                // Already stopped mic, just abort the finalization attempt.
                activeRealtimeClient().disconnect()
                finishStoppedSession(promotePendingSegment: true)
                statusText = "Network lost. Dictation stopped."
                lastError = "Network connection was lost during dictation."
            } else {
                statusText = "No network connection."
            }
        }
    }

    func toggleDictation() {
        if isDictating {
            stopDictation(reason: "manual toggle")
        } else if isFinalizingStop {
            statusText = "Finalizing previous dictation..."
        } else {
            startDictation()
        }
    }

    func refreshMicrophoneInputs() {
        let devices = microphone.availableInputDevices()
        if availableInputDevices != devices {
            availableInputDevices = devices
        }

        let savedSelection = settings.selectedInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSelection = selectedInputDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitSelection = !savedSelection.isEmpty ? savedSelection : currentSelection

        guard !devices.isEmpty else { return }

        if !explicitSelection.isEmpty,
           devices.contains(where: { $0.id == explicitSelection })
        {
            if selectedInputDeviceID != explicitSelection {
                selectedInputDeviceID = explicitSelection
            }
            if settings.selectedInputDeviceUID != explicitSelection {
                settings.selectedInputDeviceUID = explicitSelection
            }
            return
        }

        let resolvedSelection: String
        if let defaultID = microphone.defaultInputDeviceID(),
           devices.contains(where: { $0.id == defaultID })
        {
            resolvedSelection = defaultID
        } else if let firstDevice = devices.first {
            resolvedSelection = firstDevice.id
        } else {
            return
        }

        if selectedInputDeviceID != resolvedSelection {
            selectedInputDeviceID = resolvedSelection
        }
        if settings.selectedInputDeviceUID != resolvedSelection {
            settings.selectedInputDeviceUID = resolvedSelection
        }
    }

    func selectMicrophoneInput(id: String) {
        guard !id.isEmpty else { return }
        guard selectedInputDeviceID != id else { return }

        selectedInputDeviceID = id
        settings.selectedInputDeviceUID = id

        guard isDictating else { return }
        stopDictation(reason: "input device changed by user", finalizeRemainingAudio: false)
        startDictation()
    }

    func startDictation() {
        guard !isDictating else { return }
        guard !isFinalizingStop else {
            statusText = "Finalizing previous dictation..."
            return
        }
        guard !isAwaitingMicrophonePermission else {
            statusText = "Awaiting microphone permission..."
            return
        }
        guard networkMonitor.isConnected else {
            statusText = "No network connection."
            lastError = "Connect to a network before starting dictation."
            return
        }
        debugLog("startDictation requested")
        refreshMicrophoneInputs()
        if debugLoggingEnabled {
            let inputs = availableInputDevices.map { "\($0.name)=\($0.id)" }.joined(separator: ", ")
            debugLog("available inputs: \(inputs)")
            debugLog("selected input id=\(selectedInputDeviceID)")
        }
        lastError = nil
        let deniedMessage = "Grant microphone access in System Settings > Privacy & Security > Microphone."

        switch microphone.authorizationStatus() {
        case .authorized:
            beginDictationSession()
        case .notDetermined:
            isAwaitingMicrophonePermission = true
            statusText = "Requesting microphone permission..."
            debugLog("microphone permission prompt requested")
            microphone.requestAccess { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isAwaitingMicrophonePermission = false
                    self.debugLog("microphone permission result granted=\(granted)")
                    guard granted else {
                        self.statusText = "Microphone access denied."
                        self.lastError = deniedMessage
                        return
                    }
                    self.beginDictationSession()
                }
            }
            // Safety timeout: reset the awaiting flag if the permission callback
            // never fires (e.g. user dismisses the prompt without choosing).
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard let self, self.isAwaitingMicrophonePermission else { return }
                self.isAwaitingMicrophonePermission = false
                self.statusText = "Ready"
                self.debugLog("microphone permission prompt timed out")
            }
        case .denied, .restricted:
            statusText = "Microphone access denied."
            lastError = deniedMessage
            debugLog("microphone access denied or restricted")
        }
    }

    func stopDictation(reason: String = "unspecified", finalizeRemainingAudio: Bool = true) {
        guard isDictating else { return }
        debugLog("stopDictation reason=\(reason)")

        commitTask?.cancel()
        commitTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        healthMonitor.stop()
        isAwaitingMicrophonePermission = false

        microphone.stop()
        flushBufferedAudio()
        isDictating = false

        guard finalizeRemainingAudio else {
            activeRealtimeClient().disconnect()
            finishStoppedSession(promotePendingSegment: true)
            return
        }

        isFinalizingStop = true
        statusText = "Finalizing..."
        scheduleStopFinalization()
    }

    func clearTranscript() {
        transcriptText = ""
        livePartialText = ""
        lastFinalSegment = ""
        pendingRealtimeFinalizationText = ""
        currentDictationEventText = ""
        lastError = nil
    }

    func copyTranscript() {
        let fullText = fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullText, forType: .string)

        statusText = "Transcript copied."
    }

    func copyLatestSegment(updateStatus: Bool = true) {
        let segment = lastFinalSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(segment, forType: .string)

        if updateStatus {
            statusText = "Latest segment copied."
        }
    }

    func requestAccessibilityPermission() {
        textInsertion.requestAccessibilityPermission()

        if textInsertion.isAccessibilityTrusted {
            statusText = "Ready"
        } else {
            statusText = "Waiting for Accessibility permission."
        }
    }

    func refreshAccessibilityTrustState() {
        let wasTrusted = textInsertion.isAccessibilityTrusted
        textInsertion.refreshAccessibilityTrustState()

        if textInsertion.isAccessibilityTrusted, !wasTrusted, !isDictating,
           statusText == "Waiting for Accessibility permission."
            || statusText == "Paste blocked by Accessibility permission."
        {
            statusText = "Ready"
        }

        if let axError = textInsertion.lastAccessibilityError {
            if lastError == nil || lastError == TextInsertionService.accessibilityErrorMessage {
                lastError = axError
            }
        } else if lastError == TextInsertionService.accessibilityErrorMessage {
            lastError = nil
        }
    }

    func pasteLatestSegment() {
        let segment = lastFinalSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }

        textInsertion.refreshAccessibilityTrustState()

        let directInsertResult = textInsertion.insertText(segment)
        if directInsertResult == .insertedByAccessibility
            || directInsertResult == .insertedByKeyboardFallback
        {
            statusText = "Pasted latest segment."
            return
        }

        if textInsertion.pasteUsingCommandV(segment) {
            statusText = "Pasted latest segment."
            return
        }

        if !textInsertion.isAccessibilityTrusted {
            statusText = "Paste blocked by Accessibility permission."
        } else {
            statusText = "Unable to paste latest segment."
        }
    }

    var fullTranscript: String {
        let finalPart = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let livePart = livePartialText.trimmingCharacters(in: .whitespacesAndNewlines)

        if finalPart.isEmpty { return livePart }
        if livePart.isEmpty { return finalPart }
        return finalPart + "\n" + livePart
    }

    private func beginDictationSession() {
        stopFinalizationTask?.cancel()
        stopFinalizationTask = nil
        isFinalizingStop = false

        let provider = settings.realtimeProvider
        guard let endpoint = settings.resolvedWebSocketURL(for: provider) else {
            statusText = "Invalid endpoint URL."
            lastError = "Set a valid `ws://` or `wss://` endpoint for the selected backend in Settings."
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

        do {
            let chunkBuffer = audioChunkBuffer
            chunkBuffer.clear()
            let preferredInputID = selectedInputDeviceID.isEmpty ? nil : selectedInputDeviceID
            debugLog("beginDictationSession endpoint=\(endpoint.absoluteString) model=\(model) input=\(preferredInputID ?? "default")")
            try microphone.start(preferredDeviceID: preferredInputID) { chunk in
                chunkBuffer.append(chunk)
            }

            isDictating = true
            livePartialText = ""
            pendingRealtimeFinalizationText = ""
            currentDictationEventText = ""
            statusText = "Listening..."
            textInsertion.clearPendingText()
            textInsertion.resetDiagnostics()

            activeClientSource = source
            try client.connect(configuration: .init(
                endpoint: endpoint,
                apiKey: settings.trimmedAPIKey,
                model: model,
                transcriptionDelayMilliseconds: provider == .mlxAudio
                    ? settings.mlxAudioTranscriptionDelayMilliseconds
                    : nil
            ))

            restartAudioSendTask()
            restartCommitTask()
            textInsertion.restartInsertionRetryTask { [weak self] in
                self?.acceptsRealtimeEvents ?? false
            }
            healthMonitor.start(microphone: microphone, callbacks: makeHealthMonitorCallbacks())
        } catch {
            statusText = "Failed to start dictation."
            lastError = error.localizedDescription
            microphone.stop()
            client.disconnect()
            isDictating = false
            healthMonitor.stop()
            activeClientSource = nil
            debugLog("beginDictationSession failed error=\(error.localizedDescription)")
        }
    }

    private func makeHealthMonitorCallbacks() -> AudioCaptureHealthMonitor.Callbacks {
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

    private func restartCommitTask() {
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

    private func restartAudioSendTask() {
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

    private func flushBufferedAudio() {
        let chunk = audioChunkBuffer.takeAll()
        guard !chunk.isEmpty else { return }
        activeRealtimeClient().sendAudioChunk(chunk)
    }

    private var acceptsRealtimeEvents: Bool {
        isDictating || isFinalizingStop
    }

    private func scheduleStopFinalization() {
        stopFinalizationTask?.cancel()
        stopFinalizationTask = Task { [weak self] in
            guard let self else { return }
            if self.activeClientSource == .mlxAudio {
                await self.sendTrailingSilenceForMlxAudio()
            }
            guard self.isFinalizingStop else { return }

            // For openAI-compatible: send a final commit and disconnect after a
            // short grace period — the server responds quickly.
            // For mlx-audio: DON'T preemptively disconnect. The server needs time
            // for model inference on the accumulated audio (can take 5+ seconds on
            // 6-12s of speech). Keep the connection alive so the finalTranscript
            // arrives and gets auto-pasted. The timeout below acts as backstop.
            if self.activeClientSource != .mlxAudio {
                self.activeRealtimeClient().disconnectAfterFinalCommitIfNeeded()
            }

            try? await Task.sleep(for: .seconds(self.stopFinalizationTimeoutSeconds))
            guard self.isFinalizingStop else { return }
            self.debugLog("stop finalization timeout; forcing disconnect")
            self.activeRealtimeClient().disconnect()
            self.finishStoppedSession(promotePendingSegment: true)
        }
    }

    private func sendTrailingSilenceForMlxAudio() async {
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

    private func finishStoppedSession(promotePendingSegment: Bool) {
        stopFinalizationTask?.cancel()
        stopFinalizationTask = nil

        let wasMlxAudio = activeClientSource == .mlxAudio

        if promotePendingSegment {
            let promoted = promotePendingRealtimeTextToLatestSegment()

            // For mlx-audio, partial transcripts are NOT auto-pasted during
            // dictation (the server may revise hypotheses). If finalization
            // ended before a finalTranscript arrived (common due to higher
            // model inference latency), auto-paste the promoted partial text.
            if wasMlxAudio, let promoted, !promoted.isEmpty {
                if !textInsertion.insertTextUsingAccessibilityOnly(promoted) {
                    _ = textInsertion.pasteUsingCommandV(promoted)
                }
            }
        }

        isFinalizingStop = false
        livePartialText = ""
        pendingRealtimeFinalizationText = ""
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

    private func handle(event: RealtimeWebSocketClient.Event, source: ActiveClientSource) {
        guard source == activeClientSource else { return }

        switch event {
        case .connected:
            if isDictating {
                statusText = "Listening..."
            } else if isFinalizingStop {
                statusText = "Finalizing..."
            } else {
                statusText = "Ready"
            }

        case .disconnected:
            if isFinalizingStop {
                finishStoppedSession(promotePendingSegment: true)
                return
            }
            guard isDictating else { return }
            commitTask?.cancel()
            commitTask = nil
            audioSendTask?.cancel()
            audioSendTask = nil
            healthMonitor.stop()
            isAwaitingMicrophonePermission = false
            microphone.stop()
            isDictating = false
            lastError = "Connection lost. Dictation stopped."
            finishStoppedSession(promotePendingSegment: true)

        case .status(let message):
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            if source == .openAICompatible {
                // vLLM/OpenAI-compatible realtime emits append-only transcription deltas.
                // Merging by overlap can drop repeated characters (for example digits in "2021"),
                // so append directly to preserve exact incremental output for live preview.
                pendingRealtimeFinalizationText.append(delta)
                livePartialText = pendingRealtimeFinalizationText
                // For vLLM/OpenAI-compatible streams, deltas are append-only and safe to
                // insert directly to avoid duplicate full-sentence insertion on frequent commits.
                textInsertion.enqueueRealtimeInsertion(delta)
            } else {
                let mergedPartial = mergeIncrementalText(
                    existing: pendingRealtimeFinalizationText,
                    incoming: delta
                )
                pendingRealtimeFinalizationText = mergedPartial.merged
                livePartialText = mergedPartial.merged
            }
            if let accessibilityError = textInsertion.lastAccessibilityError {
                lastError = accessibilityError
            }
            statusText = isFinalizingStop ? "Finalizing..." : "Transcribing..."

        case .finalTranscript(let text):
            guard acceptsRealtimeEvents else { return }
            let finalizedSegment: String
            if source == .mlxAudio {
                finalizedSegment = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                finalizedSegment = resolvedFinalizedSegment(from: text)
            }
            let hadLiveDelta = !pendingRealtimeFinalizationText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                || !livePartialText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            guard !finalizedSegment.isEmpty else {
                livePartialText = ""
                pendingRealtimeFinalizationText = ""
                return
            }

            if transcriptText.isEmpty {
                transcriptText = finalizedSegment
            } else {
                transcriptText += "\n" + finalizedSegment
            }

            currentDictationEventText = appendToCurrentDictationEvent(
                segment: finalizedSegment,
                existingText: currentDictationEventText
            )
            lastFinalSegment = currentDictationEventText
            livePartialText = ""
            pendingRealtimeFinalizationText = ""
            statusText = isDictating ? "Listening..." : (isFinalizingStop ? "Finalizing..." : "Ready")

            // mlx-audio may revise chunk hypotheses, so insert finalized text only.
            // vLLM/OpenAI-compatible streams already insert append-only deltas, so
            // finalized text should be inserted only when no live delta was seen.
            let shouldInsertFinal = source == .mlxAudio || !hadLiveDelta
            if shouldInsertFinal {
                if source == .mlxAudio {
                    // mlx-audio transcripts arrive as a complete block after a
                    // multi-second delay. Skip the keyboard-event path entirely
                    // (postUnicodeTextEvents returns "success" even when events
                    // don't reach the target). Try accessibility first; fall
                    // back to Cmd+V paste which is reliable for complete blocks.
                    if !textInsertion.insertTextUsingAccessibilityOnly(finalizedSegment) {
                        _ = textInsertion.pasteUsingCommandV(finalizedSegment)
                    }
                } else {
                    textInsertion.enqueueRealtimeInsertion(finalizedSegment)
                }
                if let accessibilityError = textInsertion.lastAccessibilityError {
                    lastError = accessibilityError
                }
            }

            if settings.autoCopyEnabled {
                copyLatestSegment(updateStatus: false)
            }

        case .error(let message):
            let normalized = message.lowercased()
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
        }
    }

    private func selectedClientSource() -> ActiveClientSource {
        switch settings.realtimeProvider {
        case .openAICompatible:
            return .openAICompatible
        case .mlxAudio:
            return .mlxAudio
        }
    }

    private func selectedRealtimeClient() -> RealtimeClient {
        switch selectedClientSource() {
        case .openAICompatible:
            return openAIRealtimeClient
        case .mlxAudio:
            return mlxAudioRealtimeClient
        }
    }

    private func activeRealtimeClient() -> RealtimeClient {
        switch activeClientSource {
        case .openAICompatible:
            return openAIRealtimeClient
        case .mlxAudio:
            return mlxAudioRealtimeClient
        case nil:
            return selectedRealtimeClient()
        }
    }

    private func inactiveRealtimeClient(for source: ActiveClientSource) -> RealtimeClient {
        switch source {
        case .openAICompatible:
            return mlxAudioRealtimeClient
        case .mlxAudio:
            return openAIRealtimeClient
        }
    }

    private func resolvedFinalizedSegment(from finalText: String) -> String {
        let finalizedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bufferedText = pendingRealtimeFinalizationText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Promotes any buffered partial transcript text to `lastFinalSegment`.
    /// Returns the promoted segment text, or `nil` if there was nothing to promote.
    @discardableResult
    private func promotePendingRealtimeTextToLatestSegment() -> String? {
        let pendingSegment = resolvedFinalizedSegment(from: "")
        guard !pendingSegment.isEmpty else { return nil }

        currentDictationEventText = appendToCurrentDictationEvent(
            segment: pendingSegment,
            existingText: currentDictationEventText
        )
        lastFinalSegment = currentDictationEventText

        if settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }

        return pendingSegment
    }

    private func appendToCurrentDictationEvent(segment: String, existingText: String) -> String {
        let normalizedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSegment.isEmpty else { return existingText }

        let normalizedExisting = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedExisting.isEmpty else { return normalizedSegment }

        if normalizedSegment == normalizedExisting {
            return normalizedExisting
        }

        if normalizedSegment.hasPrefix(normalizedExisting) {
            return normalizedSegment
        }

        if normalizedExisting.hasSuffix(normalizedSegment) {
            return normalizedExisting
        }

        let overlap = longestSuffixPrefixOverlap(lhs: normalizedExisting, rhs: normalizedSegment)
        if overlap > 0 {
            let overlapIndex = normalizedSegment.index(normalizedSegment.startIndex, offsetBy: overlap)
            let suffix = String(normalizedSegment[overlapIndex...])
            return normalizedExisting + suffix
        }

        return normalizedExisting + "\n" + normalizedSegment
    }

    private func mergeIncrementalText(existing: String, incoming: String) -> (merged: String, appendedDelta: String) {
        guard !incoming.isEmpty else { return (existing, "") }
        guard !existing.isEmpty else { return (incoming, incoming) }

        if incoming == existing {
            return (existing, "")
        }

        if incoming.hasPrefix(existing) {
            let start = incoming.index(incoming.startIndex, offsetBy: existing.count)
            let delta = String(incoming[start...])
            return (incoming, delta)
        }

        if existing.hasSuffix(incoming) || existing.contains(incoming) {
            return (existing, "")
        }

        let overlap = longestSuffixPrefixOverlap(lhs: existing, rhs: incoming)
        if overlap > 0 {
            let start = incoming.index(incoming.startIndex, offsetBy: overlap)
            let delta = String(incoming[start...])
            return (existing + delta, delta)
        }

        return (existing + incoming, incoming)
    }

    private func longestSuffixPrefixOverlap(lhs: String, rhs: String) -> Int {
        let maxOverlap = min(lhs.count, rhs.count)
        guard maxOverlap > 0 else { return 0 }

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            let lhsStart = lhs.index(lhs.endIndex, offsetBy: -overlap)
            let rhsEnd = rhs.index(rhs.startIndex, offsetBy: overlap)
            if lhs[lhsStart...] == rhs[..<rhsEnd] {
                return overlap
            }
        }

        return 0
    }

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        Log.dictation.debug("\(message)")
    }
}
