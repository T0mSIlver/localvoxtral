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
    var lastFinalSegment = ""

    /// Raw (pre-polish) transcript of the most recent stop-commit whose LLM
    /// polishing visibly changed the text. Drives the "Copy raw transcript"
    /// popover affordance (F6): terminals can't un-type, so the raw text a
    /// polish replaced is offered for one-tap copy instead. `nil` when the last
    /// commit wasn't polish-changed; cleared on every new session start.
    /// Observable (not `@ObservationIgnored`) so the popover re-renders when it
    /// appears/disappears.
    var lastPolishChangedRawTranscript: String?

    /// Whether the "Copy raw transcript" popover row should be offered.
    var canCopyRawTranscript: Bool {
        lastPolishChangedRawTranscript?.trimmed.isEmpty == false
    }

    /// Whether the app focused at the most recent session start behaves like
    /// a terminal emulator (bundle allowlist, AX-writability heuristic
    /// fallback). Refreshed at each session start; live replacement strategy
    /// and future per-app behaviors key off it. See `TerminalTargetDetector`.
    private(set) var sessionTargetIsTerminalLike = false

    private(set) var availableInputDevices: [MicrophoneInputDevice] = []
    private(set) var selectedInputDeviceID = ""


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

    /// Secure Keyboard Entry state sampled for the CURRENT session — drives
    /// the menu bar warning icon independently of `lastError` (whose popover
    /// line a higher-priority warning may own). Set when the session verdict
    /// is applied; cleared at session end alongside the token-scoped
    /// popover clear. Internal (not private(set)) because the session-end
    /// clear lives in DictationViewModel+Session.swift.
    var sessionSecureInputActive = false

    /// What this session's Claude Code join resolved to, held for the overlay's
    /// header badge.
    ///
    /// Latched here for the same reason `sessionSecureInputActive` is: the join
    /// is resolved at session start, while the app the user dictated into is
    /// still frontmost, but the overlay panel does not open until the realtime
    /// socket connects — and `startSession` clears the state machine, so a
    /// badge pushed at resolution time would be wiped by the session that is
    /// supposed to show it. Internal, because the session-end clear lives in
    /// DictationViewModel+Session.swift.
    var sessionClaudeJoinBadge: OverlayClaudeJoinBadge = .hidden

    /// Ends the refused-start warning when no session is running: the icon
    /// (and the "Blocked" status line) return to normal, while `lastError`
    /// keeps the one-line explanation in the popover. A stopped session that
    /// is still finalizing/polishing is NOT an ended attempt — its text is
    /// still headed for the clipboard fallback, and clearing here dropped
    /// the icon to the orange session state mid-polish (owner field feedback
    /// on #90); session teardown owns that clear.
    func clearSecureInputRefusalSignalsIfAttemptEnded() {
        guard !isDictating, !isConnectingRealtimeSession, !isFinalizingStop,
              sessionSecureInputActive
        else { return }
        sessionSecureInputActive = false
        if statusText == StatusStrings.liveDictationBlockedBySecureInput {
            statusText = StatusStrings.ready
        }
    }

    /// Played once at session start when Secure Keyboard Entry is detected.
    /// The popover is closed while dictating, so an audible cue is the only
    /// immediate signal that keystrokes will be swallowed (#89). Test seam.
    @ObservationIgnored
    var secureInputWarningSound: () -> Void = { NSSound(named: "Basso")?.play() }

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

        init(
            microphone: (() -> any MicrophoneCapturing)? = nil,
            pasteboardReader: @escaping @MainActor () -> any PasteboardReading = { SystemPasteboardReader() },
            pasteboardWriter: @escaping @MainActor (String) -> Void = DictationViewModel.writeToSystemPasteboard,
            bundleIdentifier: @escaping (pid_t) -> String? = {
                NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
            },
            lifecycleNotificationCenter: NotificationCenter? = nil,
            reconnectSleep: @escaping @MainActor (TimeInterval) async -> Void =
                DictationViewModel.sleepForReconnect,
            connectionFailurePresenter: any ConnectionFailurePresenting = ModalConnectionFailurePresenter(),
            onSessionRecord: ((DictationSessionRecord) -> Void)? = nil,
            repoVocabularyGrounding: (any RepoVocabularyGrounding)? = nil
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
        }
    }

    /// `var` so a test can replace one collaborator after construction; the
    /// lifecycle center is read at init and the rest when a session uses them.
    @ObservationIgnored
    var dependencies: Dependencies

    /// The production repository-vocabulary pipeline, over the app the
    /// overlay commits into. Built on first use so its closures can reach
    /// the view model.
    @ObservationIgnored
    lazy var repoVocabularyPipeline = RepoVocabularyPipeline(
        settings: settings,
        commitTargetAppPID: { [weak self] in self?.overlayBufferCoordinator.commitTargetAppPID },
        targetBundleID: { [weak self] in self?.resolveTargetAppBundleID() }
    )
    var repoVocabularyGrounding: any RepoVocabularyGrounding {
        dependencies.repoVocabularyGrounding ?? repoVocabularyPipeline
    }

    // Services — internal so extension files can access them.
    @ObservationIgnored
    private(set) var hasInitializedMicrophone = false
    @ObservationIgnored
    lazy var microphone: any MicrophoneCapturing = {
        hasInitializedMicrophone = true
        return dependencies.microphone?() ?? MicrophoneCaptureService()
    }()

    /// Ducks other audio for the length of a session. Assigned in `init` so
    /// its volume control can be the real CoreAudio one only in the app;
    /// `var` so a test can swap the whole controller.
    @ObservationIgnored
    var audioDucking: AudioDuckingController

    /// A failed/cancelled connection can end before audio capture ever starts.
    /// Do not instantiate the lazy CoreAudio service merely to stop it: doing
    /// so registers device listeners that an app-lifetime view model then owns.
    func stopMicrophoneIfInitialized() {
        #if LOCALVOXTRAL_DOGFOOD
        stopDogfoodAudioFileSource()
        #endif
        guard hasInitializedMicrophone else { return }
        microphone.stop()
    }

    /// False only in a dogfood build launched with an audio file to dictate
    /// from: that session needs no microphone grant, and nothing may fall back
    /// to the microphone behind its back.
    var capturesFromMicrophone: Bool {
        #if LOCALVOXTRAL_DOGFOOD
        return dogfoodAudioFileURL == nil
        #else
        return true
        #endif
    }

    /// Starts whatever feeds this session's audio.
    func startSessionAudioCapture(
        preferredDeviceID: String?,
        chunkHandler: @escaping MicrophoneCaptureService.ChunkHandler
    ) throws {
        #if LOCALVOXTRAL_DOGFOOD
        if let dogfoodAudioFileURL {
            try startDogfoodAudioFileSource(dogfoodAudioFileURL, chunkHandler: chunkHandler)
            return
        }
        #endif
        try microphone.start(
            preferredDeviceID: preferredDeviceID,
            preferredInputChannel: selectedInputChannel,
            chunkHandler: chunkHandler
        )
    }

    /// Once this returns no further chunk reaches the session's handler.
    func stopSessionAudioCapture() {
        #if LOCALVOXTRAL_DOGFOOD
        stopDogfoodAudioFileSource()
        guard capturesFromMicrophone else { return }
        #endif
        microphone.stop()
    }

    @ObservationIgnored
    let networkMonitor = NetworkMonitor()
    @ObservationIgnored
    let realtimeAPIClient = RealtimeAPIWebSocketClient()
    @ObservationIgnored
    let mistralRealtimeClient = MistralRealtimeWebSocketClient()
    /// The client THIS session speaks to, latched at session start from
    /// `settings.dictationBackendMode` (`latchActiveRealtimeClient`). A stored
    /// latch rather than a lookup on every call: flipping the mode in Settings
    /// mid-dictation must not leave the running session sending audio to one
    /// client and its stop to another. While idle the latch simply decides
    /// nothing until the next start.
    @ObservationIgnored
    lazy var activeRealtimeClient: any RealtimeClient = realtimeAPIClient
    @ObservationIgnored
    let audioChunkBuffer = AudioChunkBuffer()
    @ObservationIgnored
    let healthMonitor = AudioCaptureHealthMonitor()
    @ObservationIgnored
    var llmPolishingService: any LLMPolishingServicing = LLMPolishingService()
    @ObservationIgnored
    var appConfigStore: any AppConfigServing = AppConfigStore()
    #if LOCALVOXTRAL_DOGFOOD
    /// `var` for the same reason `llmPolishingService` is: tests point it at a
    /// temp directory. Production uses the Application Support default.
    @ObservationIgnored
    var dogfoodCaptureStore = DogfoodCaptureStore()
    /// Watches the seconds after a commit for an immediate erase, and patches
    /// that dictation's record with what it saw. `var` for the same reason as
    /// the store: tests inject the clock and the event source.
    @ObservationIgnored
    var dogfoodEditSignalWatcher = DogfoodEditSignalWatcher()
    /// The WAV this launch dictates from in place of the microphone, or nil.
    /// `var` so tests name a file without touching the process environment.
    @ObservationIgnored
    var dogfoodAudioFileURL = DogfoodAudioFileSource.fileURL(
        fromEnvironment: ProcessInfo.processInfo.environment)
    @ObservationIgnored
    var dogfoodAudioFileSleep: DogfoodAudioFileSource.Sleep = { try await Task.sleep(for: $0) }
    @ObservationIgnored
    var dogfoodAudioFileSource: DogfoodAudioFileSource?
    #endif
    /// Warms the managed polishing helper's prompt-prefix cache on every
    /// helper launch (see `PolishPromptWarmupCoordinator`). Created only when
    /// runtime services run — trigger logic is unit-tested on the coordinator
    /// directly.
    @ObservationIgnored
    private(set) var polishPromptWarmupCoordinator: PolishPromptWarmupCoordinator?
    @ObservationIgnored
    let backendManager: any ManagedBackendManaging
    @ObservationIgnored
    var sessionStore: DictationSessionStore?
    /// The spellings this machine has watched the polish pipeline resolve,
    /// per project. Nil without runtime services (tests), so a unit test never
    /// writes the user's file.
    @ObservationIgnored
    var learnedTermStore: LearnedTermStore?
    /// Bumped on every learned-terms write so the Settings row re-reads it.
    private(set) var learnedTermRevision = 0
    @ObservationIgnored
    private var storedTermSuggestions: SpeakerTermSuggestionModel?
    /// Built on first use (Settings opening the About-you group); reads the
    /// store and the service at call time, so a test's replacements are seen.
    var termSuggestions: SpeakerTermSuggestionModel {
        if let storedTermSuggestions { return storedTermSuggestions }
        let model = SpeakerTermSuggestionModel(
            settings: settings,
            recentTexts: { [weak self] in
                await self?.sessionStore?.recentFinalTexts(
                    limit: SpeakerTermSuggestions.maxDictations
                ) ?? []
            },
            learnedTerms: { [weak self] in
                self?.learnedTermStore?.snapshot().confirmedEverywhere().map(\.term) ?? []
            },
            service: { [weak self] in self?.llmPolishingService ?? LLMPolishingService() },
            unavailableReason: { [weak self] in
                guard let settings = self?.settings else { return nil }
                if settings.polishingBackendMode == .managedLocal {
                    return "Needs a hosted polishing model."
                }
                // The pass reads saved dictations and nothing else.
                if !settings.dictationHistoryRetention.savesDictations {
                    return "Needs dictation history."
                }
                return nil
            }
        )
        model.onRunFinished = { [weak self] outcome, countAtStart in
            self?.termSuggestionCadence?.runFinished(outcome, countAtStart: countAtStart)
        }
        storedTermSuggestions = model
        return model
    }
    /// Nil without runtime services, so no unit test's saved dictation can
    /// start a request.
    @ObservationIgnored
    var termSuggestionCadence: TermSuggestionCadence?
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

    // Mutable state — internal so extension files can access.
    @ObservationIgnored
    var commitTask: Task<Void, Never>?
    @ObservationIgnored
    var managedStartupTask: Task<Void, Never>?
    @ObservationIgnored
    var managedStartupTaskID: UUID?
    @ObservationIgnored
    var audioSendTask: Task<Void, Never>?
    @ObservationIgnored
    var stopFinalizationTask: Task<Void, Never>?
    @ObservationIgnored
    var connectTimeoutTask: Task<Void, Never>?
    @ObservationIgnored
    var isResolvingConnectTimeout = false
    /// The connect snapshot THIS session opened with. A mid-session reconnect
    /// (#380) replays exactly this: re-reading Settings would let a backend
    /// mode flipped mid-dictation send the running session's audio — and its
    /// bearer token — to a different server than the one it started on.
    /// Cleared with the rest of the latched session metadata.
    @ObservationIgnored
    var sessionRealtimeConfiguration: RealtimeSessionConfiguration?
    /// The socket this session is on (#417). Set from the client right after
    /// every successful `connect`, and cleared the moment that socket reports
    /// itself gone — between a drop and the next dial the session is on no
    /// connection at all. Every realtime event names the socket that raised it;
    /// one naming any other generation is a retired socket still talking, and
    /// `handle(event:from:)` refuses it.
    @ObservationIgnored
    var sessionConnectionGeneration: RealtimeConnectionGeneration = .none
    @ObservationIgnored
    var reconnectTask: Task<Void, Never>?
    /// True from an unexpected drop until the reconnect run behind it either
    /// reconnects or exhausts its attempts. While set, the run owns the status
    /// line and the outcome of every realtime event the dying socket emits.
    @ObservationIgnored
    var isReconnectingRealtimeSession = false
    /// Bumped by every start and every cancel. A run compares it against the
    /// value it was launched with, so a stop, a cancel or a newer session can
    /// never be undone by an attempt that was already in flight.
    @ObservationIgnored
    var reconnectRunID = 0
    /// Set when the socket a reconnect attempt just opened reports back a
    /// failure, so the attempt gives up without waiting out its timeout.
    @ObservationIgnored
    var reconnectAttemptDidFail = false
    @ObservationIgnored
    var recentFailureResetTask: Task<Void, Never>?
    /// Set when a stop is itself a failure: the stop's finalization would
    /// otherwise turn the red icon back to idle as soon as it completes.
    @ObservationIgnored
    var holdFailureIndicatorUntilStopCompletes = false
    @ObservationIgnored
    var finalizationWatchdogTask: Task<Void, Never>?
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
    /// Test seam: invoked after the managed-startup status mirror finishes
    /// handling each status update (including updates its guard skips), so
    /// tests can await mirror processing deterministically instead of
    /// guessing with `Task.yield()`.
    @ObservationIgnored
    var debugManagedStatusMirrorEventSink: (() -> Void)?
    #if DEBUG
    /// Test seam: awaited by `beginDictationSession` after its capture awaits
    /// and immediately before the socket opens — the one window in which a
    /// real session can observe Settings changing under it.
    @ObservationIgnored
    var debugBeforeConnectHookForTesting: (@MainActor () async -> Void)?
    #endif
    @ObservationIgnored
    let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

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
    /// What a dictation carries from start to commit: the screen capture, the
    /// Claude join, the pane sample and the remote forward leases.
    @ObservationIgnored
    let context: SessionContextResolver
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
        self.dependencies = dependencies
        self.shortcuts = ShortcutController(settings: settings)
        self.backendManager =
            backendManager
            ?? BackendManager(
                polishingModelProvider: { settings.resolvedManagedLLMPolishingModel },
                speechdCacheLimitProvider: { settings.speechdCacheLimit.megabytes },
                speechdStepCadenceProvider: { settings.speechdStepCadence.milliseconds }
            )
        self.managesRuntimeServices = startRuntimeServices
        self.context = SessionContextResolver(settings: settings, textInsertion: textInsertion)
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
        self.audioDucking = AudioDuckingController(
            volumeControl: ducksRealOutput
                ? CoreAudioSystemOutputVolumeControl()
                : UnavailableSystemOutputVolumeControl(),
            isEnabled: { settings.audioDuckingEnabled },
            fadeDuration: { settings.audioDuckingFadeDuration },
            interruptedDuck: { settings.audioDuckingPendingRestore },
            recordInterruptedDuck: { settings.audioDuckingPendingRestore = $0 }
        )
        if let overlayBufferCoordinator {
            self.overlayBufferCoordinator = overlayBufferCoordinator
        } else {
            let anchorResolver = OverlayAnchorResolver()
            self.overlayBufferCoordinator = OverlayBufferSessionCoordinator(
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

        engines.interruptConnectingSession = { [weak self] in
            guard let self else { return }
            // Cancelling the startup task mid-connect without aborting would
            // leave the connecting flag latched and block every later start.
            self.cancelManagedStartupTask()
            if self.isConnectingRealtimeSession {
                self.abortConnectingSession()
                self.statusText = StatusStrings.ready
            }
        }

        // BOTH realtime clients report into the same handler. Only the latched
        // one is ever connected, so which client an event came from carries no
        // information the session path needs — and wiring both here means a
        // mode switch can never leave a client emitting into nothing.
        let realtimeEventHandler: @Sendable (RealtimeEvent, RealtimeConnectionGeneration) -> Void = {
            [weak self] event, generation in
            // Preserve callback order for back-to-back events (e.g. final transcript
            // followed by transcription finalized) by routing through main-queue FIFO.
            // The generation rides in the same call as the event, so the FIFO orders
            // the pair exactly as it orders the event alone.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.handle(event: event, from: generation)
                }
            }
        }
        realtimeAPIClient.setEventHandler(realtimeEventHandler)
        mistralRealtimeClient.setEventHandler(realtimeEventHandler)

        if startRuntimeServices {
            // A launch that died mid-session (crash, force quit) left the
            // volume down with nothing running. Put it back before anything
            // else starts.
            audioDucking.restoreInterruptedDuckFromPreviousLaunch()

            microphone.onConfigurationChange = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.healthMonitor.handleConfigurationChange()
                }
            }

            microphone.onInputDevicesChanged = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleMicrophoneInputDevicesChanged()
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

        networkMonitor.onChange = { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.handleNetworkChange(connected: connected)
            }
        }
        if startRuntimeServices {
            networkMonitor.start()
        }

        shortcuts.install(session: self)
        permissions.install(session: self)
        if startRuntimeServices {
            shortcuts.registerAtLaunch()
        }

        escapeCancelHandler.onCancel = { [weak self] in self?.cancelDictation() }

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
            termSuggestionCadence = TermSuggestionCadence(
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
                }
            )
            polishPromptWarmupCoordinator = promptWarmup
            promptWarmup.observe(self.backendManager.statusUpdates)
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
        mistralRealtimeClient.setUsageRecorder(ledger)
        llmPolishingService = LLMPolishingService(usageRecorder: ledger)
    }

    @MainActor
    deinit {
        for observer in lifecycleObservers {
            lifecycleNotificationCenter.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        commitTask?.cancel()
        managedStartupTask?.cancel()
        managedStartupTaskID = nil
        engines.cancelTasks()
        audioSendTask?.cancel()
        stopFinalizationTask?.cancel()
        connectTimeoutTask?.cancel()
        reconnectTask?.cancel()
        recentFailureResetTask?.cancel()
        finalizationWatchdogTask?.cancel()
        permissions.cancelTasks()
        polishAndCommitTask?.cancel()
        polishPromptWarmupCoordinator?.cancelTasks()
        textInsertion.stopAllTasks()
        overlayBufferCoordinator.reset()
        healthMonitor.cancelTasks()
        escapeCancelHandler.stop()
        audioDucking.restoreImmediatelyForTermination()
        if managesRuntimeServices {
            stopMicrophoneIfInitialized()
            networkMonitor.stop()
            activeRealtimeClient.disconnect()
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
                self.dogfoodEditSignalWatcher.flushForTermination()
                #endif
                // Inline, not in the Task below: a fade would not get to
                // finish and the Task is not guaranteed to run at all.
                self.audioDucking.restoreImmediatelyForTermination()
                Task {
                    self.cancelManagedStartupTask()
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

    func prepareLLMPolishingPromptAccessIfNeeded() {
        guard settings.llmPolishingEnabled else { return }

        debugLog("preloading LLM polishing prompt/config files")
        _ = appConfigStore.loadLLMPromptTemplates()
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
                activeRealtimeClient.disconnect()
                finishStoppedSession(promotePendingSegment: true)
                statusText = StatusStrings.networkLostDictationStopped
                lastError = "Network connection was lost during dictation."
            } else {
                statusText = StatusStrings.noNetworkConnection
            }
        }
    }

    // MARK: - Public API

    func toggleDictation(outputMode: DictationOutputMode? = nil) {
        shortcuts.clearPushToTalkShortcutSessionAttempt()
        defer {
            // Toggle starts (modifier tap, popover button) have no release
            // event, so a refused live start would latch the warning icon
            // forever (Codex findings on #90, rounds 5-6). The tap/click IS
            // the whole attempt gesture: if nothing started, end the refusal
            // signals now — the sound already fired and the popover line
            // keeps the explanation.
            if !isDictating, !isConnectingRealtimeSession, !isAwaitingMicrophonePermission {
                clearSecureInputRefusalSignalsIfAttemptEnded()
            }
        }
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
        // A cancelled session never reaches the commit path that consumes the
        // capture, so without this the user's screen text would sit in memory
        // until the next session start — text from a session they explicitly
        // threw away.
        context.discardTerminalScreenCapture()
        cancelManagedStartupTask()
        if isDictating {
            stopDictation(reason: "cancelled", finalizeRemainingAudio: false)
        } else if isConnectingRealtimeSession {
            abortConnectingSession()
            statusText = StatusStrings.ready
        } else if isFinalizingStop {
            activeRealtimeClient.disconnect()
            finishStoppedSession(promotePendingSegment: false)
        }
    }

    // MARK: - Mistral API

    /// The realtime client a session in `mode` speaks to.
    func realtimeClient(for mode: BackendMode) -> any RealtimeClient {
        mode == .mistralAPI ? mistralRealtimeClient : realtimeAPIClient
    }

    /// Point `activeRealtimeClient` at the mode the session ABOUT to start was
    /// configured with. Called once per session start, before anything connects.
    func latchActiveRealtimeClient() {
        let latched = realtimeClient(for: settings.dictationBackendMode)
        guard latched !== activeRealtimeClient else { return }
        // The mode changed since the last session: make sure the client we are
        // leaving behind is not left holding a socket nobody will ever stop.
        activeRealtimeClient.disconnect()
        activeRealtimeClient = latched
        Log.backends.info(
            "realtime client latched for mode=\(self.settings.dictationBackendMode.rawValue, privacy: .public)"
        )
    }

    /// CoreAudio reported a device plugged in, unplugged, or a new system
    /// default input.
    /// While a capture runs the health monitor owns the refresh: it compares
    /// the selection before and after to catch the live mic disappearing.
    /// Otherwise nobody is listening, so refresh here — without this a mic
    /// plugged in after launch stayed out of the menu until relaunch.
    func handleMicrophoneInputDevicesChanged() {
        if healthMonitor.isMonitoring {
            healthMonitor.handleInputDevicesChanged()
        } else {
            refreshMicrophoneInputs()
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
        // A saved mic that is only unplugged stays saved, so plugging it back
        // in selects it again. Only a first run with nothing saved records
        // the fallback.
        if savedSelection.isEmpty {
            settings.selectedInputDeviceUID = resolvedSelection
        }
    }

    func selectMicrophoneInput(id: String) {
        guard !id.isEmpty else { return }
        // Save even when `id` is already selected: it may be the fallback
        // standing in for an unplugged saved mic, and clicking it means
        // "use this one from now on".
        if settings.selectedInputDeviceUID != id {
            settings.selectedInputDeviceUID = id
        }
        guard selectedInputDeviceID != id else { return }

        selectedInputDeviceID = id

        guard isDictating else { return }
        stopDictation(reason: "input device changed by user", finalizeRemainingAudio: false)
        startDictation()
    }

    /// Channels the selected input device reports. Above 2 the capture path
    /// picks ONE channel (there is no meaningful downmix), so the popover
    /// offers the choice; at or below 2 the picker stays hidden.
    var selectedInputDeviceChannelCount: UInt32 {
        availableInputDevices.first { $0.id == selectedInputDeviceID }?.channelCount ?? 1
    }

    var selectedInputChannel: Int {
        MicrophoneCaptureService.resolvedCaptureChannel(
            settings.selectedInputChannel,
            channelCount: AVAudioChannelCount(selectedInputDeviceChannelCount))
    }

    func selectMicrophoneInputChannel(_ channel: Int) {
        guard channel >= 0, channel < Int(selectedInputDeviceChannelCount) else { return }
        guard settings.selectedInputChannel != channel else { return }

        settings.selectedInputChannel = channel

        guard isDictating else { return }
        stopDictation(reason: "input channel changed by user", finalizeRemainingAudio: false)
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
        // Refused BEFORE the microphone-authorization gate: a doomed live
        // session must not trigger a mic permission prompt — and the mic
        // gate's per-user TCC state must not decide whether the refusal
        // fires at all (it did: the refusal lived only past this gate, and
        // CI vs build-host permission differences flipped the behavior).
        if refuseLiveStartForSecureInputIfNeeded(
            outputMode: outputMode ?? settings.dictationOutputMode
        ) {
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
            requestMicrophoneAccessForSessionStart { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isAwaitingMicrophonePermission = false
                    self.debugLog("microphone permission result granted=\(granted)")
                    guard granted else {
                        self.statusText = StatusStrings.microphoneAccessDenied
                        self.lastError = Self.microphoneDeniedMessage
                        self.shortcuts.clearPushToTalkShortcutSessionAttempt()
                        return
                    }
                    if self.shortcuts.shouldCancelPushToTalkStartAfterConnect() {
                        self.statusText = StatusStrings.ready
                        self.shortcuts.clearPushToTalkShortcutSessionAttempt()
                        return
                    }
                    self.beginDictationAfterManagedBackendIfNeeded(outputMode: outputMode)
                    // The grant may land long after the initiating tap ended
                    // (toggle taps have no release event). If secure input
                    // turned on while the dialog was up, the entry point
                    // above just refused — with no gesture-end event left,
                    // the signals would wedge (Codex finding, round 9; same
                    // shape as the managed-startup wedge in round 8).
                    if !self.shortcuts.isDictationAttemptGestureActive {
                        self.clearSecureInputRefusalSignalsIfAttemptEnded()
                    }
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard let self, self.isAwaitingMicrophonePermission else { return }
                self.isAwaitingMicrophonePermission = false
                self.statusText = StatusStrings.ready
                if self.shortcuts.shouldCancelPushToTalkStartAfterConnect() {
                    self.shortcuts.clearPushToTalkShortcutSessionAttempt()
                }
                self.debugLog("microphone permission prompt timed out")
            }
        case .denied, .restricted:
            statusText = StatusStrings.microphoneAccessDenied
            lastError = Self.microphoneDeniedMessage
            debugLog("microphone access denied or restricted")
        }
    }

    private func requestMicrophoneAccessForSessionStart(
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        microphone.requestAccess(completion: completion)
    }

    func currentMicrophoneAuthorizationStatus() -> MicrophoneAuthorizationStatus {
        guard capturesFromMicrophone else { return .authorized }
        // A mere status read (the onboarding/General permission rows) must
        // not force the lazy CoreAudio service into existence; once the
        // service exists, or when one was injected, ask it, so the injected
        // replacement stays authoritative.
        guard hasInitializedMicrophone || dependencies.microphone != nil else {
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
        shortcuts.clearPushToTalkShortcutSessionAttempt()

        // Before anything else: a reconnect run still in flight must not be
        // allowed to hand this session a socket after the user stopped it.
        cancelRealtimeReconnect()
        polishAndCommitTask?.cancel()
        polishAndCommitTask = nil
        commitTask?.cancel()
        commitTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        healthMonitor.stop()
        isAwaitingMicrophonePermission = false

        stopSessionAudioCapture()
        audioDucking.restoreAfterSession()
        flushBufferedAudio()
        isDictating = false
        escapeCancelHandler.stop()

        guard finalizeRemainingAudio else {
            activeRealtimeClient.disconnect()
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

        writeToPasteboard(segment)

        if updateStatus {
            statusText = "Latest segment copied."
        }
    }

    /// Copies the RAW (pre-polish) transcript of the last polish-changed commit
    /// to the clipboard (F6). No-op when there is nothing to offer.
    func copyRawTranscript() {
        guard let raw = lastPolishChangedRawTranscript?.trimmed, !raw.isEmpty else { return }
        writeToPasteboard(raw)
        statusText = "Raw transcript copied."
    }

    private func writeToPasteboard(_ text: String) {
        dependencies.pasteboardWriter(text)
    }

    /// The production `Dependencies.pasteboardWriter`: the general pasteboard,
    /// which a test never reaches (headless CI has no pasteboard server, and
    /// clobbering the host clipboard is antisocial).
    static func writeToSystemPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
        let userBundleIDs = settings.userTerminalAppBundleIDs
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

}

#if DEBUG
extension DictationViewModel {
    /// Install a sink that receives every raw-delta log emission captured by
    /// `logRawRealtimeEventIfEnabled`. Only fires when
    /// `SettingsStore.debugLogRealtimeDeltas` is on (same gated path as
    /// `Log.deltas`), so it doubles as an observation point for "logging path
    /// not entered when disabled". Pass `nil` to clear.
    func debugConfigureDeltaLogSink(_ sink: ((DebugRealtimeDeltaLogRecord) -> Void)?) {
        debugDeltaLogSink = sink
    }

}
#endif

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

extension DictationViewModel: ShortcutSessionControlling {
    func endDictation(reason: String) {
        stopDictation(reason: reason)
    }

    func overlayReachabilityDidChange(wasReachable: Bool) {
        engines.handleOverlayReachabilityTransition(wasReachable: wasReachable)
    }
}

extension DictationViewModel: PermissionSessionControlling {}

extension DictationViewModel {
    /// Start-of-session capture, through the resolver; the badge it returns
    /// describes the one resolved join, so the overlay cannot disagree with
    /// the context that ships.
    func captureTerminalScreenContextForSession() async {
        #if LOCALVOXTRAL_DOGFOOD
        // The previous dictation's post-commit edit watch closes here rather
        // than reading this session's keys. It still flushes its own record,
        // as `superseded`.
        dogfoodEditSignalWatcher.supersede()
        #endif
        sessionClaudeJoinBadge = await context.captureAtStart()
    }
}
