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
        case microphoneDisconnected
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
            if message == DictationViewModel.microphoneDisconnectedMessage {
                return .microphoneDisconnected
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
        static let networkLostDictationStopped = "Dictation stopped after the network disconnected."
        static let liveDictationBlockedBySecureInput = "Secure Keyboard Entry blocks Live Auto-Paste."
        static let overlayCopiedToClipboard = "Copied for manual paste."
        static let noNetworkConnection = "No network connection."
        static let microphoneAccessDenied = "Microphone access denied."
        static let finalizing = "Finalizing..."
        static let reconnecting = "Reconnecting..."
    }

    /// Where a dictation lands when the realtime socket is gone for good:
    /// either the reconnect exhausted its attempts, or the drop was not
    /// recoverable in the first place.
    static let connectionLostMessage = "Connection lost. Dictation stopped."

    static let microphoneDisconnectedMessage = "Mic disconnected."
    static let microphoneDeniedMessage =
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
        "Secure Keyboard Entry may hide dictated text."

    /// The dictation itself: start, connect, the realtime events, stop,
    /// reconnect and the commit. The members below forward the session state
    /// the views read.
    @ObservationIgnored
    let session: DictationSessionController

    var isDictating: Bool { get { session.isDictating } set { session.isDictating = newValue } }
    var isFinalizingStop: Bool { get { session.isFinalizingStop } set { session.isFinalizingStop = newValue } }
    var isConnectingRealtimeSession: Bool {
        get { session.isConnectingRealtimeSession }
        set { session.isConnectingRealtimeSession = newValue }
    }
    var realtimeSessionIndicatorState: RealtimeSessionIndicatorState {
        get { session.realtimeSessionIndicatorState }
        set { session.realtimeSessionIndicatorState = newValue }
    }
    var transcript: TranscriptAccumulator { get { session.transcript } set { session.transcript = newValue } }
    var statusText: String { get { session.statusText } set { session.statusText = newValue } }
    var lastError: String? { get { session.lastError } set { session.lastError = newValue } }
    var lastFinalSegment: String { session.lastFinalSegment }
    var lastPolishChangedRawTranscript: String? {
        get { session.lastPolishChangedRawTranscript }
        set { session.lastPolishChangedRawTranscript = newValue }
    }
    var canCopyRawTranscript: Bool { session.canCopyRawTranscript }
    var sessionSecureInputActive: Bool {
        get { session.sessionSecureInputActive }
        set { session.sessionSecureInputActive = newValue }
    }
    var isAwaitingMicrophonePermission: Bool {
        get { session.isAwaitingMicrophonePermission }
        set { session.isAwaitingMicrophonePermission = newValue }
    }
    var isAccessibilityTrusted: Bool { session.isAccessibilityTrusted }
    var currentStatusToken: StatusToken { session.currentStatusToken }
    var currentErrorToken: ErrorToken? { session.currentErrorToken }
    var liveAutoPasteAccessibilityWarning: String? { session.liveAutoPasteAccessibilityWarning }
    var audio: SessionAudioPipeline { session.audio }
    var availableInputDevices: [MicrophoneInputDevice] { session.availableInputDevices }
    var selectedInputDeviceID: String { session.selectedInputDeviceID }
    var selectedInputDeviceChannelCount: UInt32 { session.selectedInputDeviceChannelCount }
    var selectedInputChannel: Int { session.selectedInputChannel }
    var context: SessionContextResolver { session.context }
    var dependencies: Dependencies { get { session.dependencies } set { session.dependencies = newValue } }
    var llmPolishingService: any LLMPolishingServicing {
        get { session.llmPolishingService }
        set { session.llmPolishingService = newValue }
    }
    var appConfigStore: any AppConfigServing {
        get { session.appConfigStore }
        set { session.appConfigStore = newValue }
    }
    var sessionStore: DictationSessionStore? { get { session.sessionStore } set { session.sessionStore = newValue } }
    var learnedTermStore: LearnedTermStore? {
        get { session.learnedTermStore }
        set { session.learnedTermStore = newValue }
    }
    var termSuggestions: SpeakerTermSuggestionModel { session.termSuggestions }

    func toggleDictation(outputMode: DictationOutputMode? = nil) { session.toggleDictation(outputMode: outputMode) }
    func startDictation(outputMode: DictationOutputMode? = nil) { session.startDictation(outputMode: outputMode) }
    func stopDictation(reason: String = "unspecified", finalizeRemainingAudio: Bool = true) {
        session.stopDictation(reason: reason, finalizeRemainingAudio: finalizeRemainingAudio)
    }
    func cancelDictation() { session.cancelDictation() }
    func refreshMicrophoneInputs() { session.refreshMicrophoneInputs() }
    func selectMicrophoneInput(id: String) { session.selectMicrophoneInput(id: id) }
    func selectMicrophoneInputChannel(_ channel: Int) { session.selectMicrophoneInputChannel(channel) }
    func clearTranscript() { session.clearTranscript() }
    func copyTranscript() { session.copyTranscript() }
    func copyLatestSegment(updateStatus: Bool = true) { session.copyLatestSegment(updateStatus: updateStatus) }
    func copyRawTranscript() { session.copyRawTranscript() }
    func pasteLatestSegment() { session.pasteLatestSegment() }
    func applyDictationHistoryRetention(now: Date = Date()) { session.applyDictationHistoryRetention(now: now) }
    func prepareLLMPolishingPromptAccessIfNeeded() { session.prepareLLMPolishingPromptAccessIfNeeded() }


    /// Set by the app delegate so the General settings pane can re-present the
    /// onboarding wizard. Kept as a seam rather than a singleton reference.
    @ObservationIgnored
    var onRequestReRunOnboarding: (() -> Void)?

    var requiredManagedBackendsReady: Bool {
        guard settings.onboardingCompleted else { return true }
        if settings.dictationBackendMode == .managedLocal,
           !isReady(backendManager.speechdStatus)
        {
            return false
        }
        if engines.isManagedPolishingWarmupWanted,
           !isReady(backendManager.polishdStatus)
        {
            return false
        }
        return true
    }

    var menuBarIndicatorState: MenuBarIndicatorState {
        // Checked before .connected: the warning describes the session that
        // is connected right now — its keystrokes are being swallowed, and
        // the popover (where the text warning lives) is closed mid-dictation.
        // Gated ONLY on the session-attempt flag, tracked separately from
        // `lastError`: the Accessibility warning may own the popover line
        // without hiding the icon (Codex finding), and the popover line may
        // outlive the icon as the explanation after a refused-start gesture
        // ends (owner field feedback — the icon must not stay lit after the
        // modifier is released).
        if sessionSecureInputActive {
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

    /// The Engines pane: backend modes, the Mistral key check and model
    /// catalog, managed warmup and shutdown, the download controls. Views
    /// bind to `viewModel.engines`; nothing on the session path goes
    /// through it.
    @ObservationIgnored
    let engines: EnginesModel
    /// Bumped after every history write that landed, so the History pane
    /// reads the store again.
    private(set) var dictationHistoryRevision = 0

    /// The collaborators a view model is built from. Production defaults;
    /// a test replaces the ones it has to observe or hold still. Each field
    /// retires a `debug…` seam (#432 step 2).
    struct Dependencies {
        /// Built on first use, so a mere permission read never registers
        /// CoreAudio device listeners. Nil is the CoreAudio service.
        var microphone: (() -> any MicrophoneCapturing)?
        /// The pasteboard the polish context and the payload macro read. Both
        /// read the one clipboard; a counting stub proves the no-read paths.
        var pasteboardReader: @MainActor () -> any PasteboardReading
        /// Where the copy actions write.
        var pasteboardWriter: @MainActor (String) -> Void
        /// The bundle identifier of a running process, for the app the
        /// overlay commits into.
        var bundleIdentifier: (pid_t) -> String?
        /// The center the sleep and terminate observers register on. Nil is
        /// the default center, registered only when runtime services run; a
        /// private center is registered on regardless, so a test posts
        /// through the real wiring without reaching every retained view
        /// model in the process.
        var lifecycleNotificationCenter: NotificationCenter?
        /// The clock a mid-dictation reconnect run (#380) sleeps on.
        var reconnectSleep: @MainActor (TimeInterval) async -> Void
        /// Where a connection failure the popover cannot carry is shown.
        var connectionFailurePresenter: any ConnectionFailurePresenting
        /// Every record a session writes, before retention decides whether
        /// the store keeps it. Nothing in the app observes; tests do.
        var onSessionRecord: ((DictationSessionRecord) -> Void)?
        /// The repository vocabulary a commit grounds against. Nil is the
        /// production pipeline over the commit target's working directory.
        var repoVocabularyGrounding: (any RepoVocabularyGrounding)?
        /// Every raw-delta log record, called on the same gated path as
        /// `Log.deltas` (the hidden `debug.log_realtime_deltas` toggle), so
        /// "never called with the toggle off" proves the path was not
        /// entered. Nothing in the app observes; tests do.
        var onRealtimeDeltaLogRecord: ((DebugRealtimeDeltaLogRecord) -> Void)?
        /// The time every session timer runs on. A test passes a clock it
        /// advances by hand.
        var clock: SessionClock

        init(
            microphone: (() -> any MicrophoneCapturing)? = nil,
            pasteboardReader: @escaping @MainActor () -> any PasteboardReading = { SystemPasteboardReader() },
            pasteboardWriter: @escaping @MainActor (String) -> Void = DictationViewModel.writeToSystemPasteboard,
            bundleIdentifier: @escaping (pid_t) -> String? = {
                NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
            },
            lifecycleNotificationCenter: NotificationCenter? = nil,
            reconnectSleep: @escaping @MainActor (TimeInterval) async -> Void =
                DictationSessionController.sleepForReconnect,
            connectionFailurePresenter: any ConnectionFailurePresenting = ModalConnectionFailurePresenter(),
            onSessionRecord: ((DictationSessionRecord) -> Void)? = nil,
            repoVocabularyGrounding: (any RepoVocabularyGrounding)? = nil,
            onRealtimeDeltaLogRecord: ((DebugRealtimeDeltaLogRecord) -> Void)? = nil,
            clock: SessionClock = .live
        ) {
            self.microphone = microphone
            self.pasteboardReader = pasteboardReader
            self.pasteboardWriter = pasteboardWriter
            self.bundleIdentifier = bundleIdentifier
            self.lifecycleNotificationCenter = lifecycleNotificationCenter
            self.reconnectSleep = reconnectSleep
            self.connectionFailurePresenter = connectionFailurePresenter
            self.onSessionRecord = onSessionRecord
            self.repoVocabularyGrounding = repoVocabularyGrounding
            self.onRealtimeDeltaLogRecord = onRealtimeDeltaLogRecord
            self.clock = clock
        }
    }
    /// Warms the managed polishing helper's prompt-prefix cache on every
    /// helper launch (see `PolishPromptWarmupCoordinator`). Created only when
    /// runtime services run — trigger logic is unit-tested on the coordinator
    /// directly.
    @ObservationIgnored
    private(set) var polishPromptWarmupCoordinator: PolishPromptWarmupCoordinator?
    @ObservationIgnored
    let backendManager: any ManagedBackendManaging
    /// Bumped on every learned-terms write so the Settings row re-reads it.
    private(set) var learnedTermRevision = 0



    /// Settings surface for the two Claude Code integrations.
    ///
    /// Installed by `AppDelegate`, which owns the host registry and the listener
    /// — the same reason the resolver above is installed rather than
    /// constructed: those live for the app's lifetime, not a dictation's. Nil
    /// only when the app delegate never ran (previews, unit tests), and the
    /// Settings rows simply do not render.
    ///
    /// NOT `@ObservationIgnored`: the pane re-renders when the model swaps in.
    var claudeIntegrationSettings: ClaudeIntegrationSettingsModel?




    @ObservationIgnored
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// The center `lifecycleObservers` were registered on, so deinit removes
    /// them from the same one.
    @ObservationIgnored
    private var lifecycleNotificationCenter: NotificationCenter = .default
    @ObservationIgnored
    let managesRuntimeServices: Bool
    /// When true, the startup permission-prompt pass (microphone +
    /// Accessibility) is skipped entirely. Driven by
    /// `LOCALVOXTRAL_SUPPRESS_STARTUP_PERMISSION_PROMPTS=1` in production;
    /// injectable for tests. CI's packaged-app launch smoke execs the real
    /// binary inside the Actions runner's process tree, where TCC attributes
    /// permission checks to the runner's bundled node — after a runner
    /// auto-update invalidates node's Accessibility grant, the startup
    /// prompt pops a REAL dialog on the runner's GUI session once per run
    /// (2026-07-24). The env override silences only the prompts; the launch
    /// path stays production-shaped.
    @ObservationIgnored
    /// Microphone and Accessibility permissions: the startup prompt pass and
    /// the rows' requests and refreshes. Views bind to `viewModel.permissions`.
    @ObservationIgnored
    let permissions: PermissionsCoordinator
    /// The keyboard triggers: gestures, hotkey registration, the shortcut
    /// slots. Views bind to `viewModel.shortcuts`; the session reads its
    /// gesture flags through it.
    @ObservationIgnored
    let shortcuts: ShortcutController
    typealias ShortcutAssignment = ShortcutController.ShortcutAssignment

    init(
        settings: SettingsStore,
        backendManager: (any ManagedBackendManaging)? = nil,
        overlayBufferCoordinator: OverlayBufferSessionCoordinating? = nil,
        localNetworkPermissionPreflight: (any LocalNetworkPermissionPreflighting)? = nil,
        startRuntimeServices: Bool = true,
        suppressStartupPermissionPrompts: Bool =
            DictationViewModel.startupPermissionPromptsSuppressed(),
        dependencies: Dependencies = Dependencies()
    ) {
        self.settings = settings
        self.shortcuts = ShortcutController(settings: settings)
        self.backendManager =
            backendManager
            ?? BackendManager(
                polishingModelProvider: { settings.resolvedManagedLLMPolishingModel },
                speechdCacheLimitProvider: { settings.speechdCacheLimit.megabytes },
                speechdStepCadenceProvider: { settings.speechdStepCadence.milliseconds }
            )
        self.managesRuntimeServices = startRuntimeServices
        let context = SessionContextResolver(settings: settings, textInsertion: textInsertion)
        self.permissions = PermissionsCoordinator(
            settings: settings,
            textInsertion: textInsertion,
            managesRuntimeServices: startRuntimeServices,
            suppressStartupPermissionPrompts: suppressStartupPermissionPrompts
        )
        self.engines = EnginesModel(
            settings: settings,
            backendManager: self.backendManager,
            localNetworkPermissionPreflight:
                localNetworkPermissionPreflight ?? LocalNetworkPermissionPreflight()
        )
        // The real control only in the running app: a unit suite that reached
        // it would move the volume of the Mac running the tests, and the build
        // host is the owner's own machine. `startRuntimeServices` is the gate
        // that ships; the XCTest check is a second one for the two suites that
        // do pass true, and is DEBUG-only because the symbol is.
        var ducksRealOutput = startRuntimeServices
        #if DEBUG
        ducksRealOutput = ducksRealOutput && !TerminalTargetDetector.isRunningUnderXCTest
        #endif
        let audio = SessionAudioPipeline(
            settings: settings,
            microphone: dependencies.microphone,
            ducksRealOutput: ducksRealOutput
        )
        let overlay: OverlayBufferSessionCoordinating
        if let overlayBufferCoordinator {
            overlay = overlayBufferCoordinator
        } else {
            let anchorResolver = OverlayAnchorResolver()
            overlay = OverlayBufferSessionCoordinator(
                stateMachine: OverlayBufferStateMachine(),
                renderer: DictationOverlayController(
                    metricsProvider: {
                        OverlayLayoutMetrics(
                            bodyFontSize: settings.overlayBufferFontSize,
                            visibleLines: settings.overlayBufferVisibleLines)
                    },
                    storedPlacementProvider: { settings.overlayBufferPlacement },
                    placementWriter: { settings.overlayBufferPlacement = $0 }
                ),
                anchorResolver: anchorResolver
            )
        }
        let session = DictationSessionController(
            settings: settings,
            textInsertion: textInsertion,
            engines: engines,
            backendManager: self.backendManager,
            shortcuts: shortcuts,
            context: context,
            audio: audio,
            overlayBufferCoordinator: overlay,
            dependencies: dependencies
        )
        self.session = session

        engines.interruptConnectingSession = { [weak session] in
            guard let session else { return }
            // Cancelling the startup task mid-connect without aborting would
            // leave the connecting flag latched and block every later start.
            session.cancelManagedStartupTask()
            if session.isConnectingRealtimeSession {
                session.abortConnectingSession()
                session.statusText = StatusStrings.ready
            }
        }

        // BOTH realtime clients report into the same handler. Only the latched
        // one is ever connected, so which client an event came from carries no
        // information the session path needs — and wiring both here means a
        // mode switch can never leave a client emitting into nothing.
        let realtimeEventHandler: @Sendable (RealtimeEvent, RealtimeConnectionGeneration) -> Void = {
            [weak session] event, generation in
            // Preserve callback order for back-to-back events (e.g. final transcript
            // followed by transcription finalized) by routing through main-queue FIFO.
            // The generation rides in the same call as the event, so the FIFO orders
            // the pair exactly as it orders the event alone.
            DispatchQueue.main.async { [weak session] in
                guard let session else { return }
                MainActor.assumeIsolated {
                    session.handle(event: event, from: generation)
                }
            }
        }
        session.realtimeAPIClient.setEventHandler(realtimeEventHandler)
        session.mistralRealtimeClient.setEventHandler(realtimeEventHandler)

        if startRuntimeServices {
            // A launch that died mid-session (crash, force quit) left the
            // volume down with nothing running. Put it back before anything
            // else starts.
            audio.audioDucking.restoreInterruptedDuckFromPreviousLaunch()

            audio.microphone.onConfigurationChange = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.audio.healthMonitor.handleConfigurationChange()
                }
            }

            audio.microphone.onInputDevicesChanged = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.audio.handleMicrophoneInputDevicesChanged()
                }
            }

            audio.microphone.onError = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastError = message
                }
            }
        }

        textInsertion.onAccessibilityTrustChanged = { [weak self] in
            guard let self else { return }
            self.shortcuts.retryModifierOnlyHotKeyRegistrationIfNeeded()
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

        session.networkMonitor.onChange = { [weak session] connected in
            Task { @MainActor [weak session] in
                session?.handleNetworkChange(connected: connected)
            }
        }
        if startRuntimeServices {
            session.networkMonitor.start()
        }

        shortcuts.install(session: session)
        permissions.install(session: session)
        if startRuntimeServices {
            shortcuts.registerAtLaunch()
        }

        session.escapeCancelHandler.onCancel = { [weak session] in session?.cancelDictation() }

        textInsertion.refreshAccessibilityTrustState()
        if startRuntimeServices {
            sessionStore = DictationSessionStore()
            sessionStore?.onChange = { [weak self] in self?.dictationHistoryRevision += 1 }
            applyDictationHistoryRetention()
            learnedTermStore = LearnedTermStore(
                fileURL: LearnedTermStore.defaultFileURL(),
                onChange: { [weak self] in
                    Task { @MainActor in
                        self?.learnedTermRevision += 1
                        // What keeps the sidebar badge honest between two
                        // openings of the pane; reads memory, never the disk.
                        self?.termSuggestions.refreshLearnedSuggestions()
                    }
                }
            )
            session.termSuggestionCadence = TermSuggestionCadence(
                settings: settings,
                model: { [weak self] in self?.termSuggestions },
                isDictationActive: { [weak self] in
                    guard let self else { return false }
                    return self.isDictating || self.isFinalizingStop
                        || self.isConnectingRealtimeSession
                },
                launchedAt: Date()
            )
            installMistralUsageLedger(
                MistralUsageLedger(fileURL: MistralUsageLedger.defaultFileURL()) {
                    [weak self] in
                    Task { @MainActor in self?.engines.noteUsageLedgerChanged() }
                }
            )
            refreshMicrophoneInputs()
            registerLifecycleObservers(on: dependencies.lifecycleNotificationCenter ?? .default)
            permissions.requestStartupPermissionsIfNeeded()
            importSpeakerTermsFromReplacementDictionaryIfNeeded()
            // Subscribe BEFORE the launch warmup below so the very first
            // polishd ready edge is observed and prompt-prefix-warmed.
            let promptWarmup = PolishPromptWarmupCoordinator(
                serviceProvider: { [weak self] in
                    self?.llmPolishingService ?? LLMPolishingService()
                },
                planProvider: { [weak self] in
                    guard let self else { return nil }
                    return PolishPromptWarmup.plan(
                        settings: self.settings,
                        appConfigStore: self.appConfigStore
                    )
                },
                clock: dependencies.clock
            )
            polishPromptWarmupCoordinator = promptWarmup
            promptWarmup.observe(self.backendManager.statusUpdates)
            promptWarmup.observePlanInputs()
            session.onDictationStartRequested = { [weak promptWarmup] in
                promptWarmup?.ensureWarm(reason: "dictation start")
            }
            engines.warmUpManagedBackendsAtLaunchIfNeeded()
        } else if let center = dependencies.lifecycleNotificationCenter {
            registerLifecycleObservers(on: center)
        }
    }

    /// Points both Mistral paths — the realtime socket and the polishing
    /// service — at `ledger`. Replaces `llmPolishingService`, so a test that
    /// substitutes a fake does so after this.
    func installMistralUsageLedger(_ ledger: MistralUsageLedger) {
        engines.installUsageLedger(ledger)
        session.mistralRealtimeClient.setUsageRecorder(ledger)
        llmPolishingService = LLMPolishingService(usageRecorder: ledger)
    }

    @MainActor
    deinit {
        for observer in lifecycleObservers {
            lifecycleNotificationCenter.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        audio.commitTask?.cancel()
        session.managedStartupTask?.cancel()
        session.managedStartupTaskID = nil
        engines.cancelTasks()
        audio.audioSendTask?.cancel()
        session.stopFinalizationTask?.cancel()
        session.connectTimeoutTask?.cancel()
        session.reconnectTask?.cancel()
        session.recentFailureResetTask?.cancel()
        session.finalizationWatchdogTask?.cancel()
        session.microphonePermissionTimeoutTask?.cancel()
        permissions.cancelTasks()
        session.polishAndCommitTask?.cancel()
        polishPromptWarmupCoordinator?.cancelTasks()
        textInsertion.stopAllTasks()
        session.overlayBufferCoordinator.reset()
        audio.healthMonitor.cancelTasks()
        session.escapeCancelHandler.stop()
        audio.audioDucking.restoreImmediatelyForTermination()
        if managesRuntimeServices {
            audio.stopMicrophoneIfInitialized()
            session.networkMonitor.stop()
            session.activeRealtimeClient.disconnect()
            shortcuts.unregister()
        }
    }

    // MARK: - Lifecycle Observers

    private func registerLifecycleObservers(on nc: NotificationCenter) {

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
            // `willTerminate` is posted on the main thread and a `.main`-queue
            // observer runs synchronously in it — this closure is the last
            // execution the process guarantees. Anything that must survive
            // quit happens inline HERE, before the Task below, which is
            // best-effort only (a Task spawned at terminate is not guaranteed
            // to run).
            MainActor.assumeIsolated {
                guard let self else { return }
                #if LOCALVOXTRAL_DOGFOOD
                // Last chance for a still-open post-commit watch to patch its
                // record: after this the process is gone and the dictation
                // would keep no behavior block at all.
                self.session.dogfoodEditSignalWatcher.flushForTermination()
                #endif
                // Inline, not in the Task below: a fade would not get to
                // finish and the Task is not guaranteed to run at all.
                self.audio.audioDucking.restoreImmediatelyForTermination()
                Task {
                    self.session.cancelManagedStartupTask()
                    if self.isDictating {
                        self.stopDictation(
                            reason: "app terminating", finalizeRemainingAudio: false
                        )
                    }
                    await self.backendManager.stopAll()
                }
            }
        }

        lifecycleObservers = [sleepObserver, terminateObserver]
        lifecycleNotificationCenter = nc
    }

    /// True when `LOCALVOXTRAL_SUPPRESS_STARTUP_PERMISSION_PROMPTS=1` — the
    /// explicit opt-out CI's launch smoke sets so the real packaged app can
    /// be launched without popping TCC dialogs on the runner's GUI session
    /// (see `suppressStartupPermissionPrompts`).
    nonisolated static func startupPermissionPromptsSuppressed(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        StartupPermissionSuppression.isActive(environment: environment)
    }

    /// Once per install: the spellings the user already maintains in
    /// `replacement_dictionary.toml` become their first terms. Writing the
    /// (possibly empty) result is what marks the import done, so an unreadable
    /// file leaves it for the next launch. Never at init under XCTest: the
    /// store there is still the real one, and a test must not read or seed
    /// the machine's config directory.
    private func importSpeakerTermsFromReplacementDictionaryIfNeeded() {
        #if DEBUG
        if TerminalTargetDetector.isRunningUnderXCTest { return }
        #endif
        importSpeakerTermsFromReplacementDictionary()
    }

    func importSpeakerTermsFromReplacementDictionary() {
        guard !settings.hasStoredPolishSpeakerTerms else { return }
        guard let dictionary = appConfigStore.loadReplacementDictionaryIfReadable() else {
            Log.config.error("Speaker terms import postponed: replacement dictionary unreadable")
            return
        }
        let imported = SpeakerTerms.migrated(from: dictionary)
        settings.polishSpeakerTerms = imported
        Log.config.info("Speaker terms imported from replacement dictionary: \(imported.count, privacy: .public)")
    }

    /// The production `Dependencies.pasteboardWriter`: the general pasteboard,
    /// which a test never reaches (headless CI has no pasteboard server, and
    /// clobbering the host clipboard is antisocial).
    static func writeToSystemPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Reset the first-launch flag and ask the app delegate to re-present the
    /// onboarding wizard. Invoked by the General settings pane's "Re-run setup…".
    func reRunOnboarding() {
        settings.onboardingCompleted = false
        onRequestReRunOnboarding?()
    }

    func openConfigFolder() {
        let url = appConfigStore.configDirectoryURL()
        NSWorkspace.shared.open(url)
    }

    private func isReady(_ status: ManagedBackendStatus) -> Bool {
        if case .ready = status {
            return true
        }
        return false
    }

}

#if LOCALVOXTRAL_DOGFOOD
extension DictationViewModel {
    /// The dogfood control socket's entry into the dictation trigger.
    ///
    /// Deliberately the app's OWN modifier-only tap handler, not a shortcut
    /// past it: the socket must be subject to everything a real gesture is
    /// subject to — the Secure Keyboard Entry refusal, the Accessibility state,
    /// the microphone gate, managed-backend readiness — and must report a
    /// refusal rather than override one. It mirrors
    /// the same handler the tests drive through `shortcuts`.
    func dogfoodHandleModifierOnlyTap(mode: DictationOutputMode) {
        shortcuts.handleModifierOnlyTap(mode: mode)
    }

}
#endif

