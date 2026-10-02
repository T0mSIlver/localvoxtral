import AppKit
import ClaudeContextWire
import Foundation
import Observation
import os

/// One dictation, from the start request to the commit: the managed-backend
/// wait, the connect and its timeout, audio capture, the realtime events and
/// the transcript they build, the reconnect run, the stop's finalization, and
/// the stop-commit that drives `StopCommitCoordinator`.
///
/// `DictationViewModel` builds it from the collaborators it shares with the
/// rest of the app and is the facade the views bind to: it forwards the
/// session state they read. `ShortcutController` and `PermissionsCoordinator`
/// talk to this type directly.
///
/// The view model's deinit tears the session down; this type has none. Keep
/// every task and closure it starts `[weak self]`, or one could outlive that
/// teardown.
@MainActor
@Observable
final class DictationSessionController {
    typealias StatusStrings = DictationViewModel.StatusStrings
    typealias StatusToken = DictationViewModel.StatusToken
    typealias ErrorToken = DictationViewModel.ErrorToken
    typealias Dependencies = DictationViewModel.Dependencies

    static var connectionLostMessage: String { DictationViewModel.connectionLostMessage }
    static var microphoneDisconnectedMessage: String { DictationViewModel.microphoneDisconnectedMessage }
    static var microphoneDeniedMessage: String { DictationViewModel.microphoneDeniedMessage }
    static var liveAutoPasteAccessibilityWarningMessage: String {
        DictationViewModel.liveAutoPasteAccessibilityWarningMessage
    }
    static var secureKeyboardEntryWarningMessage: String {
        DictationViewModel.secureKeyboardEntryWarningMessage
    }

    var isDictating = false
    var isFinalizingStop = false
    var isConnectingRealtimeSession = false
    var realtimeSessionIndicatorState: RealtimeSessionIndicatorState = .idle
    /// The text the realtime events built: the partial in flight, the
    /// dictation event the overlay commits, the latest segment and the
    /// running transcript.
    var transcript = TranscriptAccumulator()
    var statusText = StatusStrings.ready
    var lastError: String?
    // Raw message from the most recent websocket .error event this session.
    // Kept separate from lastError, which holds user-facing UI state (e.g. the
    // Accessibility warning) that must never leak into connection-failure details.
    var lastSocketErrorMessage: String?
    /// What the popover's copy and paste rows read. Reading it registers on
    /// the whole `transcript`, so a view that reads it re-renders on every
    /// partial; the popover already does, through `statusText`.
    var lastFinalSegment: String { transcript.lastFinalSegment }

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

    /// The last dictation the stop-commit saved, kept whether or not History
    /// keeps it: after a failed insertion it is the text the user still needs
    /// (#526). Seeded from History at launch, and it follows History when a
    /// dictation there is deleted.
    private(set) var lastDictation: DictationHistoryEntry? {
        didSet { lastDictationGeneration &+= 1 }
    }
    /// The session the last saved dictation joined, for `localvoxtral
    /// status` (#721). Nil when it joined none.
    @ObservationIgnored var lastDictationJoin: AgentCLIJoin?
    /// Whether `lastDictation` is also in History. Only then does an empty
    /// History mean it was deleted.
    @ObservationIgnored private var lastDictationIsInHistory = false
    /// A store read that started before the last change to `lastDictation`
    /// answers for an older History and must not overwrite it.
    @ObservationIgnored private var lastDictationGeneration = 0

    /// Whether "Copy last dictation" has something to copy.
    var canCopyLastDictation: Bool { lastDictation?.textToCopy != nil }

    /// Whether the app focused at the most recent session start behaves like
    /// a terminal emulator (bundle allowlist, AX-writability heuristic
    /// fallback). Refreshed at each session start; live replacement strategy
    /// and future per-app behaviors key off it. See `TerminalTargetDetector`.
    private(set) var sessionTargetIsTerminalLike = false

    var availableInputDevices: [MicrophoneInputDevice] { audio.availableInputDevices }
    var selectedInputDeviceID: String { audio.selectedInputDeviceID }

    var isAccessibilityTrusted: Bool { textInsertion.isAccessibilityTrusted }
    var currentStatusToken: StatusToken { StatusToken.from(statusText) }
    var currentErrorToken: ErrorToken? {
        guard let lastError else { return nil }
        return ErrorToken.from(lastError)
    }

    let settings: SettingsStore
    let textInsertion: TextInsertionService
    /// The Engines pane's model; a start waits on the managed backends.
    @ObservationIgnored
    let engines: EnginesModel
    @ObservationIgnored
    let backendManager: any ManagedBackendManaging
    /// The keyboard triggers, whose gesture state a start and a stop consult.
    @ObservationIgnored
    let shortcuts: ShortcutController

    /// Secure Keyboard Entry state sampled for the CURRENT session — drives
    /// the menu bar warning icon independently of `lastError` (whose popover
    /// line a higher-priority warning may own). Set when the session verdict
    /// is applied; cleared at session end alongside the token-scoped
    /// popover clear. Internal (not private(set)) because the session-end
    /// clear lives in DictationSessionController+Session.swift.
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
    /// DictationSessionController+Session.swift.
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

    /// Runs on every dictation start request, before any gate can refuse it.
    /// The view model points it at the prompt-cache warmup, which must see
    /// the start while the speaker is still talking.
    @ObservationIgnored
    var onDictationStartRequested: (() -> Void)?

    /// The joined session the prompt relay armed at connect writes into;
    /// nil without a join. The join itself is consumed before a polished
    /// commit, and the relay's answer comes after it.
    @ObservationIgnored
    var promptRelaySessionID: String?

    /// `var` so a test can replace one collaborator after construction. The
    /// lifecycle center and the microphone are read at init (the microphone
    /// into the audio pipeline, so replace it through `init`); the rest when a
    /// session uses them.
    @ObservationIgnored
    var dependencies: Dependencies

    /// The production repository-vocabulary pipeline, over the app the
    /// overlay commits into. Built on first use so its closures can reach
    /// the view model.
    @ObservationIgnored
    lazy var repoVocabularyPipeline = RepoVocabularyPipeline(
        settings: settings,
        commitTargetAppPID: { [weak self] in self?.overlayBufferCoordinator.commitTargetAppPID },
        targetBundleID: { [weak self] in self?.resolveTargetAppBundleID() },
        clock: { [weak self] in self?.dependencies.clock ?? .live }
    )
    var repoVocabularyGrounding: any RepoVocabularyGrounding {
        dependencies.repoVocabularyGrounding ?? repoVocabularyPipeline
    }

    /// The session's audio: capture, the send and commit loops, ducking and
    /// the input device selection.
    @ObservationIgnored
    let audio: SessionAudioPipeline
    /// Read by the permission rows; the pipeline owns it.
    var microphone: any MicrophoneCapturing { audio.microphone }
    var capturesFromMicrophone: Bool { audio.capturesFromMicrophone }

    @ObservationIgnored
    let networkMonitor = NetworkMonitor()
    /// Reads the rollover's pause and sleeps its watchdog (#1139), its
    /// handshake fallback and its keepalive ping (#1366) on the session clock.
    @ObservationIgnored
    let realtimeAPIClient: RealtimeAPIWebSocketClient
    /// Sleeps its keepalive ping on the session clock (#1366).
    @ObservationIgnored
    let mistralRealtimeClient: MistralRealtimeWebSocketClient
    /// The client THIS session speaks to, latched at session start from
    /// `settings.dictationBackendMode` (`latchActiveRealtimeClient`). A stored
    /// latch rather than a lookup on every call: flipping the mode in Settings
    /// mid-dictation must not leave the running session sending audio to one
    /// client and its stop to another. While idle the latch simply decides
    /// nothing until the next start.
    @ObservationIgnored
    lazy var activeRealtimeClient: any RealtimeClient = realtimeAPIClient
    @ObservationIgnored
    var llmPolishingService: any LLMPolishingServicing = LLMPolishingService()
    @ObservationIgnored
    var appConfigStore: any AppConfigServing = AppConfigStore()
    /// Where diagnostic records go. Nil without runtime services (tests), so
    /// a unit test never writes the user's folder; the tests that want one
    /// point it at a temp directory.
    @ObservationIgnored
    var diagnosticRecordStore: DiagnosticRecordStore?
    /// Watches the seconds after a commit for an immediate erase, and patches
    /// that dictation's record with what it saw. `var` for the same reason as
    /// the store: tests inject the clock and the event source.
    @ObservationIgnored
    var editSignalWatcher = EditSignalWatcher()

    @ObservationIgnored
    var sessionStore: DictationSessionStore?
    /// The spellings this machine has watched the polish pipeline resolve,
    /// per project. Nil without runtime services (tests), so a unit test never
    /// writes the user's file.
    @ObservationIgnored
    var learnedTermStore: LearnedTermStore?
    /// Learns a spelling from the fix the user makes before sending a
    /// dictation to the joined session. Nil without runtime services.
    /// The skill names every polish carries (#1024). Nil without runtime
    /// services, so a unit test never reads the user's folders.
    @ObservationIgnored
    var agentSkillStore: AgentSkillStore?
    /// Lists the repositories this Mac's coding agents worked in (#1027).
    /// Nil without runtime services, like `agentSkillStore`.
    @ObservationIgnored
    var agentProjectScanner: AgentProjectActivityScanner?
    @ObservationIgnored
    var correctionLearning: CorrectionLearning?
    /// Where the last Overlay Buffer commit landed while its prompt may
    /// still be unsent; the next commit there starts with a space (#802).
    @ObservationIgnored
    var lastOverlayCommitLanding: OverlayCommitLanding?
    /// Asks a new project's coding agent for its terms after the first
    /// joined dictation there (#609). Nil without runtime services; tests
    /// inject one over a fake runner.
    @ObservationIgnored
    var projectTermProposer: ProjectTermProposer?
    /// The last dictation's proposal task, nil when it asked nothing. Only
    /// tests await it; the commit never does.
    @ObservationIgnored
    var projectTermProposalTask: Task<Void, Never>?

    @ObservationIgnored
    private var storedTermSuggestions: SpeakerTermSuggestionModel?
    /// Built on first use (Settings opening the About-you group); reads the
    /// store and the service at call time, so a test's replacements are seen.
    var termSuggestions: SpeakerTermSuggestionModel {
        if let storedTermSuggestions { return storedTermSuggestions }
        let model = SpeakerTermSuggestionModel(
            settings: settings,
            recentDictations: { [weak self] in
                await self?.sessionStore?.recentEntries(
                    limit: SpeakerTermSuggestions.maxDictations
                ).map { TermSuggestionScreen.Dictation(raw: $0.rawText, final: $0.finalText) } ?? []
            },
            learnedTerms: { [weak self] in
                self?.learnedTermStore?.snapshot().confirmedEverywhere().map(\.term) ?? []
            },
            sentNames: { [weak self] in
                guard let self else { return [] }
                return self.polishProjectNames() + self.polishSkillNames()
            },
            currentProjectTerms: { [weak self] in
                guard let memory = self?.learnedTermStore?.snapshot() else { return [] }
                return PolishProjectNames.currentProjectTerms(from: memory, now: Date())
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
    /// `prepareDictationSession` BEFORE the socket opens — same reason as
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

    // Mutable state — internal so extension files can access.
    @ObservationIgnored
    var managedStartupTask: Task<Void, Never>?
    @ObservationIgnored
    var managedStartupTaskID: UUID?
    /// Counts session starts that reached `prepareDictationSession`. A start
    /// still capturing context when this moves on has been replaced, even
    /// once the replacement's startup task has cleared `managedStartupTaskID`.
    @ObservationIgnored
    var sessionStartGeneration: UInt64 = 0
    @ObservationIgnored
    var stopFinalizationTask: Task<Void, Never>?
    @ObservationIgnored
    var connectTimeoutTask: Task<Void, Never>?
    /// Stops an Overlay Buffer tap session that has gone quiet
    /// (`DictationSessionController+SilenceAutoStop.swift`).
    @ObservationIgnored
    var silenceAutoStopTask: Task<Void, Never>?
    @ObservationIgnored
    var lastTranscriptTextAt: Date?
    /// This session's silence threshold, kept across a reconnect so the
    /// watch can resume without re-reading Settings. Nil: no watch.
    @ObservationIgnored
    var silenceAutoStopThreshold: TimeInterval?
    /// Stops an Overlay Buffer dictation that ended in a send phrase
    /// (`DictationSessionController+SpokenStop.swift`), and the words it
    /// was armed on.
    @ObservationIgnored
    var spokenStopTask: Task<Void, Never>?
    @ObservationIgnored
    var spokenStopArmedWords: [Substring]?
    /// This session was stopped by its send phrase: a quick capture then
    /// saves without it.
    @ObservationIgnored
    var sessionStoppedBySpokenPhrase = false
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
    /// Bumped at every session's connect, so a context-limit lookup that
    /// answers late cannot set its budget on a later session (#1139).
    @ObservationIgnored
    var realtimeContextLimitLookupID = 0
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
    /// True while a voice memo streams through the bundled helper this
    /// dictation also uses.
    @ObservationIgnored
    var voiceMemoHoldsTheEngine: @MainActor () -> Bool = { false }
    /// When this session started, on the session clock, if a voice memo was
    /// streaming then. The bundled helper runs one inference queue, so this
    /// session's audio is decoded only after the memo's, and its final can
    /// come long after the stop.
    @ObservationIgnored
    var sessionStartedBehindVoiceMemoAt: Date?
    @ObservationIgnored
    var isAwaitingMicrophonePermission = false
    /// Gives up on a microphone prompt nobody answers.
    @ObservationIgnored
    var microphonePermissionTimeoutTask: Task<Void, Never>?
    /// The start attempt the open microphone prompt belongs to. The timeout
    /// clears it, so an answer that lands later starts nothing.
    @ObservationIgnored
    var microphonePermissionAttemptID: UUID?
    @ObservationIgnored
    var sessionOutputMode: DictationOutputMode?
    /// Resolves "go to <name>" (#723). Nil until the app installs it, and
    /// then an Overlay Buffer dictation is never a command.
    @ObservationIgnored
    var sessionNavigator: SessionNavigator?
    /// The needs-you queue (#717). Nil until the app installs it. Observed:
    /// the menu bar icon and the popover read its queue.
    var agentAttention: AgentAttentionModel?
    @ObservationIgnored
    var answerAgentTask: Task<Void, Never>?
    /// Asked for by the start that is under way; latched into
    /// `sessionIsQuickCapture` with the output mode, so a start that never
    /// got that far leaves nothing for the next dictation.
    @ObservationIgnored
    var requestedQuickCapture = false
    /// This session is a quick capture (#725): its words go to the Inbox,
    /// never into the focused app.
    @ObservationIgnored
    var sessionIsQuickCapture = false
    /// Asked for by the answer shortcut's start (#927); latched into
    /// `sessionDraftReview` like `requestedQuickCapture`.
    @ObservationIgnored
    var requestedDraftReview: QuickCaptureDraftSnapshot?
    /// This session reviews the one draft the overlay shows (#927): its
    /// words file, drop or change it, and are never inserted.
    @ObservationIgnored
    var sessionDraftReview: QuickCaptureDraftSnapshot?
    /// The filing or redraft the last review started, for tests to await.
    @ObservationIgnored
    var draftReviewTask: Task<Void, Never>?
    /// The Inbox the review acts on. The view model installs it.
    @ObservationIgnored
    var quickCaptureInbox: QuickCaptureInboxModel?
    /// Where a stopped quick capture's words go, with its History record's
    /// id when History kept it. The view model points it at the Inbox.
    @ObservationIgnored
    var onQuickCapture: (@MainActor (_ text: String, _ historyRecordID: UUID?, _ group: ProjectGroup?) -> Void)?
    @ObservationIgnored
    var polishAndCommitTask: Task<Void, Never>?
    /// The start's lookup of the joined session's git root (#1155).
    @ObservationIgnored
    var joinedRepositoryRootLookup: Task<Void, Never>?
    /// This Overlay Buffer dictation's pieces polished while the user speaks
    /// (#709). Handed to the stop's polish task, and cancelled on every
    /// other session exit.
    @ObservationIgnored
    var earlyPolishRun: EarlyPolishRun?
    /// Saves the dictation `polishAndCommitTask` is polishing, as not
    /// inserted, if the task never gets to. A new dictation started over the
    /// polish cancels it, and that dictation used to reach neither the
    /// target app nor History (#526).
    @ObservationIgnored
    var saveInterruptedPolishCommit: (() -> Void)?
    @ObservationIgnored
    // Several finalization callbacks can converge here; keep stop cleanup
    // idempotent until commit/post-processing fully finishes.
    var isCompletingStoppedSession = false
    @ObservationIgnored
    var wasCancelled = false
    @ObservationIgnored
    let escapeCancelHandler = EscapeCancelHandler()
    /// Tab and ⇧Tab while an Overlay Buffer dictation runs (#840).
    @ObservationIgnored
    let destinationKeyHandler = DestinationKeyHandler()
    /// The running overlay's destinations; nil outside an Overlay Buffer
    /// dictation. `sessionIsQuickCapture` follows its pick: the Inbox is a
    /// quick capture.
    @ObservationIgnored
    var destinations: SessionDestinations?
    /// Brings a picked pane forward, or the focused app back.
    @ObservationIgnored
    var destinationFocusTask: Task<Void, Never>?
    /// Closes the overlay's destination list once the user stops moving.
    @ObservationIgnored
    var destinationListCloseTask: Task<Void, Never>?
    /// What the commit checks when the stopped dictation's picks moved the
    /// focus, kept from the stop to the commit.
    @ObservationIgnored
    var sessionCommitGuard: DestinationCommitGuard?
    /// The picked pane that read back before the polish, read back again
    /// right before the insertion (#1056).
    @ObservationIgnored
    var sessionPickedPane: (sessionID: String, bundleID: String)?
    @ObservationIgnored
    var sessionStartedAt: Date?
    /// This start's press → socket → microphone → first buffer line (#527).
    @ObservationIgnored
    var sessionCaptureTimeline: CaptureTimeline?
    @ObservationIgnored
    var sessionProvider: SettingsStore.RealtimeProvider?
    @ObservationIgnored
    var sessionModelName: String?
    @ObservationIgnored
    var sessionReplacementDictionary: ReplacementDictionary?
    /// Latched at start: the session's audio goes to the audio store.
    @ObservationIgnored
    var sessionStoresAudio = false
    /// Latched at start: an Overlay Buffer dictation in Mistral API mode,
    /// which is transcribed again on stop (#317).
    @ObservationIgnored
    var sessionHasStopSecondPass = false
    /// Where the second pass reports what it cost; the realtime client and
    /// the polishing service hold the same ledger.
    @ObservationIgnored
    var secondPassUsageRecorder: (any UsageRecording)?
    /// Live Auto-Paste spoken send trigger state
    /// (`DictationSessionController+SpokenSend.swift`), reset per session.
    enum LiveSpokenSendSegmentMode {
        case undecided, typedLive, withheld
    }
    @ObservationIgnored
    var liveSpokenSendSegmentMode = LiveSpokenSendSegmentMode.undecided
    @ObservationIgnored
    var spokenSendLatch = SendNowResubmitLatch()
    /// Whether live text was typed since the last Return, so the next
    /// withheld segment needs a space before it.
    @ObservationIgnored
    var liveSpokenSendTypedSinceReturn = false
    /// The trigger pressed Return at least once this dictation, so the user
    /// sent it unedited (`liveDictationCanTeachACorrection`).
    @ObservationIgnored
    var liveSpokenSendReturnPressed = false
    /// The last word typed live since the last Return, punctuation
    /// included; empty after a space. A withheld segment that starts mid-word
    /// is glued onto it only when it ends in a letter.
    @ObservationIgnored
    var liveSpokenSendTypedWord = ""
    /// The "text went to another app" line is logged once per dictation.
    @ObservationIgnored
    var liveSpokenSendBlockLogged = false
    /// Live Auto-Paste "go to <name>" state
    /// (`DictationSessionController+LiveGoToSession.swift`), reset per session.
    @ObservationIgnored
    var liveGoToSegmentMode = LiveGoToSegmentMode.undecided
    /// The current segment's deltas the go-to hold-back has not typed.
    @ObservationIgnored
    var liveGoToHeldText = ""
    /// Resolves a spoken name and brings its pane forward; later segments
    /// wait for it.
    @ObservationIgnored
    var liveGoToTask: Task<Void, Never>?
    /// Segments that ended while `liveGoToTask` ran, in order.
    @ObservationIgnored
    var liveGoToQueuedSegments: [LiveGoToQueuedSegment] = []
    /// Where the last go-to of this dictation moved the words, if one did.
    @ObservationIgnored
    var liveGoToLanding: LiveGoToLanding?
    @ObservationIgnored
    var firstChunkPreprocessor = FirstChunkPreprocessor()

    /// The opt-in raw-delta log (`SettingsStore.debugLogRealtimeDeltas`).
    @ObservationIgnored
    var realtimeDeltaLog = RealtimeDeltaLog()
    @ObservationIgnored
    let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

    /// What a dictation carries from start to commit: the screen capture, the
    /// Claude join, the pane sample and the remote forward leases.
    @ObservationIgnored
    let context: SessionContextResolver

    init(
        settings: SettingsStore,
        textInsertion: TextInsertionService,
        engines: EnginesModel,
        backendManager: any ManagedBackendManaging,
        shortcuts: ShortcutController,
        context: SessionContextResolver,
        audio: SessionAudioPipeline,
        overlayBufferCoordinator: OverlayBufferSessionCoordinating,
        dependencies: Dependencies
    ) {
        self.settings = settings
        self.textInsertion = textInsertion
        self.engines = engines
        self.backendManager = backendManager
        self.shortcuts = shortcuts
        self.context = context
        self.audio = audio
        self.overlayBufferCoordinator = overlayBufferCoordinator
        self.dependencies = dependencies
        self.realtimeAPIClient = RealtimeAPIWebSocketClient(clock: dependencies.clock)
        self.mistralRealtimeClient = MistralRealtimeWebSocketClient(clock: dependencies.clock)
    }

    func prepareLLMPolishingPromptAccessIfNeeded() {
        guard settings.llmPolishingEnabled else { return }

        debugLog("preloading LLM polishing prompt/config files")
        _ = appConfigStore.loadLLMPromptTemplates()
    }

    // MARK: - Network

    func handleNetworkChange(connected: Bool) {
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
            // A loopback socket, such as the bundled speech server's, does not
            // ride the network path: stopping would only drop the final commit
            // that flushes the server's tail (#1238), and an idle status saying
            // the network is gone would be wrong about it (#1242). Remote
            // sockets can sit half-dead after the path goes, so those sessions
            // still stop.
            guard realtimeEndpointNeedsNetwork else {
                Log.backends.info("network lost; loopback realtime endpoint unaffected")
                return
            }
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

    /// False when the realtime endpoint is loopback, which a lost network path
    /// leaves untouched. A running or starting session judges the endpoint it
    /// dials: the latched connect snapshot once the socket was asked to open,
    /// else what Settings resolves to for its provider. An idle one judges
    /// what the next start would dial. No endpoint counts as needing one.
    private var realtimeEndpointNeedsNetwork: Bool {
        let sessionActive = isDictating || isFinalizingStop || isConnectingRealtimeSession
        let endpoint = (sessionActive ? sessionRealtimeConfiguration?.endpoint : nil)
            ?? settings.resolvedWebSocketURL(
                for: (sessionActive ? sessionProvider : nil) ?? settings.realtimeProvider
            )
        guard let endpoint else { return true }
        return !PolishContextClipboardReader.isLoopbackEndpoint(endpoint)
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
            // A commit already polishing is cancelled and saved as not
            // inserted, as a new dictation does to it (#1059).
            guard !cancelPolishingForNewSessionIfNeeded() else { return }
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

    func refreshMicrophoneInputs() {
        audio.refreshMicrophoneInputs()
    }

    /// Saves and selects the input; a running dictation restarts on it.
    func selectMicrophoneInput(id: String) {
        guard audio.selectMicrophoneInput(id: id) else { return }

        guard isDictating else { return }
        restartOnNewInput(reason: "input device changed by user")
    }

    var selectedInputDeviceChannelCount: UInt32 { audio.selectedInputDeviceChannelCount }
    var selectedInputChannel: Int { audio.selectedInputChannel }

    /// Saves the input channel; a running dictation restarts on it.
    func selectMicrophoneInputChannel(_ channel: Int) {
        guard audio.selectMicrophoneInputChannel(channel) else { return }

        guard isDictating else { return }
        restartOnNewInput(reason: "input channel changed by user")
    }

    /// Stops the running session and starts the same kind again: a quick
    /// capture restarts as a capture, never as a dictation into the app.
    private func restartOnNewInput(reason: String) {
        let quickCapture = sessionIsQuickCapture
        let draftReview = sessionDraftReview
        stopDictation(reason: reason, finalizeRemainingAudio: false)
        startDictation(
            outputMode: quickCapture || draftReview != nil ? .overlayBuffer : nil,
            quickCapture: quickCapture,
            draftReview: draftReview
        )
    }

    func startDictation(outputMode: DictationOutputMode? = nil) {
        startDictation(outputMode: outputMode, quickCapture: false)
    }

    /// The quick capture shortcut: an Overlay Buffer capture, or the stop of
    /// the one running. During an Overlay Buffer dictation it picks the
    /// Inbox, as Tab would (#840); during Live Auto-Paste it does nothing,
    /// since words already typed cannot go to the Inbox.
    func toggleQuickCapture() {
        if isDictating {
            if pickInboxOrStop() { return }
            Log.dictation.info("quick capture: pressed during a Live Auto-Paste dictation; ignored")
            return
        }
        startDictation(outputMode: .overlayBuffer, quickCapture: true)
    }

    func startDictation(
        outputMode: DictationOutputMode?, quickCapture: Bool, draftReview: QuickCaptureDraftSnapshot? = nil
    ) {
        guard !isDictating else { return }
        // An answer whose pane is still coming forward would activate its
        // terminal under this dictation and take its words there.
        answerAgentTask?.cancel()
        answerAgentTask = nil
        onDictationStartRequested?()
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
        guard networkMonitor.isConnected || !realtimeEndpointNeedsNetwork else {
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
            // Set only where the start goes ahead: a start refused above must
            // leave nothing for the next one (#732 review).
            requestedQuickCapture = quickCapture
            requestedDraftReview = draftReview
            beginDictationAfterManagedBackendIfNeeded(outputMode: outputMode)
        case .notDetermined:
            isAwaitingMicrophonePermission = true
            statusText = StatusStrings.requestingMicrophonePermission
            debugLog("microphone permission prompt requested")
            let attemptID = UUID()
            microphonePermissionAttemptID = attemptID
            requestMicrophoneAccessForSessionStart { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // The prompt timed out (or a newer one replaced it): the
                    // user has moved on, and a push-to-talk key is long released.
                    guard self.microphonePermissionAttemptID == attemptID else {
                        self.debugLog("microphone permission result granted=\(granted) for an expired attempt; ignored")
                        return
                    }
                    self.microphonePermissionAttemptID = nil
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
                    // This start's kind, not whatever a press made of the
                    // flag while the prompt was up.
                    self.requestedQuickCapture = quickCapture
                    self.requestedDraftReview = draftReview
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
            microphonePermissionTimeoutTask?.cancel()
            microphonePermissionTimeoutTask = Task { [weak self, clock = dependencies.clock] in
                await clock.sleep(.seconds(TimingConstants.microphonePermissionPromptTimeout))
                // A cancelled timeout belongs to a prompt a newer one replaced:
                // it must not clear the newer prompt's flag.
                guard let self, !Task.isCancelled, self.isAwaitingMicrophonePermission else { return }
                self.isAwaitingMicrophonePermission = false
                self.microphonePermissionAttemptID = nil
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
        audio.microphoneAuthorizationStatus()
    }

    func stopDictation(reason: String = "unspecified", finalizeRemainingAudio: Bool = true) {
        guard isDictating else { return }
        debugLog("stopDictation reason=\(reason)")
        shortcuts.clearPushToTalkShortcutSessionAttempt()
        disarmSilenceAutoStop()
        disarmSpokenStop()

        // Before anything else: a reconnect run still in flight must not be
        // allowed to hand this session a socket after the user stopped it.
        cancelRealtimeReconnect()
        polishAndCommitTask?.cancel()
        polishAndCommitTask = nil
        audio.cancelSendAndCommitTasks()
        audio.healthMonitor.stop()
        isAwaitingMicrophonePermission = false

        audio.stopSessionAudioCapture()
        audio.audioDucking.restoreAfterSession()
        audio.flushBufferedAudio(to: activeRealtimeClient)
        isDictating = false
        // An Overlay Buffer stop keeps Escape until its commit is done:
        // the text waits there on the final and the polish, and Escape
        // cancels it (`completeStoppedSessionCleanup` releases the key).
        // Live Auto-Paste has typed its words, so Escape goes back to the
        // focused app now.
        if !isOverlayBufferModeEnabled {
            escapeCancelHandler.stop()
        }
        endDestinations()

        guard finalizeRemainingAudio else {
            activeRealtimeClient.disconnect()
            ownStopWithoutFinalization()
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

    /// A stop that skips finalization owns its commit until it completes,
    /// as a finalizing stop does: a start meanwhile (a new microphone,
    /// #1055) must go through `cancelPolishingForNewSessionIfNeeded`, which
    /// saves the text. The socket is gone, so nothing it still emits may
    /// reach the transcript the commit is using.
    func ownStopWithoutFinalization() {
        sessionConnectionGeneration = .none
        isFinalizingStop = true
    }

    func clearTranscript() {
        transcript = TranscriptAccumulator()
        if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession {
            clearLatchedSessionMetadata()
        }
        firstChunkPreprocessor.reset()
        overlayBufferCoordinator.reset()
        lastError = nil
    }

    func copyTranscript() {
        let fullText = transcript.fullTranscript.trimmed
        guard !fullText.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullText, forType: .string)

        statusText = "Transcript copied."
    }

    /// Live Auto-Paste with "Copy on stop" on: after each final, the
    /// dictation so far goes to the clipboard, so it holds the whole
    /// dictation once the session stops. Silent, since the status line
    /// belongs to the running session.
    func autoCopyDictationSoFar() {
        let segment = lastFinalSegment.trimmed
        guard !segment.isEmpty else { return }
        writeToPasteboard(segment)
    }

    /// Copies the RAW (pre-polish) transcript of the last polish-changed commit
    /// to the clipboard (F6). No-op when there is nothing to offer.
    func copyRawTranscript() {
        guard let raw = lastPolishChangedRawTranscript?.trimmed, !raw.isEmpty else { return }
        writeToPasteboard(raw)
        statusText = "Raw transcript copied."
    }

    /// Copies the last dictation's text: the polished text, or the transcript
    /// when polishing failed (`LastDictationCopy`). Reached from the menu bar
    /// and from its optional global shortcut.
    func copyLastDictation() {
        // Mid-session the status line belongs to the session: "Listening..."
        // must not turn into a line about the clipboard.
        let ownsStatusLine = !isDictating && !isFinalizingStop && !isConnectingRealtimeSession
        guard let text = lastDictation?.textToCopy else {
            Log.dictation.notice("copy last dictation: nothing to copy")
            if ownsStatusLine { statusText = StatusStrings.noDictationToCopy }
            return
        }
        writeToPasteboard(text)
        Log.dictation.info("copy last dictation: copied \(text.count, privacy: .public) chars")
        if ownsStatusLine { statusText = StatusStrings.lastDictationCopied }
    }

    /// Makes `lastDictation` the newest dictation in History. Run at launch
    /// and after History changes, so a deleted dictation stops being
    /// copyable; with History off the store is empty and changes no more,
    /// and `lastDictation` is whatever this run saved last.
    func refreshLastDictationFromStore() async {
        guard let store = sessionStore else { return }
        let generation = lastDictationGeneration
        var query = DictationHistoryQuery()
        query.limit = 1
        let newest = await store.entries(matching: query).first
        guard generation == lastDictationGeneration else { return }
        // A dictation saved while History is off never reached the store, so
        // an empty store says nothing about it. One that History held was
        // deleted with it: turning History off deletes every dictation.
        guard newest != nil || lastDictationIsInHistory else { return }
        // The same dictation: keep the in-memory copy, which holds the
        // clipboard text History stores only as a placeholder.
        if let newest, newest.id == lastDictation?.id {
            lastDictationIsInHistory = true
            return
        }
        lastDictation = newest
        lastDictationIsInHistory = newest != nil
    }

    /// Called by the stop-commit for every dictation it saves.
    func rememberLastDictation(_ entry: DictationHistoryEntry, isInHistory: Bool) {
        lastDictation = entry
        lastDictationIsInHistory = isInHistory
    }

    private func writeToPasteboard(_ text: String) {
        dependencies.pasteboardWriter(text)
    }

    /// Samples the terminal-like verdict and Secure Keyboard Entry state for
    /// the app focused right now. Called from `prepareDictationSession` before
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

    /// Consumes the verdict captured at `prepareDictationSession` time once
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

    func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        Log.dictation.debug("\(message)")
    }
}

extension DictationSessionController: ShortcutSessionControlling {
    func endDictation(reason: String) {
        stopDictation(reason: reason)
    }

    func overlayReachabilityDidChange(wasReachable: Bool) {
        engines.handleOverlayReachabilityTransition(wasReachable: wasReachable)
    }
}

extension DictationSessionController: PermissionSessionControlling {}

extension DictationSessionController {
    /// Start-of-session capture, through the resolver; the badge it returns
    /// describes the one resolved join, so the overlay cannot disagree with
    /// the context that ships.
    ///
    /// `isCurrent` is asked after every suspension: once it answers false,
    /// this start was cancelled or replaced, and nothing it resolved is
    /// written over the state a newer start owns.
    func captureTerminalScreenContextForSession(isCurrent: @MainActor () -> Bool = { true }) async {
        // The previous dictation's post-commit edit watch closes here rather
        // than reading this session's keys. It still flushes its own record,
        // as `superseded`.
        editSignalWatcher.supersede()
        let badge = await context.captureAtStart(isCurrent: isCurrent)
        guard isCurrent() else { return }
        sessionClaudeJoinBadge = badge
        joinedRepositoryRootLookup?.cancel()
        joinedRepositoryRootLookup = Task { [weak self] in await self?.lookUpJoinedRepositoryRoot() }
        noteDictationJoinedAgentSession(context.claudeSessionJoin?.snapshot.sessionID)
        await context.resolveAgentPromptRoute(isCurrent: isCurrent)
    }
}
