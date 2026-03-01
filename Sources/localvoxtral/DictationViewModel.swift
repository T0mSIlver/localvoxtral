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

    // Tokenized status/error categories keep control flow stable if user-facing
    // copy changes in the future.
    enum StatusToken: Equatable {
        case waitingForAccessibilityPermission
        case pasteBlockedByAccessibilityPermission
        case awaitingMicrophonePermission
        case networkLostDictationStopped
        case noNetworkConnection
        case hotKeyHandlerRegistrationFailure
        case hotKeyShortcutUnavailable
        case other

        @MainActor
        static func from(_ statusText: String) -> StatusToken {
            switch statusText {
            case StatusStrings.waitingForAccessibilityPermission:
                return .waitingForAccessibilityPermission
            case StatusStrings.pasteBlockedByAccessibilityPermission:
                return .pasteBlockedByAccessibilityPermission
            case StatusStrings.awaitingMicrophonePermission:
                return .awaitingMicrophonePermission
            case StatusStrings.networkLostDictationStopped:
                return .networkLostDictationStopped
            case StatusStrings.noNetworkConnection:
                return .noNetworkConnection
            case HotKeyManager.handlerRegistrationErrorMessage:
                return .hotKeyHandlerRegistrationFailure
            case HotKeyManager.registrationErrorStatus:
                return .hotKeyShortcutUnavailable
            default:
                return .other
            }
        }
    }

    enum ErrorToken: Equatable {
        case accessibilityPermissionRequired
        case hotKeyHandlerRegistrationFailure
        case hotKeyShortcutUnavailable
        case websocketReceiveFailed
        case other

        @MainActor
        static func from(_ message: String) -> ErrorToken {
            if message == TextInsertionService.accessibilityErrorMessage {
                return .accessibilityPermissionRequired
            }
            if message == HotKeyManager.handlerRegistrationErrorMessage {
                return .hotKeyHandlerRegistrationFailure
            }
            if message == HotKeyManager.unavailableErrorMessage {
                return .hotKeyShortcutUnavailable
            }
            if message.localizedCaseInsensitiveContains("websocket receive failed") {
                return .websocketReceiveFailed
            }
            return .other
        }
    }

    private enum StatusStrings {
        static let ready = "Ready"
        static let connectingRealtimeBackend = "Connecting to realtime backend..."
        static let finalizingPreviousDictation = "Finalizing previous dictation..."
        static let awaitingMicrophonePermission = "Awaiting microphone permission..."
        static let requestingMicrophonePermission = "Requesting microphone permission..."
        static let waitingForAccessibilityPermission = "Waiting for Accessibility permission."
        static let pasteBlockedByAccessibilityPermission = "Paste blocked by Accessibility permission."
        static let networkLostDictationStopped = "Network lost. Dictation stopped."
        static let noNetworkConnection = "No network connection."
        static let microphoneAccessDenied = "Microphone access denied."
        static let finalizing = "Finalizing..."
    }

    private static let microphoneDeniedMessage =
        "Grant microphone access in System Settings > Privacy & Security > Microphone."

    var isDictating = false
    var isFinalizingStop = false
    var isConnectingRealtimeSession = false
    var realtimeSessionIndicatorState: RealtimeSessionIndicatorState = .idle
    var transcriptText = ""
    var livePartialText = ""
    var statusText = StatusStrings.ready
    var lastError: String?
    var lastFinalSegment = ""
    private(set) var availableInputDevices: [MicrophoneInputDevice] = []
    private(set) var selectedInputDeviceID = ""

    var isAccessibilityTrusted: Bool { textInsertion.isAccessibilityTrusted }
    var currentStatusToken: StatusToken { StatusToken.from(statusText) }
    var currentErrorToken: ErrorToken? {
        guard let lastError else { return nil }
        return ErrorToken.from(lastError)
    }

    let settings: SettingsStore
    let textInsertion = TextInsertionService()

    // Services — internal so extension files can access them.
    @ObservationIgnored
    private var hasInitializedMicrophone = false
    @ObservationIgnored
    lazy var microphone: MicrophoneCaptureService = {
        hasInitializedMicrophone = true
        return MicrophoneCaptureService()
    }()
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
    let overlayBufferCoordinator: OverlayBufferSessionCoordinating
    @ObservationIgnored
    var preResolvedOverlayAnchor: OverlayAnchor?
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
    var finalizationWatchdogTask: Task<Void, Never>?
    @ObservationIgnored
    var isShowingConnectionFailureAlert = false
    @ObservationIgnored
    var realtimeFinalizationLastActivityAt: Date?
    @ObservationIgnored
    var isAwaitingMicrophonePermission = false
    @ObservationIgnored
    private var startupPermissionTask: Task<Void, Never>?
    @ObservationIgnored
    private var hasRequestedStartupPermissions = false
    @ObservationIgnored
    var pendingSegmentText = ""
    @ObservationIgnored
    var currentDictationEventText = ""
    @ObservationIgnored
    var sessionOutputMode: DictationOutputMode?
    @ObservationIgnored
    var firstChunkPreprocessor = FirstChunkPreprocessor()

    @ObservationIgnored
    let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

    @ObservationIgnored
    private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored
    private let managesRuntimeServices: Bool
    // Tracks physical key state so repeat key-down events do not retrigger actions.
    @ObservationIgnored
    private var isPushToTalkShortcutHeld = false
    // True only when a start attempt was initiated by push-to-talk and may still need
    // to be cancelled if the user releases before dictation actually begins.
    @ObservationIgnored
    private var hasActivePushToTalkShortcutSession = false

    init(
        settings: SettingsStore,
        overlayBufferCoordinator: OverlayBufferSessionCoordinating? = nil,
        startRuntimeServices: Bool = true
    ) {
        self.settings = settings
        self.managesRuntimeServices = startRuntimeServices
        if let overlayBufferCoordinator {
            self.overlayBufferCoordinator = overlayBufferCoordinator
        } else {
            let anchorResolver = OverlayAnchorResolver()
            self.overlayBufferCoordinator = OverlayBufferSessionCoordinator(
                stateMachine: OverlayBufferStateMachine(),
                renderer: DictationOverlayController(),
                anchorResolver: anchorResolver
            )
        }

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

        if startRuntimeServices {
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
        }

        textInsertion.onAccessibilityTrustChanged = { [weak self] in
            guard let self else { return }
            if self.currentErrorToken == .accessibilityPermissionRequired {
                self.lastError = nil
            }
            if !self.isDictating,
               (self.currentStatusToken == .waitingForAccessibilityPermission
                   || self.currentStatusToken == .pasteBlockedByAccessibilityPermission)
            {
                self.statusText = StatusStrings.ready
            }
        }

        networkMonitor.onChange = { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.handleNetworkChange(connected: connected)
            }
        }
        if startRuntimeServices {
            networkMonitor.start()
        }

        hotKeyManager.onPress = { [weak self] in self?.handleDictationShortcutPress() }
        hotKeyManager.onRelease = { [weak self] in self?.handleDictationShortcutRelease() }
        if startRuntimeServices {
            switch hotKeyManager.register(shortcut: settings.dictationShortcut) {
            case .success:
                break
            case .failure(let reason):
                applyHotKeyRegistrationFailure(reason)
            }
        }

        mlxStabilizer.onRealtimeInsertion = { [weak self] delta in
            self?.handleMlxRealtimeInsertionDelta(delta)
        }
        mlxStabilizer.onFinalizedInsertion = { [weak self] delta in
            self?.handleMlxFinalizedInsertionDelta(delta)
        }
        textInsertion.refreshAccessibilityTrustState()
        if startRuntimeServices {
            refreshMicrophoneInputs()
            registerLifecycleObservers()
            requestStartupPermissionsIfNeeded()
        }
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
        finalizationWatchdogTask?.cancel()
        startupPermissionTask?.cancel()
        textInsertion.stopAllTasks()
        overlayBufferCoordinator.reset()
        healthMonitor.cancelTasks()
        if managesRuntimeServices {
            if hasInitializedMicrophone {
                microphone.stop()
            }
            networkMonitor.stop()
            realtimeAPIClient.disconnect()
            mlxAudioRealtimeClient.disconnect()
            hotKeyManager.unregister()
        }
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

    private func requestStartupPermissionsIfNeeded() {
        guard managesRuntimeServices else { return }
        guard !hasRequestedStartupPermissions else { return }
        hasRequestedStartupPermissions = true

        startupPermissionTask?.cancel()
        startupPermissionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.requestStartupMicrophonePermissionIfNeeded()
            guard !Task.isCancelled else { return }
            self.requestStartupAccessibilityPermissionIfNeeded()
        }
    }

    private func requestStartupAccessibilityPermissionIfNeeded() {
        refreshAccessibilityTrustState()
        guard !textInsertion.isAccessibilityTrusted else { return }

        debugLog("startup accessibility permission prompt requested")
        textInsertion.requestAccessibilityPermissionIfNeeded()
    }

    private func requestStartupMicrophonePermissionIfNeeded() async {
        guard !isAwaitingMicrophonePermission else { return }
        guard microphone.authorizationStatus() == .notDetermined else { return }

        isAwaitingMicrophonePermission = true
        debugLog("startup microphone permission prompt requested")

        let granted = await withCheckedContinuation { continuation in
            microphone.requestAccess { granted in
                continuation.resume(returning: granted)
            }
        }

        guard !Task.isCancelled else { return }
        isAwaitingMicrophonePermission = false
        debugLog("startup microphone permission result granted=\(granted)")

        guard granted else {
            if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession {
                statusText = StatusStrings.microphoneAccessDenied
            }
            lastError = Self.microphoneDeniedMessage
            return
        }

        if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession,
           currentStatusToken == .awaitingMicrophonePermission
        {
            statusText = StatusStrings.ready
        }
    }

    // MARK: - Network

    private func handleNetworkChange(connected: Bool) {
        if connected {
            debugLog("network restored")
            if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession,
               (currentStatusToken == .networkLostDictationStopped
                   || currentStatusToken == .noNetworkConnection)
            {
                statusText = StatusStrings.ready
                lastError = nil
            }
        } else {
            debugLog("network lost")
            if isConnectingRealtimeSession {
                abortConnectingSession()
                let message = "Network connection was lost while connecting."
                handleConnectFailure(
                    status: StatusStrings.networkLostDictationStopped,
                    message: message,
                    technicalDetails: "Network path changed to unavailable while opening websocket."
                )
            } else if isDictating {
                stopDictation(reason: "network lost", finalizeRemainingAudio: false)
                statusText = StatusStrings.networkLostDictationStopped
                lastError = "Network connection was lost during dictation."
            } else if isFinalizingStop {
                activeRealtimeClient().disconnect()
                finishStoppedSession(promotePendingSegment: true)
                statusText = StatusStrings.networkLostDictationStopped
                lastError = "Network connection was lost during dictation."
            } else {
                statusText = StatusStrings.noNetworkConnection
            }
        }
    }

    // MARK: - Public API

    private func handleDictationShortcutPress() {
        switch settings.dictationShortcutMode {
        case .toggle:
            hasActivePushToTalkShortcutSession = false
            toggleDictation()
        case .pushToTalk:
            guard !isPushToTalkShortcutHeld else { return }
            isPushToTalkShortcutHeld = true
            guard !isDictating, !isConnectingRealtimeSession, !isFinalizingStop else { return }
            hasActivePushToTalkShortcutSession = true
            startDictation()
            if !isDictating, !isConnectingRealtimeSession, !isAwaitingMicrophonePermission {
                hasActivePushToTalkShortcutSession = false
            }
        }
    }

    private func handleDictationShortcutRelease() {
        guard isPushToTalkShortcutHeld else { return }
        isPushToTalkShortcutHeld = false

        guard settings.dictationShortcutMode == .pushToTalk else {
            hasActivePushToTalkShortcutSession = false
            return
        }
        guard hasActivePushToTalkShortcutSession else { return }

        if isConnectingRealtimeSession {
            abortConnectingSession()
            statusText = StatusStrings.ready
        } else if isDictating {
            stopDictation(reason: "push-to-talk release")
        } else if isAwaitingMicrophonePermission {
            // Keep the session marker until the permission callback resolves so we can
            // suppress starting if the key was released before permission was granted.
            statusText = StatusStrings.ready
            return
        }
        hasActivePushToTalkShortcutSession = false
    }

    func toggleDictation() {
        hasActivePushToTalkShortcutSession = false
        if isDictating {
            stopDictation(reason: "manual toggle")
        } else if isConnectingRealtimeSession {
            statusText = StatusStrings.connectingRealtimeBackend
        } else if isFinalizingStop {
            statusText = StatusStrings.finalizingPreviousDictation
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
               (currentStatusToken == .hotKeyHandlerRegistrationFailure
                || currentStatusToken == .hotKeyShortcutUnavailable)
            {
                statusText = StatusStrings.ready
            }

            if currentErrorToken == .hotKeyShortcutUnavailable
                || currentErrorToken == .hotKeyHandlerRegistrationFailure
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
            statusText = StatusStrings.connectingRealtimeBackend
            return
        }
        guard !isFinalizingStop else {
            statusText = StatusStrings.finalizingPreviousDictation
            return
        }
        guard !isAwaitingMicrophonePermission else {
            statusText = StatusStrings.awaitingMicrophonePermission
            return
        }
        guard networkMonitor.isConnected else {
            statusText = StatusStrings.noNetworkConnection
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

        switch microphone.authorizationStatus() {
        case .authorized:
            beginDictationSession()
        case .notDetermined:
            isAwaitingMicrophonePermission = true
            statusText = StatusStrings.requestingMicrophonePermission
            debugLog("microphone permission prompt requested")
            microphone.requestAccess { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isAwaitingMicrophonePermission = false
                    self.debugLog("microphone permission result granted=\(granted)")
                    guard granted else {
                        self.statusText = StatusStrings.microphoneAccessDenied
                        self.lastError = Self.microphoneDeniedMessage
                        self.hasActivePushToTalkShortcutSession = false
                        return
                    }
                    if self.hasActivePushToTalkShortcutSession,
                        !self.isPushToTalkShortcutHeld
                    {
                        self.statusText = StatusStrings.ready
                        self.hasActivePushToTalkShortcutSession = false
                        return
                    }
                    self.beginDictationSession()
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard let self, self.isAwaitingMicrophonePermission else { return }
                self.isAwaitingMicrophonePermission = false
                self.statusText = StatusStrings.ready
                if self.hasActivePushToTalkShortcutSession && !self.isPushToTalkShortcutHeld {
                    self.hasActivePushToTalkShortcutSession = false
                }
                self.debugLog("microphone permission prompt timed out")
            }
        case .denied, .restricted:
            statusText = StatusStrings.microphoneAccessDenied
            lastError = Self.microphoneDeniedMessage
            debugLog("microphone access denied or restricted")
        }
    }

    func stopDictation(reason: String = "unspecified", finalizeRemainingAudio: Bool = true) {
        guard isDictating else { return }
        debugLog("stopDictation reason=\(reason)")
        hasActivePushToTalkShortcutSession = false

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
        statusText = StatusStrings.finalizing
        setRealtimeIndicatorConnected()
        if isOverlayBufferModeEnabled {
            beginOverlayFinalization()
        }
        scheduleStopFinalization()
        startStopFinalizationWatchdog()
    }

    func clearTranscript() {
        transcriptText = ""
        livePartialText = ""
        lastFinalSegment = ""
        pendingSegmentText = ""
        currentDictationEventText = ""
        if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession {
            sessionOutputMode = nil
        }
        firstChunkPreprocessor.reset()
        mlxStabilizer.reset()
        overlayBufferCoordinator.reset()
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
            statusText = StatusStrings.ready
        } else {
            statusText = StatusStrings.waitingForAccessibilityPermission
        }
    }

    func refreshAccessibilityTrustState() {
        let wasTrusted = textInsertion.isAccessibilityTrusted
        textInsertion.refreshAccessibilityTrustState()

        if textInsertion.isAccessibilityTrusted, !wasTrusted, !isDictating,
           (currentStatusToken == .waitingForAccessibilityPermission
               || currentStatusToken == .pasteBlockedByAccessibilityPermission)
        {
            statusText = StatusStrings.ready
        }

        if let axError = textInsertion.lastAccessibilityError {
            if lastError == nil || currentErrorToken == .accessibilityPermissionRequired {
                lastError = axError
            }
        } else if currentErrorToken == .accessibilityPermissionRequired {
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
            statusText = StatusStrings.pasteBlockedByAccessibilityPermission
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

    var isOverlayBufferModeEnabled: Bool {
        activeOutputMode == .overlayBuffer
    }

    var isLiveAutoPasteModeEnabled: Bool {
        activeOutputMode == .liveAutoPaste
    }

    private var activeOutputMode: DictationOutputMode {
        sessionOutputMode ?? settings.dictationOutputMode
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

    private func handleMlxRealtimeInsertionDelta(_ delta: String) {
        guard isLiveAutoPasteModeEnabled else { return }
        textInsertion.enqueueRealtimeInsertion(delta)
    }

    private func handleMlxFinalizedInsertionDelta(_ delta: String) {
        guard isLiveAutoPasteModeEnabled else { return }
        if !textInsertion.insertTextUsingAccessibilityOnly(delta) {
            _ = textInsertion.pasteUsingCommandV(delta)
        }
    }
}
