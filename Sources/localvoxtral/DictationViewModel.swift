import AVFoundation
import AppKit
import Foundation
import Observation
import os

enum RealtimeSessionIndicatorState {
    case idle
    case connected
    case recentFailure
}

enum MenuBarIndicatorState: Equatable {
    case idle
    case connected
    case failure
    /// Secure Keyboard Entry is swallowing this session's keystrokes — shown
    /// with the failure icon because the menu bar is the only surface still
    /// visible while the popover is closed during dictation (#89).
    case secureInputWarning
}

/// A single raw realtime-delta log emission, captured before any
/// merge/preprocess/insertion processing. Mirrors what `Log.deltas` records
/// when `SettingsStore.debugLogRealtimeDeltas` is on; surfaced through the
/// `#if DEBUG` `debugDeltaLogSink` seam for instrumentation tests.
///
/// `payload` is the exact, unprocessed string the backend delivered (quoted in
/// the actual log via `.debugDescription` so whitespace is visible); it is nil
/// for events that carry no string payload (session boundaries, finalized).
struct DebugRealtimeDeltaLogRecord: Equatable, Sendable {
    enum Kind: String, Sendable {
        case sessionConnected = "session.connected"
        case sessionDisconnected = "session.disconnected"
        case partialDelta = "partial"
        case finalTranscript = "final"
        case status = "status"
        case error = "error"
        case transcriptionFinalized = "finalized"
    }

    let kind: Kind
    let sequence: Int
    let payload: String?
}

@MainActor
@Observable
final class DictationViewModel {
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
        case secureKeyboardEntryActive
        case other

        @MainActor
        static func from(_ message: String) -> ErrorToken {
            if message == TextInsertionService.accessibilityErrorMessage
                || message == DictationViewModel.liveAutoPasteAccessibilityWarningMessage
            {
                return .accessibilityPermissionRequired
            }
            if message == DictationViewModel.secureKeyboardEntryWarningMessage {
                return .secureKeyboardEntryActive
            }
            if message == HotKeyManager.handlerRegistrationErrorMessage {
                return .hotKeyHandlerRegistrationFailure
            }
            if message == HotKeyManager.unavailableErrorMessage
                || message == HotKeyManager.livePasteUnavailableErrorMessage
                || message == HotKeyManager.modifierOnlyUnavailableErrorMessage
            {
                return .hotKeyShortcutUnavailable
            }
            if message.localizedCaseInsensitiveContains("websocket receive failed") {
                return .websocketReceiveFailed
            }
            return .other
        }
    }

    enum StatusStrings {
        static let ready = "Ready"
        static let connectingRealtimeBackend = "Connecting to realtime backend..."
        static let finalizingPreviousDictation = "Finalizing previous dictation..."
        static let polishing = "Polishing..."
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

    /// Surfaced at dictation start (and in the popover) when Live Auto-Paste is
    /// active but Accessibility isn't trusted — transcribed text would otherwise
    /// land nowhere. Kept as a stable constant so `ErrorToken` can recognize it.
    static let liveAutoPasteAccessibilityWarningMessage =
        "Live Auto-Paste needs Accessibility access to type into other apps. Text won't appear until you enable it in System Settings > Privacy & Security > Accessibility."

    /// Surfaced at dictation start when macOS Secure Keyboard Entry is active
    /// (e.g. Ghostty around password prompts): it blocks synthetic keyboard
    /// events, so dictated text may silently land nowhere. Warn only — the
    /// session still runs. One short sentence (popover copy rule).
    static let secureKeyboardEntryWarningMessage =
        "Secure Keyboard Entry is on; dictated text may not appear."

    var isDictating = false
    var isFinalizingStop = false
    var isConnectingRealtimeSession = false
    var realtimeSessionIndicatorState: RealtimeSessionIndicatorState = .idle
    var transcriptText = ""
    var livePartialText = ""
    var statusText = StatusStrings.ready
    var lastError: String?
    // Raw message from the most recent websocket .error event this session.
    // Kept separate from lastError, which holds user-facing UI state (e.g. the
    // Accessibility warning) that must never leak into connection-failure details.
    var lastSocketErrorMessage: String?
    #if DEBUG
    // Test seam: technicalDetails otherwise only reaches the log and the alert.
    var debugLastConnectFailureTechnicalDetails: String?
    #endif
    var lastFinalSegment = ""

    /// Whether the app focused at the most recent session start behaves like
    /// a terminal emulator (bundle allowlist, AX-writability heuristic
    /// fallback). Refreshed at each session start; live replacement strategy
    /// and future per-app behaviors key off it. See `TerminalTargetDetector`.
    private(set) var sessionTargetIsTerminalLike = false

    private(set) var availableInputDevices: [MicrophoneInputDevice] = []
    private(set) var selectedInputDeviceID = ""

    /// Observable mirror of the live microphone authorization status, refreshed
    /// on demand via `refreshMicrophonePermissionState()`. Stored (rather than
    /// read live) so permission UI re-renders when the grant changes while the
    /// app is foregrounded. Seeded lazily — reading the real status touches the
    /// microphone service, so it stays `.notDetermined` until the first refresh.
    private(set) var microphoneAuthorizationStatus: MicrophoneAuthorizationStatus = .notDetermined

    /// Set by the app delegate so the General settings pane can re-present the
    /// onboarding wizard. Kept as a seam rather than a singleton reference.
    @ObservationIgnored
    var onRequestReRunOnboarding: (() -> Void)?

    var isAccessibilityTrusted: Bool { textInsertion.isAccessibilityTrusted }
    var currentStatusToken: StatusToken { StatusToken.from(statusText) }
    var currentErrorToken: ErrorToken? {
        guard let lastError else { return nil }
        return ErrorToken.from(lastError)
    }
    var requiredManagedBackendsReady: Bool {
        guard settings.onboardingCompleted else { return true }
        if settings.dictationBackendMode == .managedLocal,
           !isReady(backendManager.voxmlxStatus)
        {
            return false
        }
        if isManagedPolishingWarmupWanted,
           !isReady(backendManager.mlxLMStatus)
        {
            return false
        }
        return true
    }

    var menuBarIndicatorState: MenuBarIndicatorState {
        // Checked before .connected: the warning describes the session that
        // is connected right now — its keystrokes are being swallowed, and
        // the popover (where the text warning lives) is closed mid-dictation.
        // `sessionSecureInputActive` is tracked separately from `lastError`
        // because the Accessibility warning deliberately outranks the
        // secure-input POPOVER line — the icon must not vanish with it
        // (Codex review finding on #90).
        if sessionSecureInputActive || currentErrorToken == .secureKeyboardEntryActive {
            return .secureInputWarning
        }
        switch realtimeSessionIndicatorState {
        case .connected:
            return .connected
        case .recentFailure:
            return .failure
        case .idle:
            return requiredManagedBackendsReady ? .idle : .failure
        }
    }

    let settings: SettingsStore
    let textInsertion = TextInsertionService()

    /// Secure Keyboard Entry state sampled for the CURRENT session — drives
    /// the menu bar warning icon independently of `lastError` (whose popover
    /// line a higher-priority warning may own). Set when the session verdict
    /// is applied; cleared at session end alongside the token-scoped
    /// popover clear. Internal (not private(set)) because the session-end
    /// clear lives in DictationViewModel+Session.swift.
    var sessionSecureInputActive = false

    /// Played once at session start when Secure Keyboard Entry is detected.
    /// The popover is closed while dictating, so an audible cue is the only
    /// immediate signal that keystrokes will be swallowed (#89). Test seam.
    @ObservationIgnored
    var secureInputWarningSound: () -> Void = { NSSound(named: "Basso")?.play() }

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
    let audioChunkBuffer = AudioChunkBuffer()
    @ObservationIgnored
    let healthMonitor = AudioCaptureHealthMonitor()
    @ObservationIgnored
    var llmPolishingService: any LLMPolishingServicing = LLMPolishingService()
    @ObservationIgnored
    var appConfigStore: any AppConfigServing = AppConfigStore()
    @ObservationIgnored
    let backendManager: any ManagedBackendManaging
    @ObservationIgnored
    var sessionStore: DictationSessionStore?
    @ObservationIgnored
    let overlayBufferCoordinator: OverlayBufferSessionCoordinating
    @ObservationIgnored
    var preResolvedOverlayAnchor: OverlayAnchor?

    /// Terminal-like verdict + Secure Keyboard Entry state sampled in
    /// `beginDictationSession` BEFORE the socket opens — same reason as
    /// `preResolvedOverlayAnchor` above: the user may focus another app while
    /// the backend connects, and the session must record the app dictation
    /// was started in. Consumed (and cleared) once audio capture starts.
    @ObservationIgnored
    var preCapturedSessionTargetVerdict: SessionTargetVerdict?

    struct SessionTargetVerdict: Equatable, Sendable {
        let decision: TerminalTargetDetector.Decision
        let secureKeyboardEntryEnabled: Bool
    }
    @ObservationIgnored
    private let hotKeyManager = HotKeyManager()

    // Mutable state — internal so extension files can access.
    @ObservationIgnored
    var commitTask: Task<Void, Never>?
    @ObservationIgnored
    var managedStartupTask: Task<Void, Never>?
    @ObservationIgnored
    var managedStartupTaskID: UUID?
    // Stops the managed mlx-lm (polishing) process when LLM polishing is turned
    // off in Managed local mode. Kept awaitable so tests can await the shutdown.
    // Shutdown tasks are tracked (never fire-and-forget) so a warmup requested
    // right after a stop can cancel a still-queued stop and serialize behind a
    // running one — otherwise a stale stop lands after the fresh warmup and
    // kills the backend the settings now require.
    @ObservationIgnored
    var polishingShutdownTask: Task<Void, Never>?
    @ObservationIgnored
    var dictationShutdownTask: Task<Void, Never>?
    // Eagerly installs/downloads/starts required managed backends so the user
    // watches inline progress in Settings instead of waiting for dictation.
    // One slot per backend (mirroring BackendManager's per-backend single-flight
    // rationale): a polishing toggle/mode flip must never cancel an in-flight
    // voxmlx warmup, and vice versa. Kept awaitable for tests.
    @ObservationIgnored
    var dictationWarmupTask: Task<Void, Never>?
    @ObservationIgnored
    var polishingWarmupTask: Task<Void, Never>?
    @ObservationIgnored
    var audioSendTask: Task<Void, Never>?
    @ObservationIgnored
    var stopFinalizationTask: Task<Void, Never>?
    @ObservationIgnored
    var connectTimeoutTask: Task<Void, Never>?
    @ObservationIgnored
    var isResolvingConnectTimeout = false
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
    var polishAndCommitTask: Task<Void, Never>?
    @ObservationIgnored
    // Several finalization callbacks can converge here; keep stop cleanup
    // idempotent until commit/post-processing fully finishes.
    var isCompletingStoppedSession = false
    @ObservationIgnored
    var wasCancelled = false
    @ObservationIgnored
    let escapeCancelHandler = EscapeCancelHandler()
    @ObservationIgnored
    var sessionStartedAt: Date?
    @ObservationIgnored
    var sessionProvider: SettingsStore.RealtimeProvider?
    @ObservationIgnored
    var sessionModelName: String?
    @ObservationIgnored
    var sessionReplacementDictionary: ReplacementDictionary?
    @ObservationIgnored
    var firstChunkPreprocessor = FirstChunkPreprocessor()

    // Per-session sequence counter for the opt-in raw-delta log
    // (`SettingsStore.debugLogRealtimeDeltas`). Reset to 0 when a new realtime
    // session connects. Only mutated inside the gated logging path, so a value
    // of 0 while events are flowing proves the toggle is off. Internal so the
    // realtime-events extension can read/advance it.
    @ObservationIgnored
    var realtimeDeltaLogSequence = 0

    /// `#if DEBUG` test seam mirroring the raw-delta log emissions. Only
    /// invoked when `SettingsStore.debugLogRealtimeDeltas` is on (i.e. inside
    /// the same gated path that calls `Log.deltas`), so "sink not called when
    /// disabled" proves the logging call path was not entered. The record is
    /// the exact pre-processing payload the Logger would emit.
    @ObservationIgnored
    var debugDeltaLogSink: ((DebugRealtimeDeltaLogRecord) -> Void)?
    @ObservationIgnored
    var debugSavedSessionRecordSink: ((DictationSessionRecord) -> Void)?
    /// Test seam: invoked after the managed-startup status mirror finishes
    /// handling each status update (including updates its guard skips), so
    /// tests can await mirror processing deterministically instead of
    /// guessing with `Task.yield()`.
    @ObservationIgnored
    var debugManagedStatusMirrorEventSink: (() -> Void)?
    @ObservationIgnored
    var debugMicrophoneAuthorizationStatusOverride: MicrophoneAuthorizationStatus?
    @ObservationIgnored
    var debugHasRequestedStartupPermissions: Bool { hasRequestedStartupPermissions }

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
    // True when a modifier-only hold gesture started dictation (push-to-talk semantics).
    @ObservationIgnored
    private var isModifierOnlyHoldActive = false

    init(
        settings: SettingsStore,
        backendManager: (any ManagedBackendManaging)? = nil,
        overlayBufferCoordinator: OverlayBufferSessionCoordinating? = nil,
        startRuntimeServices: Bool = true
    ) {
        self.settings = settings
        self.backendManager = backendManager ?? BackendManager()
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
            // Preserve callback order for back-to-back events (e.g. final transcript
            // followed by transcription finalized) by routing through main-queue FIFO.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.handle(event: event)
                }
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
            self.retryModifierOnlyHotKeyRegistrationIfNeeded()
            if self.currentErrorToken == .accessibilityPermissionRequired {
                self.lastError = nil
            }
            if !self.isDictating,
               (self.currentStatusToken == .waitingForAccessibilityPermission
                   || self.currentStatusToken == .pasteBlockedByAccessibilityPermission)
            {
                self.statusText = StatusStrings.ready
            } else if self.isDictating,
                self.currentStatusToken == .pasteBlockedByAccessibilityPermission
            {
                // Accessibility just landed mid-session: clear the stale warning
                // so the menu bar / popover reflects that text will now arrive.
                self.statusText = "Listening..."
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

        hotKeyManager.onPressWithMode = { [weak self] mode in self?.handleDictationShortcutPress(mode: mode) }
        hotKeyManager.onPress = { [weak self] in self?.handleDictationShortcutPress() }
        hotKeyManager.onRelease = { [weak self] in self?.handleDictationShortcutRelease() }
        hotKeyManager.onHoldStart = { [weak self] in self?.handleModifierOnlyHoldStart() }
        hotKeyManager.onModifierOnlyTap = { [weak self] mode in self?.handleModifierOnlyTap(mode: mode) }
        if startRuntimeServices {
            registerCurrentHotKeys()
        }

        escapeCancelHandler.onCancel = { [weak self] in self?.cancelDictation() }

        textInsertion.refreshAccessibilityTrustState()
        if startRuntimeServices {
            sessionStore = DictationSessionStore()
            refreshMicrophoneInputs()
            registerLifecycleObservers()
            requestStartupPermissionsIfNeeded()
            warmUpManagedBackendsAtLaunchIfNeeded()
        }
    }

    @MainActor
    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        commitTask?.cancel()
        managedStartupTask?.cancel()
        managedStartupTaskID = nil
        polishingShutdownTask?.cancel()
        dictationShutdownTask?.cancel()
        dictationWarmupTask?.cancel()
        polishingWarmupTask?.cancel()
        audioSendTask?.cancel()
        stopFinalizationTask?.cancel()
        connectTimeoutTask?.cancel()
        recentFailureResetTask?.cancel()
        finalizationWatchdogTask?.cancel()
        startupPermissionTask?.cancel()
        polishAndCommitTask?.cancel()
        textInsertion.stopAllTasks()
        overlayBufferCoordinator.reset()
        healthMonitor.cancelTasks()
        escapeCancelHandler.stop()
        if managesRuntimeServices {
            if hasInitializedMicrophone {
                microphone.stop()
            }
            networkMonitor.stop()
            realtimeAPIClient.disconnect()
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
                guard let self else { return }
                self.cancelManagedStartupTask()
                if self.isDictating {
                    self.stopDictation(reason: "app terminating", finalizeRemainingAudio: false)
                }
                await self.backendManager.stopAll()
            }
        }

        lifecycleObservers = [sleepObserver, terminateObserver]
    }

    private func requestStartupPermissionsIfNeeded() {
        guard managesRuntimeServices else { return }
        guard settings.onboardingCompleted else {
            debugLog("startup permission prompts skipped until onboarding completes")
            return
        }
        guard !hasRequestedStartupPermissions else { return }
        hasRequestedStartupPermissions = true

        startupPermissionTask?.cancel()
        startupPermissionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.prepareLLMPolishingPromptAccessIfNeeded()
            guard !Task.isCancelled else { return }
            await self.requestStartupMicrophonePermissionIfNeeded()
            guard !Task.isCancelled else { return }
            self.requestStartupAccessibilityPermissionIfNeeded()
        }
    }

    func prepareLLMPolishingPromptAccessIfNeeded() {
        guard settings.llmPolishingEnabled else { return }

        debugLog("preloading LLM polishing prompt/config files")
        _ = appConfigStore.loadLLMPromptTemplates()
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
                handleConnectFailure(reason: .networkLost)
            } else if isDictating {
                stopDictation(reason: "network lost", finalizeRemainingAudio: false)
                statusText = StatusStrings.networkLostDictationStopped
                lastError = "Network connection was lost during dictation."
            } else if isFinalizingStop {
                realtimeAPIClient.disconnect()
                finishStoppedSession(promotePendingSegment: true)
                statusText = StatusStrings.networkLostDictationStopped
                lastError = "Network connection was lost during dictation."
            } else {
                statusText = StatusStrings.noNetworkConnection
            }
        }
    }

    // MARK: - Public API

    private func handleDictationShortcutPress(mode: DictationOutputMode? = nil) {
        switch settings.dictationShortcutMode {
        case .toggle:
            hasActivePushToTalkShortcutSession = false
            if isDictating {
                stopDictation(reason: "manual toggle")
            } else if isConnectingRealtimeSession {
                statusText = StatusStrings.connectingRealtimeBackend
            } else if isFinalizingStop {
                statusText = StatusStrings.finalizingPreviousDictation
            } else {
                startDictation(outputMode: mode)
            }
        case .pushToTalk:
            guard !isPushToTalkShortcutHeld else { return }
            isPushToTalkShortcutHeld = true
            guard !isDictating, !isConnectingRealtimeSession, !isFinalizingStop else { return }
            hasActivePushToTalkShortcutSession = true
            startDictation(outputMode: mode)
            if !isDictating, !isConnectingRealtimeSession, !isAwaitingMicrophonePermission {
                hasActivePushToTalkShortcutSession = false
            }
        }
    }

    private func handleDictationShortcutRelease() {
        // Modifier-only hold release
        if isModifierOnlyHoldActive {
            isModifierOnlyHoldActive = false
            isPushToTalkShortcutHeld = false
            if isDictating {
                stopDictation(reason: "modifier hold release")
            } else if isConnectingRealtimeSession {
                statusText = StatusStrings.connectingRealtimeBackend
                return
            } else if isAwaitingMicrophonePermission {
                statusText = StatusStrings.ready
                return
            }
            clearPushToTalkShortcutSessionAttempt()
            return
        }

        guard isPushToTalkShortcutHeld else { return }
        isPushToTalkShortcutHeld = false

        guard settings.dictationShortcutMode == .pushToTalk else {
            hasActivePushToTalkShortcutSession = false
            return
        }
        guard hasActivePushToTalkShortcutSession else { return }

        if isConnectingRealtimeSession {
            // Keep the connection attempt alive so timeout/errors surface to the user
            // instead of silently resetting to Ready on key release.
            statusText = StatusStrings.connectingRealtimeBackend
            return
        } else if isDictating {
            stopDictation(reason: "push-to-talk release")
        } else if isAwaitingMicrophonePermission {
            // Keep the session marker until the permission callback resolves so we can
            // suppress starting if the key was released before permission was granted.
            statusText = StatusStrings.ready
            return
        }
        clearPushToTalkShortcutSessionAttempt()
    }

    /// Modifier-only hold gesture started — use push-to-talk semantics with live auto-paste.
    private func handleModifierOnlyHoldStart() {
        guard !isDictating, !isConnectingRealtimeSession, !isFinalizingStop else { return }
        isModifierOnlyHoldActive = true
        isPushToTalkShortcutHeld = true
        hasActivePushToTalkShortcutSession = true
        startDictation(outputMode: .liveAutoPaste)
        if !isDictating, !isConnectingRealtimeSession, !isAwaitingMicrophonePermission {
            hasActivePushToTalkShortcutSession = false
            isModifierOnlyHoldActive = false
            isPushToTalkShortcutHeld = false
        }
    }

    /// Modifier-only TAP is a toggle by contract regardless of the configured
    /// shortcut behavior: taps have no release event, so routing them through
    /// push-to-talk semantics latches dictation on with no way to stop it.
    private func handleModifierOnlyTap(mode: DictationOutputMode) {
        toggleDictation(outputMode: mode)
    }

    func shouldCancelPushToTalkStartAfterConnect() -> Bool {
        hasActivePushToTalkShortcutSession
            && !isPushToTalkShortcutHeld
    }

    func clearPushToTalkShortcutSessionAttempt() {
        hasActivePushToTalkShortcutSession = false
    }

    func toggleDictation(outputMode: DictationOutputMode? = nil) {
        hasActivePushToTalkShortcutSession = false
        if isDictating {
            stopDictation(reason: "manual toggle")
        } else if isConnectingRealtimeSession {
            statusText = StatusStrings.connectingRealtimeBackend
        } else if isFinalizingStop {
            statusText = StatusStrings.finalizingPreviousDictation
        } else {
            startDictation(outputMode: outputMode)
        }
    }

    func cancelDictation() {
        guard isDictating || isFinalizingStop || isConnectingRealtimeSession else { return }
        wasCancelled = true
        cancelManagedStartupTask()
        if isDictating {
            stopDictation(reason: "cancelled", finalizeRemainingAudio: false)
        } else if isConnectingRealtimeSession {
            abortConnectingSession()
            statusText = StatusStrings.ready
        } else if isFinalizingStop {
            realtimeAPIClient.disconnect()
            finishStoppedSession(promotePendingSegment: false)
        }
    }

    /// Re-register the hotkey based on current settings.
    /// Called when modifier-only mode or modifier key selection changes.
    func applyHotKeySettingsChange() {
        switch registerCurrentHotKeys() {
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
        case .failure(let reason):
            applyHotKeyRegistrationFailure(reason)
        }
    }

    /// Modifier-only NSEvent monitors require Accessibility trust, and
    /// `AXIsProcessTrusted()` can transiently report false at cold launch even
    /// with a persisted grant (field-hit 2026-07-05: launch-time registration
    /// died and the shortcut stayed dead until the user touched the modifier
    /// setting). Once trust lands, re-register — but never churn a live
    /// registration.
    private func retryModifierOnlyHotKeyRegistrationIfNeeded() {
        guard settings.modifierOnlyHotKeyEnabled,
              textInsertion.isAccessibilityTrusted,
              !hotKeyManager.isModifierOnlyRegistrationActive
        else { return }
        Log.modifierKeys.notice(
            "Accessibility trust granted; retrying modifier-only hotkey registration."
        )
        applyHotKeySettingsChange()
    }

    func applyDictationBackendModeChange(_ mode: BackendMode) {
        let previousMode = settings.dictationBackendMode
        settings.dictationBackendMode = mode

        if previousMode == .externalURL, mode == .managedLocal {
            startManagedBackendWarmup(dictation: true, polishing: false)
            return
        }

        if previousMode == .managedLocal, mode == .externalURL {
            Log.backends.info("dictation backend mode switched to external; stopping managed voxmlx")
            cancelManagedStartupTask()
            dictationWarmupTask?.cancel()
            if isConnectingRealtimeSession {
                abortConnectingSession()
                statusText = StatusStrings.ready
            }
            dictationShutdownTask?.cancel()
            dictationShutdownTask = Task { @MainActor [backendManager] in
                guard !Task.isCancelled else { return }
                await backendManager.stopDictation()
            }
        }
    }

    func applyPolishingBackendModeChange(_ mode: BackendMode) {
        let previousMode = settings.polishingBackendMode
        settings.polishingBackendMode = mode

        if previousMode == .externalURL, mode == .managedLocal {
            if isManagedPolishingWarmupWanted {
                startPolishingWarmup()
            }
            return
        }

        if previousMode == .managedLocal, mode == .externalURL {
            Log.backends.info("polishing backend mode switched to external; stopping managed mlx-lm")
            cancelManagedStartupTask()
            polishingWarmupTask?.cancel()
            polishingShutdownTask?.cancel()
            polishingShutdownTask = Task { @MainActor [backendManager] in
                guard !Task.isCancelled else { return }
                await backendManager.stopPolishing()
            }
        }
    }

    func applyDictationOutputModeChange(_ mode: DictationOutputMode) {
        // The menu-bar output mode is not a reachability input (see
        // `isOverlayBufferSessionReachable`), so managed mlx-lm is unaffected.
        settings.dictationOutputMode = mode
    }

    /// The trigger picker in Settings > Dictation. Switching between the
    /// single-modifier gesture and per-mode shortcuts changes whether an
    /// Overlay Buffer session is reachable, so managed mlx-lm follows.
    func applyDictationTriggerModeChange(modifierOnlyEnabled: Bool) {
        guard settings.modifierOnlyHotKeyEnabled != modifierOnlyEnabled else { return }
        let wasReachable = settings.isOverlayBufferSessionReachable
        settings.modifierOnlyHotKeyEnabled = modifierOnlyEnabled
        applyHotKeySettingsChange()
        handleOverlayReachabilityTransition(wasReachable: wasReachable)
    }

    /// Managed mlx-lm follows Overlay Buffer reachability: polishing runs only
    /// on Overlay Buffer commits, so when no trigger can start one the process
    /// is stopped instead of idling in memory.
    func handleOverlayReachabilityTransition(wasReachable: Bool) {
        let isReachable = settings.isOverlayBufferSessionReachable
        guard wasReachable != isReachable,
              settings.llmPolishingEnabled,
              settings.polishingBackendMode == .managedLocal
        else { return }

        if isReachable {
            startPolishingWarmup()
        } else {
            Log.backends.info("no Overlay Buffer trigger configured; stopping managed mlx-lm")
            polishingWarmupTask?.cancel()
            polishingShutdownTask?.cancel()
            polishingShutdownTask = Task { @MainActor [backendManager] in
                guard !Task.isCancelled else { return }
                await backendManager.stopPolishing()
            }
        }
    }

    /// React to the LLM polishing enable toggle. Disabling polishing in Managed
    /// local polishing mode stops the managed mlx-lm process so it stops holding memory.
    /// Enabling in Managed local mode eagerly starts the polishing warmup so
    /// install/model progress is visible in Settings. External URL mode owns
    /// no local process.
    /// Any polish request in flight when the process stops fails, and the
    /// existing polish-failure fallback commits the raw text.
    func llmPolishingEnabledDidChange(_ enabled: Bool) {
        guard settings.polishingBackendMode == .managedLocal else { return }
        polishingShutdownTask?.cancel()
        if enabled, settings.isOverlayBufferSessionReachable {
            startPolishingWarmup()
        } else {
            Log.backends.info("polishing disabled; stopping managed mlx-lm")
            polishingWarmupTask?.cancel()
            polishingShutdownTask = Task { @MainActor [backendManager] in
                guard !Task.isCancelled else { return }
                await backendManager.stopPolishing()
            }
        }
    }

    func warmUpManagedBackendsAtLaunchIfNeeded() {
        guard settings.onboardingCompleted else {
            Log.backends.info("launch managed backend warmup skipped until onboarding completes")
            return
        }

        let needsDictation = settings.dictationBackendMode == .managedLocal
        let needsPolishing = isManagedPolishingWarmupWanted
        startManagedBackendWarmup(dictation: needsDictation, polishing: needsPolishing)
    }

    func startPolishingWarmup() {
        startManagedBackendWarmup(dictation: false, polishing: true)
    }

    func startManagedBackendWarmup(dictation: Bool, polishing: Bool) {
        guard dictation || polishing else { return }
        guard settings.onboardingCompleted else {
            Log.backends.info("managed backend warmup skipped until onboarding completes")
            return
        }

        // Owner-specified UX: required managed backends install/download/start
        // eagerly, with progress rendered inline in Endpoints.
        // Failures land in the manager statuses; dictation-time ensureReady remains the
        // backstop and retry path.
        Log.backends.info(
            "managed backend warmup requested dictation=\(dictation, privacy: .public) polishing=\(polishing, privacy: .public)"
        )
        // A stop decided just before this warmup must not land on the fresh
        // process: cancel the shutdown if it hasn't run yet, and serialize the
        // warmup behind it if it has (rapid managed→external→managed or
        // polishing off→on flips race the async stop otherwise).
        if dictation {
            dictationWarmupTask?.cancel()
            let pendingShutdown = dictationShutdownTask
            dictationShutdownTask = nil
            pendingShutdown?.cancel()
            dictationWarmupTask = Task { @MainActor [backendManager] in
                await pendingShutdown?.value
                try? await backendManager.ensureReady(dictation: true, polishing: false)
            }
        }
        if polishing {
            polishingWarmupTask?.cancel()
            let pendingShutdown = polishingShutdownTask
            polishingShutdownTask = nil
            pendingShutdown?.cancel()
            polishingWarmupTask = Task { @MainActor [backendManager] in
                await pendingShutdown?.value
                try? await backendManager.ensureReady(dictation: false, polishing: true)
            }
        }
    }

    /// Writes a local-first diagnostics report to the Desktop. The report
    /// contains only non-secret configuration/status (no API keys, no dictated
    /// content). See `DiagnosticsExporter` for the redaction boundary.
    func exportDiagnostics() {
        let snapshot = DiagnosticsExporter.makeSnapshot(
            settings: settings,
            voxmlxStatus: backendManager.voxmlxStatus,
            mlxLMStatus: backendManager.mlxLMStatus,
            voxmlxRecentOutput: backendManager.recentOutput(for: BackendCatalog.voxmlx),
            mlxLMRecentOutput: backendManager.recentOutput(for: BackendCatalog.mlxLM)
        )

        guard let desktop = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first else {
            Log.diagnostics.error("diagnostics export failed: Desktop directory unavailable")
            return
        }

        let exportedAt = Date()
        Task.detached(priority: .utility) {
            do {
                let writtenURL = try DiagnosticsExporter.writeReport(
                    snapshot: snapshot,
                    to: desktop,
                    now: exportedAt
                )
                Log.diagnostics.info("diagnostics exported: \(writtenURL.path, privacy: .public)")
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([writtenURL])
                }
            } catch {
                Log.diagnostics.error("diagnostics export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Register hotkeys based on current settings.
    /// Uses modifier-only, dual shortcuts, or legacy single shortcut depending on config.
    @discardableResult
    private func registerCurrentHotKeys() -> HotKeyManager.RegistrationResult {
        if settings.modifierOnlyHotKeyEnabled {
            return hotKeyManager.registerModifierOnly(
                settings.modifierOnlyHotKeyModifier,
                holdThreshold: settings.modifierOnlyHoldDelay
            )
        }

        // Use dual shortcut registration
        let overlayShortcut = settings.overlayBufferShortcut
        let livePasteShortcut = settings.livePasteShortcut

        return hotKeyManager.registerDual(
            overlay: overlayShortcut,
            livePaste: livePasteShortcut
        )
    }

    func updateDictationShortcut(_ shortcut: DictationShortcut?) {
        let previousShortcut = settings.dictationShortcut
        let previousWasEnabled = settings.dictationShortcutEnabled

        settings.setDictationShortcut(shortcut)

        switch registerCurrentHotKeys() {
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
            _ = registerCurrentHotKeys()
            applyHotKeyRegistrationFailure(reason)
        }
    }

    func updateOverlayBufferShortcut(_ shortcut: DictationShortcut?) {
        let previousShortcut = settings.overlayBufferShortcut
        let previousWasEnabled = settings.overlayBufferShortcutEnabled
        let wasReachable = settings.isOverlayBufferSessionReachable

        settings.setOverlayBufferShortcut(shortcut)

        switch registerCurrentHotKeys() {
        case .success:
            clearHotKeyErrors()
        case .failure(let reason):
            if previousWasEnabled {
                settings.setOverlayBufferShortcut(previousShortcut ?? SettingsStore.defaultDictationShortcut)
            } else {
                settings.setOverlayBufferShortcut(nil)
            }
            _ = registerCurrentHotKeys()
            applyHotKeyRegistrationFailure(reason)
        }
        handleOverlayReachabilityTransition(wasReachable: wasReachable)
    }

    func updateLivePasteShortcut(_ shortcut: DictationShortcut?) {
        let previousShortcut = settings.livePasteShortcut
        let previousWasEnabled = settings.livePasteShortcutEnabled

        settings.setLivePasteShortcut(shortcut)

        switch registerCurrentHotKeys() {
        case .success:
            clearHotKeyErrors()
        case .failure(let reason):
            if previousWasEnabled, let previousShortcut {
                settings.setLivePasteShortcut(previousShortcut)
            } else {
                settings.setLivePasteShortcut(nil)
            }
            _ = registerCurrentHotKeys()
            applyHotKeyRegistrationFailure(reason)
        }
    }

    private func clearHotKeyErrors() {
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

    func startDictation(outputMode: DictationOutputMode? = nil) {
        guard !isDictating else { return }
        guard !isConnectingRealtimeSession else {
            statusText = StatusStrings.connectingRealtimeBackend
            return
        }
        if isFinalizingStop {
            guard cancelPolishingForNewSessionIfNeeded() else {
                statusText = StatusStrings.finalizingPreviousDictation
                return
            }
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

        switch currentMicrophoneAuthorizationStatus() {
        case .authorized:
            beginDictationAfterManagedBackendIfNeeded(outputMode: outputMode)
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
                    self.beginDictationAfterManagedBackendIfNeeded(outputMode: outputMode)
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

    func currentMicrophoneAuthorizationStatus() -> MicrophoneAuthorizationStatus {
        #if DEBUG
        if let debugMicrophoneAuthorizationStatusOverride {
            return debugMicrophoneAuthorizationStatusOverride
        }
        #endif
        // A mere status read (the onboarding/General permission rows) must
        // not force the lazy capture service into existence; but once the
        // service exists, ask it, so any injected replacement stays
        // authoritative.
        guard hasInitializedMicrophone else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .authorized
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            case .notDetermined:
                return .notDetermined
            @unknown default:
                return .notDetermined
            }
        }
        return microphone.authorizationStatus()
    }

    func stopDictation(reason: String = "unspecified", finalizeRemainingAudio: Bool = true) {
        guard isDictating else { return }
        debugLog("stopDictation reason=\(reason)")
        hasActivePushToTalkShortcutSession = false

        polishAndCommitTask?.cancel()
        polishAndCommitTask = nil
        commitTask?.cancel()
        commitTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        healthMonitor.stop()
        isAwaitingMicrophonePermission = false

        microphone.stop()
        flushBufferedAudio()
        isDictating = false
        escapeCancelHandler.stop()

        guard finalizeRemainingAudio else {
            realtimeAPIClient.disconnect()
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
            clearLatchedSessionMetadata()
        }
        firstChunkPreprocessor.reset()
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

    /// Re-read the live microphone authorization status into the observable
    /// mirror. Reading only — never prompts. Call on appear / app activation so
    /// permission rows reflect grants made in System Settings.
    func refreshMicrophonePermissionState() {
        let status = currentMicrophoneAuthorizationStatus()
        if microphoneAuthorizationStatus != status {
            microphoneAuthorizationStatus = status
        }
    }

    /// Samples the terminal-like verdict and Secure Keyboard Entry state for
    /// the app focused right now. Called from `beginDictationSession` before
    /// the socket opens (see `preCapturedSessionTargetVerdict`).
    /// Opt-in field diagnostic: scalar tracing of posted keyboard chunks is
    /// enabled per session by the presence of the `insertion_scalar_trace`
    /// marker file in the shared config folder (same gate pattern as the
    /// eval-llm marker). Called at each dictation session start.
    func refreshInsertionScalarTracingForSession() {
        let markerURL = appConfigStore.configDirectoryURL()
            .appendingPathComponent("insertion_scalar_trace", isDirectory: false)
        let enabled = FileManager.default.fileExists(atPath: markerURL.path)
        if enabled, !textInsertion.isScalarTracingEnabled {
            Log.insertion.notice("scalar-trace enabled for this session (marker file present)")
        }
        textInsertion.isScalarTracingEnabled = enabled
    }

    func captureSessionTargetVerdict() {
        let userBundleIDs = Set(appConfigStore.loadTerminalAppBundleIDs())
        preCapturedSessionTargetVerdict = SessionTargetVerdict(
            decision: TerminalTargetDetector.detectCurrentTarget(userBundleIDs: userBundleIDs),
            secureKeyboardEntryEnabled: TerminalTargetDetector.isSecureKeyboardEntryEnabled()
        )
    }

    /// Consumes the verdict captured at `beginDictationSession` time once
    /// audio capture starts, and warns (without blocking) when Secure
    /// Keyboard Entry would swallow synthetic keystrokes. Lives in this file
    /// (not +Session) so `sessionTargetIsTerminalLike` stays private(set).
    func applyPreCapturedSessionTargetVerdict() {
        // Fallback probe covers paths that reach audio start without a
        // capture (should not happen; keeps the verdict defined regardless).
        let verdict = preCapturedSessionTargetVerdict ?? SessionTargetVerdict(
            decision: TerminalTargetDetector.detectCurrentTarget(),
            secureKeyboardEntryEnabled: TerminalTargetDetector.isSecureKeyboardEntryEnabled()
        )
        preCapturedSessionTargetVerdict = nil
        sessionTargetIsTerminalLike = verdict.decision.isTerminalLike
        sessionSecureInputActive = verdict.secureKeyboardEntryEnabled

        if verdict.secureKeyboardEntryEnabled {
            // Never mask the Accessibility-trust warning — it explains a
            // total insertion failure, which outranks a secure-input maybe.
            if currentErrorToken != .accessibilityPermissionRequired {
                lastError = Self.secureKeyboardEntryWarningMessage
            }
            // Audible regardless of which warning owns the popover line: the
            // session that just started will type nothing either way.
            secureInputWarningSound()
            Log.target.warning(
                "Secure Keyboard Entry is enabled at session start; synthetic keyboard events may be blocked."
            )
        } else if currentErrorToken == .secureKeyboardEntryActive {
            // Stale warning from an earlier session; secure input is off now.
            lastError = nil
        }
    }

    /// Prompt for microphone access if it has not been decided yet. When access
    /// was already denied/restricted the system dialog no longer appears, so the
    /// permission UI routes the user to System Settings instead. Refreshes the
    /// observable status once the request resolves.
    func requestMicrophonePermission() {
        microphone.requestAccess { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMicrophonePermissionState()
            }
        }
    }

    /// Reset the first-launch flag and ask the app delegate to re-present the
    /// onboarding wizard. Invoked by the General settings pane's "Re-run Setup…".
    func reRunOnboarding() {
        settings.onboardingCompleted = false
        onRequestReRunOnboarding?()
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

    func openConfigFolder() {
        let url = appConfigStore.configDirectoryURL()
        NSWorkspace.shared.open(url)
    }

    func pasteLatestSegment() {
        let segment = lastFinalSegment.trimmed
        guard !segment.isEmpty else { return }

        textInsertion.refreshAccessibilityTrustState()

        let directInsertResult = textInsertion.insertText(segment)
        if directInsertResult.isSuccess {
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

    /// Non-nil when Live Auto-Paste is the active output mode but Accessibility
    /// isn't trusted — the condition under which transcribed text lands nowhere.
    /// Used to surface a warning in the popover and at dictation start. Derived
    /// from existing state; no new stored state.
    var liveAutoPasteAccessibilityWarning: String? {
        guard isLiveAutoPasteModeEnabled, !textInsertion.isAccessibilityTrusted else {
            return nil
        }
        return Self.liveAutoPasteAccessibilityWarningMessage
    }

    func isManagedPolishingRequired(outputMode: DictationOutputMode) -> Bool {
        outputMode == .overlayBuffer
            && settings.llmPolishingEnabled
            && settings.polishingBackendMode == .managedLocal
    }

    /// Warmup-time variant of `isManagedPolishingRequired`: instead of a
    /// session's output mode, gates on whether a keyboard trigger can start
    /// an Overlay Buffer session at all. When false, managed mlx-lm stays
    /// stopped — an overlay session started from the menu-bar button still
    /// polishes via the dictation-time `ensureReady` backstop, paying the
    /// mlx-lm cold start (deliberate: see
    /// `SettingsStore.isOverlayBufferSessionReachable`).
    var isManagedPolishingWarmupWanted: Bool {
        settings.llmPolishingEnabled
            && settings.polishingBackendMode == .managedLocal
            && settings.isOverlayBufferSessionReachable
    }

    private var activeOutputMode: DictationOutputMode {
        sessionOutputMode ?? settings.dictationOutputMode
    }

    private func isReady(_ status: ManagedBackendStatus) -> Bool {
        if case .ready = status {
            return true
        }
        return false
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
        case .livePasteShortcutUnavailable:
            statusText = HotKeyManager.registrationErrorStatus
            lastError = HotKeyManager.livePasteUnavailableErrorMessage
        case .modifierOnlyHotKeyUnavailable:
            statusText = HotKeyManager.registrationErrorStatus
            lastError = HotKeyManager.modifierOnlyUnavailableErrorMessage
        }
    }
}

#if DEBUG
extension DictationViewModel {
    func debugHandleDictationShortcutPressForTesting(mode: DictationOutputMode? = nil) {
        handleDictationShortcutPress(mode: mode)
    }

    func debugHandleDictationShortcutReleaseForTesting() {
        handleDictationShortcutRelease()
    }

    func debugHandleModifierOnlyTapForTesting(mode: DictationOutputMode) {
        handleModifierOnlyTap(mode: mode)
    }

    func debugHandleModifierOnlyHoldStartForTesting() {
        handleModifierOnlyHoldStart()
    }

    var debugIsPushToTalkShortcutHeldForTesting: Bool {
        isPushToTalkShortcutHeld
    }

    func debugSetPushToTalkShortcutStateForTesting(
        isHeld: Bool,
        hasActiveSession: Bool
    ) {
        isPushToTalkShortcutHeld = isHeld
        hasActivePushToTalkShortcutSession = hasActiveSession
    }

    /// Install a sink that receives every raw-delta log emission captured by
    /// `logRawRealtimeEventIfEnabled`. Only fires when
    /// `SettingsStore.debugLogRealtimeDeltas` is on (same gated path as
    /// `Log.deltas`), so it doubles as an observation point for "logging path
    /// not entered when disabled". Pass `nil` to clear.
    func debugConfigureDeltaLogSink(_ sink: ((DebugRealtimeDeltaLogRecord) -> Void)?) {
        debugDeltaLogSink = sink
    }

    func debugSetModifierOnlyHoldStateForTesting(isActive: Bool) {
        isModifierOnlyHoldActive = isActive
    }

    var debugCurrentHotKeyRegistrationKindForTesting: HotKeyManager.DebugRegistrationKind {
        hotKeyManager.debugCurrentRegistrationKind
    }
}
#endif
