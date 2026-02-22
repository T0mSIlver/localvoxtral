import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import os

enum RealtimeSessionIndicatorState {
    case idle
    case connected
    case recentFailure
}

@MainActor
@Observable
final class DictationViewModel {
    private enum ActiveClientSource {
        case realtimeAPI
        case mlxAudio
    }

    private enum MlxInsertionMode {
        case realtime
        case finalized
        case none
    }

    private(set) var isDictating = false
    private(set) var isFinalizingStop = false
    private(set) var isConnectingRealtimeSession = false
    private(set) var realtimeSessionIndicatorState: RealtimeSessionIndicatorState = .idle
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
    private let realtimeAPIClient = RealtimeAPIWebSocketClient()
    private let mlxAudioRealtimeClient = MlxAudioRealtimeWebSocketClient()
    private var activeClientSource: ActiveClientSource?
    private let audioChunkBuffer = AudioChunkBuffer()
    private let healthMonitor = AudioCaptureHealthMonitor()
    private let audioSendInterval: TimeInterval = 0.1
    private let connectTimeoutSeconds: TimeInterval = 2.0
    private let recentFailureIndicatorSeconds: TimeInterval = 5.0
    private var commitTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var stopFinalizationTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var recentFailureResetTask: Task<Void, Never>?
    private var isShowingConnectionFailureAlert = false
    private var realtimeFinalizationLastActivityAt: Date?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var isAwaitingMicrophonePermission = false
    private var pendingRealtimeFinalizationText = ""
    private var currentDictationEventText = ""
    private var mlxCommittedEventText = ""
    private var mlxCommittedSinceLastFinal = ""
    private var mlxSegmentLatestHypothesis = ""
    private var mlxSegmentPreviousHypothesis = ""
    private var mlxSegmentCommittedPrefix = ""
    private let mlxTrailingSilenceDurationSeconds: TimeInterval = 1.6
    private let mlxTrailingSilenceChunkDurationSeconds: TimeInterval = 0.1
    private let stopFinalizationTimeoutSeconds: TimeInterval = 7.0
    private let mlxStopFinalizationTimeoutSeconds: TimeInterval = 25.0
    private let realtimeFinalizationInactivitySeconds: TimeInterval = 0.7
    private let realtimeFinalizationMinimumOpenSeconds: TimeInterval = 1.5
    private let finalizationPollIntervalSeconds: TimeInterval = 0.1
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

    private var lifecycleObservers: [NSObjectProtocol] = []
    private static let hotKeySignature = OSType(0x53565854) // SVXT
    private static weak var hotKeyTarget: DictationViewModel?
    private static let hotKeyUnavailableErrorMessage = "The selected keyboard shortcut is unavailable."

    init(settings: SettingsStore) {
        self.settings = settings

        realtimeAPIClient.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event, source: .realtimeAPI)
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
        connectTimeoutTask?.cancel()
        recentFailureResetTask?.cancel()
        textInsertion.stopAllTasks()
        healthMonitor.cancelTasks()
        microphone.stop()
        networkMonitor.stop()
        realtimeAPIClient.disconnect()
        mlxAudioRealtimeClient.disconnect()
        unregisterGlobalHotkey()
    }

    @discardableResult
    private func registerGlobalHotkey() -> Bool {
        unregisterGlobalHotkey()

        guard let shortcut = settings.dictationShortcut else {
            return true
        }

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
            lastError = "Failed to register global hotkey handler."
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            statusText = "Failed to register global hotkey."
            lastError = Self.hotKeyUnavailableErrorMessage
            unregisterGlobalHotkey()
            return false
        }

        return true
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
            if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession,
               statusText == "Network lost. Dictation stopped."
                || statusText == "No network connection."
            {
                statusText = "Ready"
                lastError = nil
            }
        } else {
            debugLog("network lost")
            if isConnectingRealtimeSession {
                abortConnectingSession()
                let message = "Network connection was lost while connecting."
                handleConnectFailure(
                    status: "Network lost. Dictation stopped.",
                    message: message,
                    technicalDetails: "Network path changed to unavailable while opening websocket."
                )
            } else if isDictating {
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
        } else if isConnectingRealtimeSession {
            statusText = "Connecting to realtime backend..."
        } else if isFinalizingStop {
            statusText = "Finalizing previous dictation..."
        } else {
            startDictation()
        }
    }

    func updateDictationShortcut(_ shortcut: DictationShortcut?) {
        let previousShortcut = settings.dictationShortcut
        let previousWasEnabled = settings.dictationShortcutEnabled

        settings.setDictationShortcut(shortcut)

        if registerGlobalHotkey() {
            if !isDictating, !isFinalizingStop,
               (statusText == "Failed to register global hotkey handler."
                || statusText == "Failed to register global hotkey.")
            {
                statusText = "Ready"
            }

            if lastError == Self.hotKeyUnavailableErrorMessage
                || lastError == "Failed to register global hotkey handler."
            {
                lastError = nil
            }
            return
        }

        if previousWasEnabled {
            settings.setDictationShortcut(previousShortcut ?? SettingsStore.defaultDictationShortcut)
        } else {
            settings.setDictationShortcut(nil)
        }

        _ = registerGlobalHotkey()
        statusText = "Failed to register global hotkey."
        lastError = Self.hotKeyUnavailableErrorMessage
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
        guard !isConnectingRealtimeSession else {
            statusText = "Connecting to realtime backend..."
            return
        }
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
        // Dictation audio is stopped, but keep the connected indicator while the
        // realtime websocket remains open for trailing transcript chunks.
        setRealtimeIndicatorConnected()
        scheduleStopFinalization()
    }

    func clearTranscript() {
        transcriptText = ""
        livePartialText = ""
        lastFinalSegment = ""
        pendingRealtimeFinalizationText = ""
        currentDictationEventText = ""
        mlxCommittedEventText = ""
        mlxCommittedSinceLastFinal = ""
        mlxSegmentLatestHypothesis = ""
        mlxSegmentPreviousHypothesis = ""
        mlxSegmentCommittedPrefix = ""
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
        pendingRealtimeFinalizationText = ""
        currentDictationEventText = ""
        mlxCommittedEventText = ""
        mlxCommittedSinceLastFinal = ""
        mlxSegmentLatestHypothesis = ""
        mlxSegmentPreviousHypothesis = ""
        mlxSegmentCommittedPrefix = ""
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

    private func startAudioCaptureAfterConnection() {
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

            // For Realtime API (vLLM/voxmlx): send a final commit and keep the
            // websocket open while transcript chunks are still arriving. Disconnect
            // once transcript activity is idle for a short window.
            // For mlx-audio: DON'T preemptively disconnect. The server needs time
            // for model inference on the accumulated audio (can take 10-20s with
            // large buffers at MAX_CHUNK=30). Keep the connection alive so the
            // finalTranscript arrives and gets auto-pasted. The 25s timeout below
            // acts as backstop.
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
        cancelConnectTimeout()

        let wasMlxAudio = activeClientSource == .mlxAudio

        if promotePendingSegment {
            let promoted = wasMlxAudio
                ? promotePendingMlxTextToLatestSegment()
                : promotePendingRealtimeTextToLatestSegment()

            // For mlx-audio, we incrementally insert only stabilized prefixes.
            // If finalization ends before a finalTranscript arrives, promote
            // the remaining unstabilized tail and insert it once.
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
        pendingRealtimeFinalizationText = ""
        mlxCommittedSinceLastFinal = ""
        mlxSegmentLatestHypothesis = ""
        mlxSegmentPreviousHypothesis = ""
        mlxSegmentCommittedPrefix = ""
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

    private func handle(event: RealtimeEvent, source: ActiveClientSource) {
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

            // Realtime API (vLLM/voxmlx) emits append-only transcription deltas.
            // Merging by overlap can drop repeated characters (for example digits in "2021"),
            // so append directly to preserve exact incremental output for live preview.
            pendingRealtimeFinalizationText.append(delta)
            livePartialText = pendingRealtimeFinalizationText
            // For Realtime API streams, deltas are append-only and safe to
            // insert directly to avoid duplicate full-sentence insertion on frequent commits.
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

            currentDictationEventText = TextMergingAlgorithms.appendToCurrentDictationEvent(
                segment: finalizedSegment,
                existingText: currentDictationEventText
            )
            lastFinalSegment = currentDictationEventText
            livePartialText = ""
            pendingRealtimeFinalizationText = ""
            statusText = isDictating ? "Listening..." : (isFinalizingStop ? "Finalizing..." : "Ready")

            // Realtime API streams already insert append-only deltas, so
            // finalized text should be inserted only when no live delta was seen.
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

    private func handleMlxPartialTranscript(_ delta: String) {
        let mergedHypothesis = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            delta.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !mergedHypothesis.isEmpty else { return }
        let insertionMode: MlxInsertionMode = settings.autoPasteIntoInputFieldEnabled ? .realtime : .none
        _ = commitMlxHypothesis(
            mergedHypothesis,
            isFinal: false,
            insertionMode: insertionMode
        )

        if settings.autoPasteIntoInputFieldEnabled, let accessibilityError = textInsertion.lastAccessibilityError {
            lastError = accessibilityError
        }
        statusText = isFinalizingStop ? "Finalizing..." : "Transcribing..."
    }

    private func handleMlxFinalTranscript(_ text: String) {
        let hypothesis = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !hypothesis.isEmpty else {
            livePartialText = ""
            pendingRealtimeFinalizationText = ""
            mlxSegmentLatestHypothesis = ""
            mlxSegmentPreviousHypothesis = ""
            mlxSegmentCommittedPrefix = ""
            return
        }

        // While dictating, keep mlx insertion on the same retry queue used by
        // partial commits to avoid queue/direct race duplicates. During stop
        // finalization we still prefer direct finalized insertion.
        let insertionMode: MlxInsertionMode
        if settings.autoPasteIntoInputFieldEnabled {
            insertionMode = isFinalizingStop ? .finalized : .realtime
        } else {
            insertionMode = .none
        }

        _ = commitMlxHypothesis(
            hypothesis,
            isFinal: true,
            insertionMode: insertionMode
        )

        let finalizedDelta = consumeMlxCommittedSinceLastFinal()
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
        pendingRealtimeFinalizationText = ""
        mlxSegmentLatestHypothesis = ""
        mlxSegmentPreviousHypothesis = ""
        mlxSegmentCommittedPrefix = ""
        statusText = isDictating ? "Listening..." : (isFinalizingStop ? "Finalizing..." : "Ready")

        if settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }
    }

    /// Promotes the remaining mlx hypothesis tail when the server disconnects
    /// before emitting a final transcript.  Returns only the unstabilized tail
    /// that was NOT already inserted via the realtime insertion queue.
    @discardableResult
    private func promotePendingMlxTextToLatestSegment() -> String? {
        let hypothesis = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            mlxSegmentLatestHypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        // Capture the already-inserted prefix length before committing the tail.
        // Everything up to mlxSegmentCommittedPrefix was already inserted
        // word-by-word during partial processing via enqueueRealtimeInsertion.
        let alreadyInsertedPrefix = mlxSegmentCommittedPrefix

        if !hypothesis.isEmpty {
            _ = commitMlxHypothesis(
                hypothesis,
                isFinal: true,
                insertionMode: .none
            )
        }

        let allCommitted = consumeMlxCommittedSinceLastFinal().trimmingCharacters(in: .whitespacesAndNewlines)

        // Update transcript view with all committed text.
        if !allCommitted.isEmpty {
            if transcriptText.isEmpty {
                transcriptText = allCommitted
            } else {
                transcriptText += "\n" + allCommitted
            }
        }

        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingRealtimeFinalizationText = ""
        mlxSegmentLatestHypothesis = ""
        mlxSegmentPreviousHypothesis = ""
        mlxSegmentCommittedPrefix = ""

        if settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }

        // For app insertion: only the tail beyond what was already inserted
        // during partial processing.  The committed prefix was already sent
        // to the focused app via enqueueRealtimeInsertion.
        let newlyPromoted: String
        if hypothesis.count > alreadyInsertedPrefix.count,
           hypothesis.hasPrefix(alreadyInsertedPrefix)
        {
            let start = hypothesis.index(
                hypothesis.startIndex,
                offsetBy: alreadyInsertedPrefix.count
            )
            newlyPromoted = String(hypothesis[start...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if alreadyInsertedPrefix.isEmpty {
            newlyPromoted = allCommitted
        } else {
            newlyPromoted = ""
        }

        guard !newlyPromoted.isEmpty else { return nil }
        return newlyPromoted
    }

    @discardableResult
    private func commitMlxHypothesis(
        _ hypothesis: String,
        isFinal: Bool,
        insertionMode: MlxInsertionMode
    ) -> String {
        guard !hypothesis.isEmpty else { return "" }

        if isFinal,
           !mlxSegmentCommittedPrefix.isEmpty,
           !hypothesis.hasPrefix(mlxSegmentCommittedPrefix)
        {
            // Final hypotheses can occasionally revise earlier words. We do not
            // retract committed text, so only append a conservative suffix delta
            // if it can be inferred safely from the previous hypothesis.
            let safeDelta = resolvedMlxFinalMismatchDelta(
                previousHypothesis: mlxSegmentLatestHypothesis,
                finalHypothesis: hypothesis
            )
            let appended = appendCommittedMlxDeltaToEvent(
                safeDelta,
                insertionMode: insertionMode
            )
            mlxSegmentCommittedPrefix = hypothesis
            mlxSegmentLatestHypothesis = hypothesis
            mlxSegmentPreviousHypothesis = hypothesis
            pendingRealtimeFinalizationText = ""
            livePartialText = ""
            return appended
        }

        let previousHypothesis = mlxSegmentPreviousHypothesis
        var commitTarget = mlxSegmentCommittedPrefix

        if isFinal {
            if hypothesis.hasPrefix(mlxSegmentCommittedPrefix) {
                commitTarget = hypothesis
            }
        } else if !previousHypothesis.isEmpty {
            let stableLength = TextMergingAlgorithms.longestCommonPrefixLength(
                lhs: previousHypothesis,
                rhs: hypothesis
            )
            let boundaryLength = TextMergingAlgorithms.stableWordBoundaryLength(in: hypothesis, upTo: stableLength)
            if boundaryLength > mlxSegmentCommittedPrefix.count {
                commitTarget = String(hypothesis.prefix(boundaryLength))
            }
        }

        var appendedDelta = ""
        if commitTarget.count > mlxSegmentCommittedPrefix.count,
           commitTarget.hasPrefix(mlxSegmentCommittedPrefix)
        {
            let start = commitTarget.index(
                commitTarget.startIndex,
                offsetBy: mlxSegmentCommittedPrefix.count
            )
            let newlyStableDelta = String(commitTarget[start...])
            appendedDelta = appendCommittedMlxDeltaToEvent(
                newlyStableDelta,
                insertionMode: insertionMode
            )
            mlxSegmentCommittedPrefix = commitTarget
        }

        mlxSegmentLatestHypothesis = hypothesis
        mlxSegmentPreviousHypothesis = hypothesis

        if hypothesis.hasPrefix(mlxSegmentCommittedPrefix) {
            let start = hypothesis.index(
                hypothesis.startIndex,
                offsetBy: mlxSegmentCommittedPrefix.count
            )
            let unstableTail = String(hypothesis[start...])
            pendingRealtimeFinalizationText = unstableTail
            livePartialText = unstableTail
        } else {
            pendingRealtimeFinalizationText = hypothesis
            livePartialText = hypothesis
        }

        return appendedDelta
    }

    @discardableResult
    private func appendCommittedMlxDeltaToEvent(
        _ delta: String,
        insertionMode: MlxInsertionMode
    ) -> String {
        guard !delta.isEmpty else { return "" }

        let merged = TextMergingAlgorithms.appendWithTailOverlap(existing: mlxCommittedEventText, incoming: delta)
        mlxCommittedEventText = merged.merged
        currentDictationEventText = merged.merged

        guard !merged.appendedDelta.isEmpty else { return "" }

        let finalizedDeltaBuffer = TextMergingAlgorithms.appendWithTailOverlap(
            existing: mlxCommittedSinceLastFinal,
            incoming: merged.appendedDelta
        )
        mlxCommittedSinceLastFinal = finalizedDeltaBuffer.merged

        switch insertionMode {
        case .realtime:
            textInsertion.enqueueRealtimeInsertion(merged.appendedDelta)
        case .finalized:
            if !textInsertion.insertTextUsingAccessibilityOnly(merged.appendedDelta) {
                _ = textInsertion.pasteUsingCommandV(merged.appendedDelta)
            }
        case .none:
            break
        }

        if insertionMode != .none, let accessibilityError = textInsertion.lastAccessibilityError {
            lastError = accessibilityError
        }

        return merged.appendedDelta
    }

    private func consumeMlxCommittedSinceLastFinal() -> String {
        let delta = mlxCommittedSinceLastFinal
        mlxCommittedSinceLastFinal = ""
        return delta
    }

    private func resolvedMlxFinalMismatchDelta(
        previousHypothesis: String,
        finalHypothesis: String
    ) -> String {
        let previous = previousHypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty else { return finalHypothesis }

        if finalHypothesis.hasPrefix(previous) {
            let start = finalHypothesis.index(finalHypothesis.startIndex, offsetBy: previous.count)
            return String(finalHypothesis[start...])
        }

        if previous.hasPrefix(finalHypothesis) || previous.contains(finalHypothesis) {
            return ""
        }

        if let range = finalHypothesis.range(of: previous) {
            return String(finalHypothesis[range.upperBound...])
        }

        let overlap = TextMergingAlgorithms.longestSuffixPrefixOverlap(
            lhs: previous,
            rhs: finalHypothesis
        )
        guard overlap > 0 else { return "" }
        let start = finalHypothesis.index(finalHypothesis.startIndex, offsetBy: overlap)
        return String(finalHypothesis[start...])
    }

    private func scheduleConnectTimeout() {
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

    private func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    private func abortConnectingSession(disconnectSocket: Bool = true) {
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

    private func setRealtimeIndicatorIdle() {
        recentFailureResetTask?.cancel()
        recentFailureResetTask = nil
        realtimeSessionIndicatorState = .idle
    }

    private func setRealtimeIndicatorConnected() {
        recentFailureResetTask?.cancel()
        recentFailureResetTask = nil
        realtimeSessionIndicatorState = .connected
    }

    private func markRecentConnectionFailureIndicator() {
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

    private func handleConnectFailure(status: String, message: String, technicalDetails: String? = nil) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMessage = trimmedMessage.isEmpty ? "Unable to establish realtime connection." : trimmedMessage
        let resolvedDetails = normalizedFailureDetails(technicalDetails)

        statusText = status
        lastError = resolvedDetails ?? resolvedMessage
        logConnectionFailure(message: resolvedMessage, technicalDetails: resolvedDetails)
        markRecentConnectionFailureIndicator()
        presentConnectionFailureAlert(message: resolvedMessage)
    }

    private func presentConnectionFailureAlert(message: String) {
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

    private func openSystemConsole() {
        guard let consoleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            return
        }
        _ = NSWorkspace.shared.open(consoleURL)
    }

    private func logConnectionFailure(message: String, technicalDetails: String?) {
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

    private func selectedClientSource() -> ActiveClientSource {
        switch settings.realtimeProvider {
        case .realtimeAPI:
            return .realtimeAPI
        case .mlxAudio:
            return .mlxAudio
        }
    }

    private func selectedRealtimeClient() -> RealtimeClient {
        switch selectedClientSource() {
        case .realtimeAPI:
            return realtimeAPIClient
        case .mlxAudio:
            return mlxAudioRealtimeClient
        }
    }

    private func activeRealtimeClient() -> RealtimeClient {
        switch activeClientSource {
        case .realtimeAPI:
            return realtimeAPIClient
        case .mlxAudio:
            return mlxAudioRealtimeClient
        case nil:
            return selectedRealtimeClient()
        }
    }

    private func inactiveRealtimeClient(for source: ActiveClientSource) -> RealtimeClient {
        switch source {
        case .realtimeAPI:
            return mlxAudioRealtimeClient
        case .mlxAudio:
            return realtimeAPIClient
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

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        Log.dictation.debug("\(message)")
    }
}
