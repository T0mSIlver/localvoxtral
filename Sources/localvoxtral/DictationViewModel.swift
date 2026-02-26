import AppKit
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
    enum ActiveClientSource {
        case realtimeAPI
        case mlxAudio
    }

    var isDictating = false
    var isFinalizingStop = false
    var isConnectingRealtimeSession = false
    var realtimeSessionIndicatorState: RealtimeSessionIndicatorState = .idle
    var transcriptText = ""
    var livePartialText = ""
    var statusText = "Ready"
    var lastError: String?
    var lastFinalSegment = ""
    private(set) var availableInputDevices: [MicrophoneInputDevice] = []
    private(set) var selectedInputDeviceID = ""

    var isAccessibilityTrusted: Bool { textInsertion.isAccessibilityTrusted }

    let settings: SettingsStore
    let textInsertion = TextInsertionService()

    // Services — internal so extension files can access them.
    @ObservationIgnored
    let microphone = MicrophoneCaptureService()
    @ObservationIgnored
    let networkMonitor = NetworkMonitor()
    @ObservationIgnored
    let realtimeAPIClient = RealtimeAPIWebSocketClient()
    @ObservationIgnored
    let mlxAudioRealtimeClient = MlxAudioRealtimeWebSocketClient()
    @ObservationIgnored
    let audioChunkBuffer = AudioChunkBuffer()
    @ObservationIgnored
    let healthMonitor = AudioCaptureHealthMonitor()
    @ObservationIgnored
    let mlxStabilizer = MlxHypothesisStabilizer()
    @ObservationIgnored
    private let hotKeyManager = HotKeyManager()

    // Mutable state — internal so extension files can access.
    @ObservationIgnored
    var activeClientSource: ActiveClientSource?
    @ObservationIgnored
    var commitTask: Task<Void, Never>?
    @ObservationIgnored
    var audioSendTask: Task<Void, Never>?
    @ObservationIgnored
    var stopFinalizationTask: Task<Void, Never>?
    @ObservationIgnored
    var connectTimeoutTask: Task<Void, Never>?
    @ObservationIgnored
    var recentFailureResetTask: Task<Void, Never>?
    @ObservationIgnored
    var isShowingConnectionFailureAlert = false
    @ObservationIgnored
    var realtimeFinalizationLastActivityAt: Date?
    @ObservationIgnored
    var isAwaitingMicrophonePermission = false
    @ObservationIgnored
    var pendingSegmentText = ""
    @ObservationIgnored
    var currentDictationEventText = ""

    @ObservationIgnored
    let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

    @ObservationIgnored
    private var lifecycleObservers: [NSObjectProtocol] = []

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
               (self.statusText == "Waiting for Accessibility permission."
                   || self.statusText == "Paste blocked by Accessibility permission.")
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

        hotKeyManager.onToggle = { [weak self] in self?.toggleDictation() }
        switch hotKeyManager.register(shortcut: settings.dictationShortcut) {
        case .success:
            break
        case .failure(let reason):
            applyHotKeyRegistrationFailure(reason)
        }

        mlxStabilizer.onRealtimeInsertion = { [weak self] delta in
            self?.textInsertion.enqueueRealtimeInsertion(delta)
        }
        mlxStabilizer.onFinalizedInsertion = { [weak self] delta in
            guard let self else { return }
            if !self.textInsertion.insertTextUsingAccessibilityOnly(delta) {
                _ = self.textInsertion.pasteUsingCommandV(delta)
            }
        }
        textInsertion.refreshAccessibilityTrustState()
        refreshMicrophoneInputs()
        registerLifecycleObservers()
    }

    @MainActor
    deinit {
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
        hotKeyManager.unregister()
    }

    // MARK: - Lifecycle Observers

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default

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

    // MARK: - Network

    private func handleNetworkChange(connected: Bool) {
        if connected {
            debugLog("network restored")
            if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession,
               (statusText == "Network lost. Dictation stopped."
                   || statusText == "No network connection.")
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
                stopDictation(reason: "network lost", finalizeRemainingAudio: false)
                statusText = "Network lost. Dictation stopped."
                lastError = "Network connection was lost during dictation."
            } else if isFinalizingStop {
                activeRealtimeClient().disconnect()
                finishStoppedSession(promotePendingSegment: true)
                statusText = "Network lost. Dictation stopped."
                lastError = "Network connection was lost during dictation."
            } else {
                statusText = "No network connection."
            }
        }
    }

    // MARK: - Public API

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

        switch hotKeyManager.register(shortcut: settings.dictationShortcut) {
        case .success:
            if !isDictating, !isFinalizingStop,
               (statusText == HotKeyManager.handlerRegistrationErrorMessage
                || statusText == HotKeyManager.registrationErrorStatus)
            {
                statusText = "Ready"
            }

            if lastError == HotKeyManager.unavailableErrorMessage
                || lastError == HotKeyManager.handlerRegistrationErrorMessage
            {
                lastError = nil
            }
            return
        case .failure(let reason):
            if previousWasEnabled {
                settings.setDictationShortcut(previousShortcut ?? SettingsStore.defaultDictationShortcut)
            } else {
                settings.setDictationShortcut(nil)
            }
            _ = hotKeyManager.register(shortcut: settings.dictationShortcut)
            applyHotKeyRegistrationFailure(reason)
        }
    }

    func refreshMicrophoneInputs() {
        let devices = microphone.availableInputDevices()
        if availableInputDevices != devices {
            availableInputDevices = devices
        }

        let savedSelection = settings.selectedInputDeviceUID.trimmed
        let currentSelection = selectedInputDeviceID.trimmed
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
        setRealtimeIndicatorConnected()
        scheduleStopFinalization()
    }

    func clearTranscript() {
        transcriptText = ""
        livePartialText = ""
        lastFinalSegment = ""
        pendingSegmentText = ""
        currentDictationEventText = ""
        mlxStabilizer.reset()
        lastError = nil
    }

    func copyTranscript() {
        let fullText = fullTranscript.trimmed
        guard !fullText.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullText, forType: .string)

        statusText = "Transcript copied."
    }

    func copyLatestSegment(updateStatus: Bool = true) {
        let segment = lastFinalSegment.trimmed
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
           (statusText == "Waiting for Accessibility permission."
               || statusText == "Paste blocked by Accessibility permission.")
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
        let segment = lastFinalSegment.trimmed
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
        let finalPart = transcriptText.trimmed
        let livePart = livePartialText.trimmed

        if finalPart.isEmpty { return livePart }
        if livePart.isEmpty { return finalPart }
        return finalPart + "\n" + livePart
    }

    var acceptsRealtimeEvents: Bool {
        isDictating || isFinalizingStop
    }

    func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        Log.dictation.debug("\(message)")
    }

    private func applyHotKeyRegistrationFailure(_ reason: HotKeyManager.RegistrationFailure) {
        switch reason {
        case .handlerInstallFailed:
            statusText = HotKeyManager.handlerRegistrationErrorMessage
            lastError = HotKeyManager.handlerRegistrationErrorMessage
        case .shortcutUnavailable:
            statusText = HotKeyManager.registrationErrorStatus
            lastError = HotKeyManager.unavailableErrorMessage
        }
    }
}
