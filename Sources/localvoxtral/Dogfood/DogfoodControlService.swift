#if LOCALVOXTRAL_DOGFOOD

import Foundation
import Synchronization

/// Executes one control-socket command against the LIVE app.
///
/// Everything the socket exists for is here; the socket file is transport. Each
/// seam is injected, so every branch below — including the refusals — is
/// reachable from a test with no window, no registry and no descriptor.
///
/// ## The one thing the one-shot probe cannot do
///
/// `localvoxtral --probe-surface` (PR #237) resolves the focused surface in a
/// FRESH process, and `ClaudeSessionRegistry` is per-process with no
/// persistence — so that probe always resolves against an empty registry and
/// can never report a real join arm. `surface probe` here runs the same
/// decision function (`ClaudeSurfaceProbe.summarize`) inside the running app,
/// against the registry the broker has been filling since launch. That is the
/// entire reason this socket exists, and it is why the probe verb's read-only
/// capability withholding is deliberately NOT copied: the app is a legitimate
/// owner of a supervised `ssh -L` and of a nonce lease it will clear, which a
/// one-shot process is not.
///
/// ## What is not here
///
/// No seam accepts a surface, a session, a tty, a pane id or a marker from the
/// caller. Every command observes; none injects. A control socket that could
/// fabricate a session would answer questions about itself.
@MainActor
final class DogfoodControlService {
    /// The dictation `session start` arms is stopped after this long no matter
    /// what the client does next.
    ///
    /// A socket client is a script or an agent, and both die: `nc` gets ^C'd,
    /// an ssh session drops, an agent's turn ends. Without a cap the app would
    /// be left recording, holding the realtime socket open and typing into
    /// whatever is focused, with the only way out being the owner's own hotkey
    /// — on a machine the operator by hypothesis cannot see. Two minutes is
    /// far past any real dictation and far short of a session anyone would
    /// leave running.
    static let autoStopSeconds = 120

    /// Deadline for one `surface probe`. The resolver spends Apple events, a
    /// socket dial and possibly an `ssh -G`; a consent sheet or a wedged
    /// socket blocks until answered. Same ceiling and same reasoning as
    /// `ClaudeSurfaceProbeCommand.deadline` — a diagnostic that hangs is worse
    /// than one that abstains.
    static let probeDeadlineSeconds = 25

    typealias SleepClosure = @Sendable (Duration) async -> Void

    private weak var viewModel: DictationViewModel?
    private let liveSessions: @MainActor () -> [ClaudeSessionSnapshot]
    private let hasLiveSessions: @MainActor () -> Bool
    private let accessibilityTrusted: @MainActor () -> Bool
    private let frontmostTarget: @MainActor () -> TerminalScreenTarget?
    private let resolveSurface: @MainActor (TerminalScreenTarget) async -> ClaudeSessionJoin?
    private let sleepFor: SleepClosure
    private let autoStopAfter: Duration

    /// The bounded auto-stop for the session `session start` opened. Held so
    /// every exit path can release it: an explicit `session stop`, a start that
    /// was refused, the auto-stop firing, and `shutdown()` at quit.
    private var autoStopTask: Task<Void, Never>?
    /// Guards against a second command arriving mid-probe.
    /// `ClaudeJoinAbstentionTap.collecting` is documented as non-reentrant, and
    /// two overlapping probes would interleave one another's causes.
    private var isExecuting = false

    init(
        viewModel: DictationViewModel?,
        liveSessions: @escaping @MainActor () -> [ClaudeSessionSnapshot],
        hasLiveSessions: @escaping @MainActor () -> Bool,
        accessibilityTrusted: @escaping @MainActor () -> Bool,
        frontmostTarget: @escaping @MainActor () -> TerminalScreenTarget?,
        resolveSurface: @escaping @MainActor (TerminalScreenTarget) async -> ClaudeSessionJoin?,
        sleepFor: @escaping SleepClosure = { try? await Task.sleep(for: $0) },
        autoStopAfter: Duration = .seconds(DogfoodControlService.autoStopSeconds)
    ) {
        self.viewModel = viewModel
        self.liveSessions = liveSessions
        self.hasLiveSessions = hasLiveSessions
        self.accessibilityTrusted = accessibilityTrusted
        self.frontmostTarget = frontmostTarget
        self.resolveSurface = resolveSurface
        self.sleepFor = sleepFor
        self.autoStopAfter = autoStopAfter
    }

    /// Refusals this service raises before a command reaches the app. Content
    /// free, like every other value that crosses the socket.
    enum Refusal: String, Error, Equatable {
        case noViewModel = "the app has no dictation model"
        case busy = "another control command is still running"
        case alreadyDictating = "a dictation is already running"
        case notDictating = "no dictation is running"
        case dictationInProgress = "refusing to probe while a dictation is resolving its own join"
        case probeTimedOut = "the resolver did not answer within the probe deadline"
    }

    /// Run one command. Returns the JSON body for `result`, or a refusal.
    func execute(_ command: DogfoodControlProtocol.Command) async -> Result<String, Refusal> {
        guard !isExecuting else { return .failure(.busy) }
        isExecuting = true
        defer { isExecuting = false }

        switch command {
        case .sessionStart(let mode): return startSession(mode: mode)
        case .sessionStop: return stopSession()
        case .joinReport: return .success(joinReport())
        case .surfaceProbe: return await surfaceProbe()
        case .registryList: return .success(registryList())
        }
    }

    /// Release the auto-stop. Called from `applicationWillTerminate`, so a quit
    /// during an armed window does not leave a task waiting on a view model
    /// that is being torn down.
    func shutdown() {
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    // MARK: - session

    /// The REAL trigger path, not a shortcut around it.
    ///
    /// `dogfoodHandleModifierOnlyTap` is the app's own modifier-only tap
    /// handler — the same function the HID gesture reaches, subject to the
    /// same Secure Keyboard Entry refusal, the same Accessibility state, the
    /// same microphone gate, and the same managed-backend readiness. Whatever
    /// it refuses, this reports; it never overrides one. The one thing added
    /// on top is a REFUSAL, not a bypass: a `session start` that arrived while
    /// a dictation was running would toggle it OFF, so it is rejected instead.
    private func startSession(mode: DictationOutputMode) -> Result<String, Refusal> {
        guard let viewModel else { return .failure(.noViewModel) }
        guard !viewModel.isDictating else { return .failure(.alreadyDictating) }

        Log.claudeContext.info(
            "Dogfood control: session start mode=\(mode.rawValue, privacy: .public)"
        )
        viewModel.dogfoodHandleModifierOnlyTap(mode: mode)

        let phase = phase(of: viewModel)
        // Armed for anything that is on its way to being a live session, not
        // just `isDictating`: a start that is still connecting, or still
        // waiting on the microphone prompt, becomes a dictation moments later
        // and must be inside the cap too.
        if phase != .idle {
            armAutoStop()
        } else {
            releaseAutoStop()
        }
        Log.claudeContext.info(
            "Dogfood control: session start phase=\(phase.rawValue, privacy: .public)"
        )
        return .success(DogfoodControlJSON.object([
            ("started", DogfoodControlJSON.bool(phase != .idle)),
            ("phase", DogfoodControlJSON.string(phase.rawValue)),
            ("outputMode", DogfoodControlJSON.string(mode.rawValue)),
            ("statusToken", DogfoodControlJSON.string(Self.name(viewModel.currentStatusToken))),
            ("errorToken", DogfoodControlJSON.optionalString(
                viewModel.currentErrorToken.map(Self.name)
            )),
            ("secureInputActive", DogfoodControlJSON.bool(viewModel.sessionSecureInputActive)),
            ("accessibilityTrusted", DogfoodControlJSON.bool(viewModel.isAccessibilityTrusted)),
            ("autoStopSeconds", DogfoodControlJSON.int(Int(autoStopAfter.components.seconds))),
        ]))
    }

    private func stopSession() -> Result<String, Refusal> {
        guard let viewModel else { return .failure(.noViewModel) }
        guard viewModel.isDictating else {
            // Release anyway: a start that never became a dictation (refused
            // at the microphone prompt, say) can still have armed the cap.
            releaseAutoStop()
            return .failure(.notDictating)
        }
        Log.claudeContext.info("Dogfood control: session stop")
        // The stop half of the same gesture. A tap toggles, and the toggle's
        // stop branch ignores the mode — it is passed for shape, so this call
        // is literally the gesture the user's own second tap produces.
        viewModel.dogfoodHandleModifierOnlyTap(mode: viewModel.settings.dictationOutputMode)
        releaseAutoStop()
        return .success(DogfoodControlJSON.object([
            ("stopped", DogfoodControlJSON.bool(!viewModel.isDictating)),
            ("phase", DogfoodControlJSON.string(phase(of: viewModel).rawValue)),
            ("statusToken", DogfoodControlJSON.string(Self.name(viewModel.currentStatusToken))),
            ("errorToken", DogfoodControlJSON.optionalString(
                viewModel.currentErrorToken.map(Self.name)
            )),
        ]))
    }

    private func armAutoStop() {
        releaseAutoStop()
        autoStopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleepFor(self.autoStopAfter)
            guard !Task.isCancelled else { return }
            self.autoStopTask = nil
            guard let viewModel = self.viewModel else { return }
            guard viewModel.isDictating || viewModel.isConnectingRealtimeSession else { return }
            Log.claudeContext.error(
                "Dogfood control: auto-stopping a session that outlived the control-socket cap"
            )
            viewModel.dogfoodHandleModifierOnlyTap(mode: viewModel.settings.dictationOutputMode)
        }
    }

    private func releaseAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    /// True while the bounded stop is armed. Test seam only — nothing on the
    /// wire reports it.
    var isAutoStopArmed: Bool { autoStopTask != nil }

    // MARK: - join / probe / registry

    /// The join the LAST dictation resolved, with the abstention chain that
    /// produced it — read from the tap's durable slot rather than the
    /// consumable one, so asking does not steal the capture record's causes.
    private func joinReport() -> String {
        let recorded = DogfoodCaptureTap.shared.lastResolvedJoin()
        return DogfoodControlJSON.object([
            ("present", DogfoodControlJSON.bool(recorded != nil)),
            ("dictations", DogfoodControlJSON.int(Int(DogfoodCaptureTap.shared.currentGeneration))),
            ("join", recorded?.jsonLine ?? "null"),
        ])
    }

    private func surfaceProbe() async -> Result<String, Refusal> {
        // A dictation resolves its own join through the same resolver and the
        // same forward service. Racing it would interleave two resolutions and
        // could hand the dictation a forward this probe is tearing down.
        if let viewModel, viewModel.isDictating || viewModel.isConnectingRealtimeSession {
            return .failure(.dictationInProgress)
        }
        let sessions = liveSessions().count
        let trusted = accessibilityTrusted()
        let target = frontmostTarget()
        let resolve = resolveSurface
        let liveness = hasLiveSessions

        // Bounded, and bounded by ABANDONMENT rather than by cancellation.
        //
        // A task group would wait for every child before returning, so a
        // resolver wedged in a syscall that ignores cancellation — an
        // Automation consent sheet, a socket the kernel has not given up on —
        // would hang the deadline it was supposed to be subject to. So the
        // first of the two to answer wins and the loser is simply left to
        // finish into a continuation nobody is holding, which is exactly what
        // `ClaudeSurfaceProbeCommand` does with its run-loop pump.
        let sleepFor = self.sleepFor
        let deadline = Duration.seconds(Self.probeDeadlineSeconds)
        let summary: ClaudeSessionJoinSummary? = await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            @Sendable func finish(_ value: ClaudeSessionJoinSummary?) {
                let isFirst = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard isFirst else { return }
                continuation.resume(returning: value)
            }
            Task { @MainActor in
                finish(await ClaudeSurfaceProbe.summarize(
                    accessibilityTrusted: trusted,
                    frontmostTarget: target,
                    hasLiveSessions: liveness,
                    resolve: resolve
                ))
            }
            Task {
                await sleepFor(deadline)
                finish(nil)
            }
        }
        guard let summary else { return .failure(.probeTimedOut) }
        Log.claudeContext.info(
            "Dogfood control: surface probe arm=\(summary.arm, privacy: .public)"
        )
        return .success(DogfoodControlJSON.object([
            ("registrySessions", DogfoodControlJSON.int(sessions)),
            ("join", summary.jsonLine),
        ]))
    }

    /// The live registry, as SHAPES.
    ///
    /// This verb exists to separate "no sessions registered" from "surface
    /// resolution failed" — the single most common dead end in this area, where
    /// an empty registry and a surface the resolver could not identify produce
    /// the same silence. Answering it needs a count and, per session, which
    /// join keys it even carries. It does NOT need the keys themselves, so
    /// none of them is here: no session id, no marker, no workspace, no tty, no
    /// pane id, no socket path, no bridge id, no host. Every field below is a
    /// bool, a count or a closed enum name.
    private func registryList() -> String {
        let sessions = liveSessions()
        let rows = sessions.map { snapshot -> String in
            let process = snapshot.process
            return DogfoodControlJSON.object([
                ("origin", DogfoodControlJSON.string(
                    snapshot.origin.isLocalAuthenticated ? "local" : "remote"
                )),
                ("agent", DogfoodControlJSON.string(snapshot.agent.rawValue)),
                ("workspaceIsLocal", DogfoodControlJSON.bool(snapshot.localWorkspacePath != nil)),
                ("hasProcessBlock", DogfoodControlJSON.bool(process != nil)),
                ("hasTTY", DogfoodControlJSON.bool(process?.tty != nil)),
                ("hasHerdrPane", DogfoodControlJSON.bool(process?.herdrPaneID != nil)),
                ("hasHerdrSocket", DogfoodControlJSON.bool(process?.herdrSocketPath != nil)),
                ("hasCmuxSurface", DogfoodControlJSON.bool(process?.cmuxSurfaceID != nil)),
                ("hasBridgeSession", DogfoodControlJSON.bool(snapshot.bridgeSessionID != nil)),
                ("hasRemoteEnvironment", DogfoodControlJSON.bool(
                    snapshot.remoteSessionEnvironment != nil
                )),
                ("recentFiles", DogfoodControlJSON.int(snapshot.recentFiles.count)),
                ("hasPriorPrompt", DogfoodControlJSON.bool(
                    snapshot.latestPriorUserPrompt != nil
                )),
            ])
        }
        return DogfoodControlJSON.object([
            ("count", DogfoodControlJSON.int(sessions.count)),
            ("sessions", DogfoodControlJSON.array(rows)),
        ])
    }

    // MARK: - Vocabulary

    /// Where the app is, as one closed word. Derived from the view model's own
    /// booleans rather than from `statusText`, which is user-facing copy.
    enum Phase: String {
        case dictating
        case connecting
        case awaitingMicrophonePermission
        case finalizing
        case idle
    }

    private func phase(of viewModel: DictationViewModel) -> Phase {
        if viewModel.isDictating { return .dictating }
        if viewModel.isConnectingRealtimeSession { return .connecting }
        if viewModel.isAwaitingMicrophonePermission { return .awaitingMicrophonePermission }
        if viewModel.isFinalizingStop { return .finalizing }
        return .idle
    }

    /// `StatusToken` and `ErrorToken` are the app's own content-free
    /// categories; these two switches are exhaustive on purpose, so a new case
    /// upstream is a compile error here rather than a silently missing word.
    static func name(_ token: DictationViewModel.StatusToken) -> String {
        switch token {
        case .waitingForAccessibilityPermission: return "waitingForAccessibilityPermission"
        case .pasteBlockedByAccessibilityPermission: return "pasteBlockedByAccessibilityPermission"
        case .awaitingMicrophonePermission: return "awaitingMicrophonePermission"
        case .networkLostDictationStopped: return "networkLostDictationStopped"
        case .noNetworkConnection: return "noNetworkConnection"
        case .hotKeyHandlerRegistrationFailure: return "hotKeyHandlerRegistrationFailure"
        case .hotKeyShortcutUnavailable: return "hotKeyShortcutUnavailable"
        case .other: return "other"
        }
    }

    static func name(_ token: DictationViewModel.ErrorToken) -> String {
        switch token {
        case .accessibilityPermissionRequired: return "accessibilityPermissionRequired"
        case .hotKeyHandlerRegistrationFailure: return "hotKeyHandlerRegistrationFailure"
        case .hotKeyShortcutUnavailable: return "hotKeyShortcutUnavailable"
        case .websocketReceiveFailed: return "websocketReceiveFailed"
        case .secureKeyboardEntryActive: return "secureKeyboardEntryActive"
        case .other: return "other"
        }
    }
}

#endif
