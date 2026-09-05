import ClaudeContextWire
import CoreGraphics
import Foundation

/// One dictation's answer to "which Claude Code session is the user talking
/// to?", resolved ONCE and then shared by everything that needs it.
///
/// Resolving once is a correctness requirement, not an optimization. The three
/// consumers — raw screen attachment, hook state (the prior prompt), and
/// repository context — must describe the SAME session, or the prompt tells the
/// model that the user was working in one repo while showing it another one's
/// screen. Three independent resolutions cannot promise that: the user can
/// switch tabs mid-sentence, and each read would then answer honestly about a
/// different moment. So the surface is read at START, from the pane the user
/// was looking at when they began speaking, and that answer is what every
/// consumer gets.
enum ClaudeSessionJoinMechanism: Sendable, Equatable {
    case ttyDevice
    case herdrPane
    /// The focused browser tab's `claude.ai/code/session_…` URL matched a live
    /// session's Remote Control bridge session id. No screen is ever read for
    /// this mechanism — see `TerminalScreenClaudeJoinAuthorizer`.
    case browserTab
    /// A cmux surface, matched by the surface id cmux injected into the
    /// session's environment. Local surfaces and `cmux ssh` remote shells both
    /// arrive here — see `ClaudeSessionJoinResolver.resolveViaCmux`.
    case cmuxSurface
    /// A Claude Code session inside a herdr running on an ENROLLED REMOTE host,
    /// reached over an app-managed `ssh -L` to that herdr's socket.
    case remoteHerdrPane
}

/// The herdr pane a herdr join resolved to. Captured at resolution so the
/// pane-text fetch can only ever be keyed by the pane the join is ABOUT —
/// there is no other place a pane id enters that path.
///
/// `socketPath` is always a LOCAL socket this user owns: herdr's own socket for
/// a `.herdrPane` join, and the local end of our `ssh -L` for a
/// `.remoteHerdrPane` one. The remote host's own socket path never appears
/// here; it exists only as an argv token inside the forward.
struct ClaudeHerdrPaneBinding: Sendable, Equatable {
    let paneID: String
    let socketPath: String
}

/// The Remote Control bridge session id a `.browserTab` join resolved on.
/// Captured at resolution so commit-time liveness can ask whether the SAME
/// binding still holds, rather than re-reading a tab the user may have changed.
struct ClaudeBrowserTabBinding: Sendable, Equatable {
    let bridgeSessionID: String
}

/// The cmux surface a `.cmuxSurface` join resolved to. Same role as
/// `ClaudeHerdrPaneBinding`: captured at resolution so the surface-text fetch
/// can only ever be keyed by the surface the join is ABOUT.
struct ClaudeCmuxSurfaceBinding: Sendable, Equatable {
    let surfaceID: String
}

struct ClaudeSessionJoin: Sendable, Equatable {
    /// The pane the join was resolved for. Consumers re-check this rather than
    /// assuming the join is about whatever target they happen to hold.
    let target: TerminalScreenTarget
    /// The session as the registry described it at start. Its `sessionID` is
    /// the handle commit-time liveness re-checks (`isStillLive`).
    let snapshot: ClaudeSessionSnapshot
    /// The identity of the WINDOW that was focused when the join resolved.
    /// `target` cannot
    /// tell two windows of one Ghostty process apart, and the screen capture is
    /// a SEPARATE read that can land on a different window if focus moves
    /// between the two — so authorization compares windows, not just targets
    /// (review F2). Nil means unknown, which never authorizes.
    let windowID: CGWindowID?
    /// Positive evidence that selected this session. In particular, a herdr
    /// pane join is useful for session/repository context but can never license
    /// a composite raw TUI capture.
    let mechanism: ClaudeSessionJoinMechanism
    /// Non-nil exactly for herdr joins: the pane whose clean, per-pane text
    /// (`pane.read`) may stand in for the composite screen capture.
    let herdrPane: ClaudeHerdrPaneBinding?
    /// Non-nil exactly for `.browserTab` joins: the bridge session id the tab
    /// URL and the session's hooks agreed on. Commit-time liveness re-checks it
    /// (`isStillLive`), which is how a Remote Control disconnect ages the join
    /// out on the session's own next hook rather than on a timer of ours.
    let browserTab: ClaudeBrowserTabBinding?
    /// Non-nil exactly for `.cmuxSurface` joins: the surface whose clean,
    /// per-surface text (`surface.read_text`) is the ONLY screen route cmux has.
    let cmuxSurface: ClaudeCmuxSurfaceBinding?
    /// Non-nil exactly for `.remoteHerdrPane` joins: the `ssh -L` this join
    /// runs over.
    ///
    /// Carried ON THE JOIN because its lifetime IS the join's: the stop-side
    /// `pane.read` has to reach the same herdr the start-side one did, and the
    /// join is the one object every consumer of that answer already holds.
    /// Closing it is the holder's job (`close()` is idempotent, and the handle
    /// closes itself on deinit as a backstop).
    let remoteHerdrForward: ClaudeRemoteHerdrForwardHandle?
    /// The agents-panel token lease for a panel-authorized remote join. The
    /// view model starts it after taking ownership and stops it on every exit.
    let remoteHerdrIndicator: HerdrPanelMicIndicator?

    init(
        target: TerminalScreenTarget,
        snapshot: ClaudeSessionSnapshot,
        windowID: CGWindowID?,
        mechanism: ClaudeSessionJoinMechanism,
        herdrPane: ClaudeHerdrPaneBinding? = nil,
        browserTab: ClaudeBrowserTabBinding? = nil,
        cmuxSurface: ClaudeCmuxSurfaceBinding? = nil,
        remoteHerdrForward: ClaudeRemoteHerdrForwardHandle? = nil,
        remoteHerdrIndicator: HerdrPanelMicIndicator? = nil
    ) {
        self.target = target
        self.snapshot = snapshot
        self.windowID = windowID
        self.mechanism = mechanism
        self.herdrPane = herdrPane
        self.browserTab = browserTab
        self.cmuxSurface = cmuxSurface
        self.remoteHerdrForward = remoteHerdrForward
        self.remoteHerdrIndicator = remoteHerdrIndicator
    }

    /// The per-pane socket route this join owns, if any: the herdr pane id or
    /// the cmux surface id. Lets the shared socket-pane screen path key its
    /// start/stop reconciliation without knowing which multiplexer answered.
    var socketPaneKey: String? {
        switch mechanism {
        case .herdrPane, .remoteHerdrPane: return herdrPane?.paneID
        case .cmuxSurface: return cmuxSurface?.surfaceID
        case .ttyDevice, .browserTab: return nil
        }
    }

    // Deliberately NO `releaseResources()` here. The join VALUE travels — it is
    // consumed by the commit path and captured into a Task — so a resource
    // whose owner is "whoever currently holds the join" has no owner at all,
    // which is how an aborted connect and a quit-during-polish each leaked an
    // ssh child (review finding 4). `DictationViewModel` takes ownership of the
    // handle when it assigns the join, and closes it from every exit.

    /// The workspace path, non-nil only for a locally authenticated session.
    /// The type is what keeps a remote session's cwd away from the filesystem;
    /// there is nothing to check here because there is nothing to check WITH.
    var localWorkspacePath: LocalWorkspacePath? { snapshot.localWorkspacePath }
}

/// Resolves the focused pane to a live Claude session, and authorizes raw
/// screen attachment only when that join is unambiguous.
///
/// This is the positive gate `TerminalScreenRawAttachmentPolicy` was written to
/// wait for. Every arm below is the same shape, and the shape is what makes it
/// a gate rather than a guess:
///
/// 1. A session was authenticated by its TRANSPORT — peer credentials for a
///    local one (`ClaudeTransportOrigin`), an enrolled host's token for a
///    remote one — so a candidate existing at all means someone we trust
///    reported it.
/// 2. That session's own hooks published a HANDLE to where it lives: a
///    controlling TTY, a herdr pane id, a cmux surface id, a Remote Control
///    bridge session id.
/// 3. We read the SAME KIND of handle off the surface the user is actually
///    looking at, from the PID we captured — never system-wide focus.
/// 4. The two are compared for exact equality, and the registry still resolves
///    the match to ONE live session.
///
/// Every link abstains rather than guesses, because the failure modes are not
/// symmetric: a wrong `true` renders an unrelated terminal's scrollback into
/// someone's prompt, while a wrong `false` costs only an excerpt whose terms the
/// vocabulary matcher already extracted. So a surface that publishes no handle
/// we can read (a plain shell, an editor, a terminal the user opened
/// themselves) joins nothing, and so does `unknown`, `stale` (past TTL, or the
/// agent process is gone) or `ambiguous` (more than one live session matches).
///
/// Note what is NOT here: any inference from the cwd, the window title, or
/// "there is only one live session so it must be that one". No window title is
/// read for a join at all — it is a fought-over channel that every party in the
/// stack rewrites. A sole-session heuristic is wrong precisely when it matters
/// — the user has one Claude session open and is dictating into an unrelated
/// shell — and it would attach that session's repo to a prompt that has nothing
/// to do with it.
@MainActor
struct ClaudeSessionJoinResolver {
    private let registry: ClaudeSessionRegistry
    private let focusedTerminalTTY: (String) async -> String?
    private let focusedBrowserTabURL: (String) async -> String?
    private let focusedWindowID: (pid_t) -> CGWindowID?
    private let herdrClientProbe: @Sendable (String) -> Bool
    private let herdrPanes: HerdrPaneQuerying?
    private let cmuxSurfaces: CmuxSurfaceQuerying?
    private let cmuxJoinEnabled: @MainActor () -> Bool
    private let reportCmuxStatus: @MainActor (CmuxSocketStatus) -> Void
    private let sshDestinationProbe: @Sendable (String) -> SSHDestinationTTYProbeResult
    private let enrolledHosts: @MainActor (String) -> [ClaudeRemoteHost]
    private let canonicalizedEnrolledHosts: @MainActor (String) async -> [ClaudeRemoteHost]
    private let speculativeHosts: @MainActor () -> [ClaudeRemoteHost]
    private let remoteHerdrForwards: (any ClaudeRemoteHerdrForwarding)?
    private let herdrPanelMetadata: (any HerdrPanelMetadataReporting)?
    private let readFocusedGrid: HerdrPanelBindingProbe.GridRead
    private let panelNow: HerdrPanelBindingProbe.Now
    private let panelSleepFor: HerdrPanelBindingProbe.SleepFor
    private let panelRandomBits: HerdrPanelBindingProbe.RandomBits
    private let indicatorSleepFor: HerdrPanelMicIndicator.SleepFor
    private let reportPanelStatus: @MainActor (HerdrPanelConfigurationStatus) -> Void

    /// - Parameters:
    ///   - focusedTerminalTTY: reads the focused pane's controlling TTY for a
    ///     bundle id over AppleScript (Ghostty ≥ 1.4's focused terminal,
    ///     iTerm2's current session, Terminal.app's selected tab). Unlike the
    ///     AX seam this
    ///     DEFAULTS TO ABSTAIN, not to the live reader: an Apple event is not
    ///     an AX read — the first one triggers the Automation consent prompt,
    ///     and a defaulted live reader would send real events (and hang the
    ///     suite on that prompt) from any test that forgets to inject. The app
    ///     wires `AppleScriptTerminalTTYReader` explicitly.
    ///   - focusedBrowserTabURL: reads the focused window's active-tab URL for
    ///     an allowlisted browser over AppleScript. DEFAULTS TO ABSTAIN for the
    ///     same reason `focusedTerminalTTY` does — it sends a real Apple event
    ///     and can raise the Automation consent sheet — and additionally
    ///     because a browser tab URL is user CONTENT: no test may reach the
    ///     live reader by forgetting an injection. The app wires
    ///     `AppleScriptFocusedBrowserTabURLReader` explicitly.
    ///   - focusedWindowID: the join's window identity, from its own
    ///     PID-pinned AX read. It exists to pair a screen capture with the
    ///     join that authorized it; nil means unknown, which the authorizer
    ///     refuses rather than treats as a match (review F2).
    ///   - herdrClientProbe: reads the local process table to bind the focused
    ///     Ghostty surface to a herdr client. It DEFAULTS TO ABSTAIN: a test
    ///     that forgets to inject must never consult the live process table.
    ///     The app wires the live probe explicitly.
    ///   - herdrPanes: queries herdr's local JSON socket after that surface
    ///     binding succeeds. It likewise DEFAULTS TO ABSTAIN so a test that
    ///     forgets to inject cannot connect to a real user socket. The app is
    ///     the only place that installs the live client.
    ///   - cmuxSurfaces: queries cmux's control socket for the focused surface
    ///     and its text. DEFAULTS TO ABSTAIN (nil) for the same reason as
    ///     `herdrPanes`: no test may dial a real user's socket.
    ///   - cmuxJoinEnabled: the user's cmux opt-in, read live so turning the
    ///     toggle off stops the next dictation from dialing. DEFAULTS TO
    ///     ABSTAIN — a second, independent reason a forgetful test cannot reach
    ///     that socket.
    ///   - reportCmuxStatus: one short sentence for the Settings row when the
    ///     socket refuses us (details go to the log, never the popover).
    ///   - sshDestinationProbe: reads the local process table for an ssh client
    ///     on the focused surface's TTY and reports where it is going. Defaults
    ///     to `.undeterminable`, which disables the remote herdr arm entirely
    ///     — an un-injected resolver behaves exactly as it did before that arm
    ///     existed.
    ///   - enrolledHosts: the enrolled remote hosts whose ssh alias IS that
    ///     destination. Defaults to none, for the same reason: no enrollment
    ///     lookup, no remote arm. Passed as a closure rather than the registry
    ///     because the host list is built later in launch than this resolver.
    ///   - canonicalizedEnrolledHosts: the `ssh -G` fallback, consulted only
    ///     when exact alias matching found nothing. Defaults to none so a test
    ///     that forgets to inject never spawns a process.
    ///   - remoteHerdrForwards: opens the app-managed `ssh -L`. Nil means the
    ///     arm can never spawn anything, which is what a test that forgets to
    ///     inject must get.
    init(
        registry: ClaudeSessionRegistry,
        focusedTerminalTTY: @escaping (String) async -> String? = { _ in nil },
        focusedBrowserTabURL: @escaping (String) async -> String? = { _ in nil },
        focusedWindowID: @escaping (pid_t) -> CGWindowID? = {
            TerminalScreenAXReader.focusedWindowIdentity(applicationPID: $0)
        },
        herdrClientProbe: @escaping @Sendable (String) -> Bool = { _ in false },
        herdrPanes: HerdrPaneQuerying? = nil,
        cmuxSurfaces: CmuxSurfaceQuerying? = nil,
        cmuxJoinEnabled: @escaping @MainActor () -> Bool = { false },
        reportCmuxStatus: @escaping @MainActor (CmuxSocketStatus) -> Void = { _ in },
        sshDestinationProbe: @escaping @Sendable (String) -> SSHDestinationTTYProbeResult = { _ in
            .undeterminable(.probeUnavailable)
        },
        enrolledHosts: @escaping @MainActor (String) -> [ClaudeRemoteHost] = { _ in [] },
        canonicalizedEnrolledHosts: @escaping @MainActor (String) async -> [ClaudeRemoteHost] = {
            _ in []
        },
        speculativeHosts: @escaping @MainActor () -> [ClaudeRemoteHost] = { [] },
        remoteHerdrForwards: (any ClaudeRemoteHerdrForwarding)? = nil,
        herdrPanelMetadata: (any HerdrPanelMetadataReporting)? = nil,
        readFocusedGrid: @escaping HerdrPanelBindingProbe.GridRead = { _ in nil },
        panelNow: @escaping HerdrPanelBindingProbe.Now = Date.init,
        panelSleepFor: @escaping HerdrPanelBindingProbe.SleepFor = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        panelRandomBits: @escaping HerdrPanelBindingProbe.RandomBits = {
            var generator = SystemRandomNumberGenerator()
            return generator.next()
        },
        indicatorSleepFor: @escaping HerdrPanelMicIndicator.SleepFor = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        reportPanelStatus: @escaping @MainActor (HerdrPanelConfigurationStatus) -> Void = { _ in }
    ) {
        self.registry = registry
        self.focusedTerminalTTY = focusedTerminalTTY
        self.focusedBrowserTabURL = focusedBrowserTabURL
        self.focusedWindowID = focusedWindowID
        self.herdrClientProbe = herdrClientProbe
        self.herdrPanes = herdrPanes
        self.cmuxSurfaces = cmuxSurfaces
        self.cmuxJoinEnabled = cmuxJoinEnabled
        self.reportCmuxStatus = reportCmuxStatus
        self.sshDestinationProbe = sshDestinationProbe
        self.enrolledHosts = enrolledHosts
        self.canonicalizedEnrolledHosts = canonicalizedEnrolledHosts
        self.speculativeHosts = speculativeHosts
        self.remoteHerdrForwards = remoteHerdrForwards
        self.herdrPanelMetadata = herdrPanelMetadata
        self.readFocusedGrid = readFocusedGrid
        self.panelNow = panelNow
        self.panelSleepFor = panelSleepFor
        self.panelRandomBits = panelRandomBits
        self.indicatorSleepFor = indicatorSleepFor
        self.reportPanelStatus = reportPanelStatus
    }

    /// The join for `target`, or nil on any abstention.
    ///
    /// TTY first, then — on that same surface TTY — herdr when a herdr client
    /// holds it, and otherwise the remote-herdr arm. The TTY arm compares the
    /// focused pane's device against what the hook publisher reported from
    /// inside the session; the process table cannot be clobbered by whoever
    /// wrote the window title last, which is exactly why it, and not a title,
    /// is the primary evidence. A TTY non-answer does not fall through to some
    /// weaker reading of the same surface — there is no such reading — so the
    /// arms below it are the ones that ask a DIFFERENT question (an inner
    /// herdr pane, a cmux surface, a browser tab), and when none of them
    /// answers, the dictation gets no join.
    ///
    /// LOCAL sessions only, for every terminal arm: a remote session's TTY,
    /// pane id, or surface id names something on another machine, and
    /// `resolve(tty:)` refuses remote candidates outright so an SSH host can
    /// never claim a local pane by echoing its device. A remote session joins
    /// only through an arm that proves the remote binding itself — the
    /// remote-herdr pane arm, `cmux ssh`'s round-tripped surface id, or the
    /// bridge-allocated Remote Control session id.
    ///
    /// Whether the registry currently holds ANY live session.
    ///
    /// Not a join and not a step toward one: the overlay's join badge asks it
    /// to tell "nothing attached" apart from "there was nothing to attach", so
    /// a Mac that simply is not running Claude Code shows no badge instead of a
    /// permanent complaint. It reads no title, no TTY, no socket and no
    /// process table — it cannot influence, or be influenced by, what `resolve`
    /// decides.
    func hasLiveSessions() -> Bool {
        registry.hasLiveSessions()
    }

    /// This remains the only place a join is resolved, once per dictation, at
    /// start — whichever mechanism answers.
    func resolve(target: TerminalScreenTarget) async -> ClaudeSessionJoin? {
        // A browser is a different kind of target with a different capability:
        // one short URL string, no screen, no pane. The two allowlists are
        // disjoint (pinned by a test), so this branch and the terminal path
        // below can never both apply to one app.
        if BrowserTabAllowlist.isSupported(target.bundleID) {
            return await resolveViaBrowserTab(target: target)
        }
        // The allowlist is re-checked here even though the capture gate already
        // enforced it. This object is reachable independently of that gate, and
        // "only a terminal with a verified focused-pane surface" (Ghostty's
        // single-AXTextArea grid, iTerm2's current session, Terminal.app's
        // selected tab) is a precondition of reading this app at all — not
        // something to inherit on trust from a caller.
        guard TerminalScreenAllowlist.isSupported(target.bundleID) else { return nil }

        if let tty = await focusedTerminalTTY(target.bundleID) {
            switch registry.resolve(tty: tty) {
            case .resolved(let snapshot):
                Log.claudeContext.info(
                    "Terminal pane joined to a live Claude session via focused-pane tty"
                )
                // Without a window identity the authorizer cannot tell two
                // windows of one Ghostty process apart and must refuse raw
                // attachment (review F2). Read here, once, at join time.
                return ClaudeSessionJoin(
                    target: target,
                    snapshot: snapshot,
                    windowID: focusedWindowID(target.pid),
                    mechanism: .ttyDevice
                )
            case .unknown:
                abstainedTTYJoin(outcome: "no live session on this device")
            case .stale:
                abstainedTTYJoin(outcome: "stale")
            case .ambiguous:
                abstainedTTYJoin(outcome: "ambiguous")
            }

            // A focused surface positively bound to herdr describes an inner
            // pane, so only herdr can say which one: the arms below ask about
            // the outer surface and would answer about the wrong thing.
            if herdrClientProbe(tty) {
                return await resolveViaHerdr(target: target)
            }

            // The surface is not a local herdr client. It may still be an ssh
            // session into an enrolled host that is running one.
            switch await resolveViaRemoteHerdr(target: target, tty: tty) {
            case .joined(let join):
                return join
            case .declined:
                break
            }
        }

        // cmux has no AppleScript TTY reader, so the block above never answers
        // for it and this is where its surface arm runs.
        if TerminalScreenAllowlist.isSocketCaptureSupported(target.bundleID),
           let join = await resolveViaCmux(target: target) {
            return join
        }

        // Nothing identified the surface. There is no weaker reading to fall
        // back to, and that is the design: the alternative was a marker in the
        // window title, which every party in the stack (Claude Code, herdr,
        // cmux, the user) rewrites at will, so a lingering one could only
        // describe a session other than the one on screen.
        return nil
    }

    /// Outcome only, never the device path. A silent abstention here made a
    /// broken hook-side tty capture indistinguishable from a failed pane read
    /// in the field (2026-07-20): later arms may still answer, but the
    /// non-answer must say which side of the join went missing.
    private func abstainedTTYJoin(outcome: String) {
        Log.claudeContext.info(
            "Focused-pane tty matched no session (\(outcome, privacy: .public))"
        )
        Self.noteAbstention("tty: \(outcome)")
    }

    /// Where an abstention cause leaves this resolver as a value rather than as
    /// a log line (`HerdrPanelBindingProbe` has the one other such point).
    ///
    /// Both consumers are diagnostics — the dogfood capture record and
    /// `--probe-surface` — and both need the SAME string, so they read it from
    /// here rather than each deriving one. `cause` is already the content-free
    /// category the log line above carries; nothing else may be passed in.
    private static func noteAbstention(_ cause: String) {
        ClaudeJoinAbstentionTap.note(cause)
        #if LOCALVOXTRAL_DOGFOOD
        DogfoodCaptureTap.shared.noteJoinAbstention(cause)
        #endif
    }

    /// The browser arm: the focused tab's `claude.ai/code/session_…` URL
    /// matched, by exact equality, against the bridge session id a live
    /// session's own hooks published.
    ///
    /// Claude Code "Remote Control" runs the agent on a machine (this one, or a
    /// remote host over SSH) while the browser is its UI, so there is no pane,
    /// no TTY, and no title to join on — but since Claude Code 2.1.199 every
    /// hook subprocess of such a session carries
    /// `CLAUDE_CODE_BRIDGE_SESSION_ID`, whose value IS the `session_…`
    /// component of the URL in the address bar. That makes this the same kind
    /// of join as the TTY arm: two independent reports of one identifier,
    /// compared for equality, with no heuristic in between.
    ///
    /// Everything abstains rather than guesses, in particular: a tab that is
    /// not a Claude Code session URL (the user is reading docs), an id no live
    /// session reports (the Remote Control connection ended, or that session is
    /// on a machine we have no hooks from), and two sessions reporting one id.
    private func resolveViaBrowserTab(target: TerminalScreenTarget) async -> ClaudeSessionJoin? {
        guard let tabURL = await focusedBrowserTabURL(target.bundleID) else {
            Self.abstainedBrowserTabJoin(outcome: "focused tab url unavailable")
            return nil
        }
        guard let bridgeSessionID = ClaudeBridgeSessionURL.sessionID(inTabURL: tabURL) else {
            // Never the URL itself: it names a page the user is looking at.
            Self.abstainedBrowserTabJoin(outcome: "focused tab is not a Claude Code session")
            return nil
        }

        switch registry.resolve(bridgeSessionID: bridgeSessionID) {
        case .resolved(let snapshot):
            Log.claudeContext.info(
                "Browser tab joined to a live Claude session via Remote Control bridge session id"
            )
            return ClaudeSessionJoin(
                target: target,
                snapshot: snapshot,
                // Deliberately nil. A window identity exists to pair a SCREEN
                // capture with the join that authorized it, and there is no
                // screen route for a browser — the authorizer refuses this
                // mechanism outright. Supplying one would imply a raw read we
                // never make (and cost an AX round trip to say so).
                windowID: nil,
                mechanism: .browserTab,
                browserTab: ClaudeBrowserTabBinding(bridgeSessionID: bridgeSessionID)
            )
        case .unknown:
            Self.abstainedBrowserTabJoin(outcome: "no live session reports this bridge session")
            return nil
        case .stale:
            Self.abstainedBrowserTabJoin(outcome: "stale")
            return nil
        case .ambiguous:
            Self.abstainedBrowserTabJoin(outcome: "ambiguous")
            return nil
        }
    }

    /// Outcome only. A bridge session id is a live handle to a session's
    /// context and a tab URL is page content; neither belongs in the log.
    private static func abstainedBrowserTabJoin(outcome: String) {
        Log.claudeContext.info(
            "Browser tab matched no session (\(outcome, privacy: .public)); Claude context withheld"
        )
        Self.noteAbstention("browserTab: \(outcome)")
    }

    private func resolveViaHerdr(target: TerminalScreenTarget) async -> ClaudeSessionJoin? {
        let sockets = registry.liveLocalHerdrSocketPaths()
        guard sockets.count == 1, let socketPath = sockets.first else {
            Self.abstainedHerdrJoin(
                outcome: sockets.isEmpty ? "no live registered socket" : "multiple live sockets"
            )
            return nil
        }
        guard let herdrPanes else {
            Self.abstainedHerdrJoin(outcome: "pane query capability unavailable")
            return nil
        }
        guard let pane = await herdrPanes.focusedPane(socketPath: socketPath) else {
            Self.abstainedHerdrJoin(outcome: "focused pane unavailable")
            return nil
        }

        let snapshot: ClaudeSessionSnapshot
        switch registry.resolve(herdrPaneID: pane.paneID) {
        case .resolved(let resolved):
            snapshot = resolved
        case .unknown:
            Self.abstainedHerdrJoin(outcome: "focused pane has no live session")
            return nil
        case .stale:
            Self.abstainedHerdrJoin(outcome: "focused pane session stale")
            return nil
        case .ambiguous:
            Self.abstainedHerdrJoin(outcome: "focused pane session ambiguous")
            return nil
        }

        // herdr reports the agent's RAW session id; the registry speaks
        // agent-scoped ids (`ClaudeAgentSessionScope`). Scope the claim by the
        // resolved session's own agent before comparing — for Claude that is
        // the identity function, for opencode it adds the same prefix ingest
        // did. Scoping by the snapshot's agent (not by anything herdr says)
        // keeps this a pure cross-check: a claim can only ever CONFIRM the
        // pane-id join, never redirect it.
        if let claimed = pane.claimedClaudeSessionID,
           ClaudeAgentSessionScope.scopedSessionID(
               agent: snapshot.agent, sessionID: claimed
           ) != snapshot.sessionID {
            Self.abstainedHerdrJoin(outcome: "pane session claim disagrees")
            return nil
        }
        guard let foreground = await herdrPanes.paneForegroundInfo(
            socketPath: socketPath, paneID: pane.paneID
        ) else {
            Self.abstainedHerdrJoin(outcome: "foreground process query unavailable")
            return nil
        }
        guard let foregroundPIDs = foreground.foregroundPIDs else {
            Self.abstainedHerdrJoin(outcome: "foreground process detection unavailable")
            return nil
        }
        guard Self.registeredAgentIsForeground(
            snapshot: snapshot, foregroundPIDs: foregroundPIDs
        ) else { return nil }

        Log.claudeContext.info("Terminal pane joined to a live Claude session via herdr pane")
        return ClaudeSessionJoin(
            target: target,
            snapshot: snapshot,
            windowID: focusedWindowID(target.pid),
            mechanism: .herdrPane,
            herdrPane: ClaudeHerdrPaneBinding(paneID: pane.paneID, socketPath: socketPath)
        )
    }

    /// What the remote herdr arm concluded.
    ///
    /// One decline, not three. The arm used to distinguish "nothing here is
    /// about a remote herdr" from "this surface IS an enrolled host's herdr
    /// and the join still failed" (and a third case for an ssh present but
    /// unreadable) because those three chose differently between falling
    /// through to a window-title marker and stopping the dictation's join
    /// dead. With no title arm left there is nothing to fall through TO, so
    /// every non-join is one answer: this arm has no session for you. The
    /// CAUSES stay distinct — each decline still logs and taps its own
    /// content-free string, which is what the dogfood record and
    /// `--probe-surface` read.
    enum RemoteHerdrArmOutcome {
        case declined
        case joined(ClaudeSessionJoin)
    }

    /// A Claude Code session inside a herdr on an ENROLLED REMOTE host.
    ///
    /// The agents-panel nonce is the primary surface authorization. A readable
    /// ssh destination narrows it to one enrolled host; otherwise up to three
    /// live herdr-bearing hosts are tried. Only when that proof cannot render
    /// does the pre-existing argv path below become the fallback.
    ///
    /// The fallback bindings, all required, remain:
    /// 1. the focused surface's TTY hosts EXACTLY ONE foreground ssh session,
    ///    whose destination is exactly one enrolled host's alias. One, because
    ///    several in a group cannot be told apart from here and unioning them
    ///    let a plain connection borrow a sibling's herdr signal (round 7).
    ///    This is the only step that says anything about what the user is
    ///    looking at;
    /// 2. that CONNECTION is bound to herdr, and it takes BOTH facts: the ssh
    ///    argv names herdr as its remote command (first token), AND this
    ///    terminal holds the only ssh connection to that destination on the
    ///    machine. Neither alone is enough — uniqueness does not say what the
    ///    terminal DISPLAYS (a detached herdr still answers `pane.current`),
    ///    and argv is written by whoever launched the process;
    /// 3. that host has live sessions reporting a herdr pane, all from ONE herdr
    ///    socket. This counts SOCKETS, not sessions: several live sessions on
    ///    one herdr are expected and fine — panes are what a multiplexer is for
    ///    — and it is two herdr SERVERS that leave the surface ambiguous;
    /// 4. over the forward, exactly ONE of those candidates claims that herdr's
    ///    FOCUSED pane id (two claiming the same pane id abstain);
    /// 5. herdr's own session claim for the pane does not disagree, and the pane
    ///    is running that session's agent.
    ///
    /// Every one of these can only ever CONFIRM. No step picks a session because
    /// it is the only one, the most recent, or the one whose cwd looks right.
    private func resolveViaRemoteHerdr(
        target: TerminalScreenTarget,
        tty: String
    ) async -> RemoteHerdrArmOutcome {
        let sshResult = sshDestinationProbe(tty)

        // PRIMARY authorization: stamp each plausible server with a fresh
        // nonce and require that exact value in the focused terminal grid.
        // argv is consulted only after this direct surface proof fails.
        if let panelOutcome = await resolveViaRemoteHerdrPanel(
            target: target,
            sshResult: sshResult
        ) {
            return panelOutcome
        }

        let connection: SSHSurfaceConnection
        switch sshResult {
        case .noSSHClient:
            // The overwhelmingly common case: a local shell. Not logged — this
            // is not an abstention, it is the arm not applying.
            return .declined
        case .undeterminable(let cause):
            // The category is content-free by type (`SSHProbeIndeterminacy` —
            // never a host, path, or option), so it may ride into the log and
            // the dogfood record. Three field dictations were diagnosed blind
            // without it (2026-08-06).
            Self.abstainedRemoteHerdrJoin(outcome: "ssh session undeterminable (\(cause.rawValue))")
            return .declined
        case .connection(let value):
            connection = value
        }

        var hosts = enrolledHosts(connection.destination)
        if hosts.isEmpty {
            hosts = await canonicalizedEnrolledHosts(connection.destination)
        }
        guard !hosts.isEmpty else {
            // An ssh session to a host the user never enrolled. There is no
            // context to join.
            return .declined
        }
        guard hosts.count == 1, let host = hosts.first, let alias = host.sshHostAlias else {
            Self.abstainedRemoteHerdrJoin(outcome: "ssh destination matches multiple enrolled hosts")
            return .declined
        }

        let candidates = registry.liveRemoteHerdrSessions(hostID: host.id)
        guard !candidates.isEmpty else {
            // Enrolled, but nothing on it reported a herdr pane — a plain
            // remote Claude session, which this arm cannot speak for.
            return .declined
        }
        let socketPaths = Set(candidates.compactMap { $0.remoteSessionEnvironment?.herdrSocketPath })
        guard socketPaths.count == 1, let remoteSocketPath = socketPaths.first else {
            // Mirror of the local single-socket rule: two herdr servers on one
            // host, and no way to tell which one the surface is attached to.
            Self.abstainedRemoteHerdrJoin(outcome: "multiple live herdr sockets on this host")
            return .declined
        }

        // The connection-level bind: this connection's own argv must be a
        // plain herdr whole-view client, and no OTHER connection may be a
        // competing herdr view of the same destination.
        //
        // The invocation requirement is the round-5b lesson unchanged: a herdr
        // whose client detached — or whose pane still runs an agent inside the
        // registry TTL — keeps answering
        // `pane.current`, so being the sole `ssh builder` proves nothing about
        // what this terminal DISPLAYS. herdr exposes no read-only attachment
        // signal (re-verified at v0.8.0 / protocol 19, 2026-08-06: the only
        // `client.*` methods are still `window_title.set`/`clear`, both
        // mutations, and `session.snapshot` has no client records), so the
        // evidence has to come from the invocation — the exec-time argv of a
        // VERIFIED OpenSSH binary, i.e. the command ssh actually ran.
        //
        // The competing-client rule REPLACED machine-wide uniqueness
        // (2026-08-06), on a protocol fact verified in herdr's source: focus
        // is server-global and multi-client attach is a mirror, so a plain
        // shell to the same host cannot be displaying "our" herdr, and a
        // second whole-view client of the SAME server displays the same
        // focused pane — joining is correct for both. What still blocks is a
        // possible client of a DIFFERENT herdr view: another session selector,
        // a single-pane attach, or an argv unreadable enough to be either.
        //
        // The residual cost after panel fallback: a manual `ssh host`, then
        // `herdr` flow still gets no join at all when the sidebar row cannot
        // render (collapsed/narrow/covered/unconfigured), because its argv has
        // no remote command and no other arm can see inside that connection.
        // The surface's own classification first: when the surface argv is the
        // problem, the log must say so — a competing neighbor may exist too,
        // and reporting it instead buried the actionable cause (review nit,
        // 2026-08-06).
        switch connection.herdr {
        case .notHerdr:
            Self.abstainedRemoteHerdrJoin(
                outcome: "the ssh command on this terminal is not herdr itself"
            )
            return .declined
        case .otherHerdrSubcommand:
            // `herdr terminal attach <id>` renders ONE pane and
            // `herdr --session <x>` in a shape we could not normalize may be
            // another server entirely — while the join would read the
            // candidates' server-global focus. Joining would pair the prompt
            // with a pane the user is not looking at.
            Self.abstainedRemoteHerdrJoin(
                outcome: "this terminal attaches a partial or different herdr view"
            )
            return .declined
        case .plainClient:
            break
        }
        guard !connection.hasCompetingHerdrClient else {
            Self.abstainedRemoteHerdrJoin(
                outcome: "another terminal may hold a different herdr view of this destination"
            )
            return .declined
        }

        guard let remoteHerdrForwards else {
            Self.abstainedRemoteHerdrJoin(outcome: "forward capability unavailable")
            return .declined
        }
        guard let herdrPanes else {
            Self.abstainedRemoteHerdrJoin(outcome: "pane query capability unavailable")
            return .declined
        }
        guard let forward = await remoteHerdrForwards.open(
            alias: alias, remoteSocketPath: remoteSocketPath
        ) else {
            Self.abstainedRemoteHerdrJoin(outcome: "forward unavailable")
            return .declined
        }

        if let join = await resolveRemoteHerdrPane(
            target: target,
            hostID: host.id,
            candidates: candidates,
            forward: forward,
            herdrPanes: herdrPanes
        ) {
            Log.claudeContext.info(
                "Terminal pane joined to a live Claude session via remote herdr pane"
            )
            return .joined(join)
        }
        forward.close()
        return .declined
    }

    private struct PanelCandidateMatch {
        let host: ClaudeRemoteHost
        let pane: HerdrFocusedPane
        let snapshot: ClaudeSessionSnapshot
        let forward: ClaudeRemoteHerdrForwardHandle
        let token: String
    }

    /// Returns nil only when the panel did not authorize any server, which is
    /// the one condition that permits the argv fallback below it.
    private func resolveViaRemoteHerdrPanel(
        target: TerminalScreenTarget,
        sshResult: SSHDestinationTTYProbeResult
    ) async -> RemoteHerdrArmOutcome? {
        guard let herdrPanes,
              let remoteHerdrForwards,
              let herdrPanelMetadata
        else { return nil }

        let selectedHosts: [ClaudeRemoteHost]
        let speculative: Bool
        switch sshResult {
        case .connection(let connection):
            let matching = enrolledHosts(connection.destination).filter {
                !$0.isRevoked && $0.sshHostAlias != nil
            }
            guard matching.count == 1 else { return nil }
            selectedHosts = matching
            speculative = false
        case .noSSHClient:
            // A surface with NO ssh at all is a local shell — the
            // overwhelmingly common dictation target. It must not pay remote
            // latency (a cold forward per candidate host) and must not flash
            // a nonce in remote panels the user is not looking at, so it
            // never probes. The cost: a nested wrapper whose inner ssh lives
            // on another pty (tmux) stays unjoinable until a warm-forward
            // speculative mode exists.
            return nil
        case .undeterminable:
            // An ssh IS present but its argv cannot be read (a wrapper the
            // parser refuses). That is a strong prior that the surface shows
            // a remote session, so plausible servers are probed. Registry
            // liveness bounds the candidates, and the hard prefix keeps one
            // join from opening an unbounded number of forwards.
            selectedHosts = Array(speculativeHosts().filter { host in
                !host.isRevoked
                    && host.sshHostAlias != nil
                    && !registry.liveRemoteHerdrSessions(hostID: host.id).isEmpty
            }.prefix(3))
            speculative = true
        }
        guard !selectedHosts.isEmpty else { return nil }

        let probe = HerdrPanelBindingProbe(
            metadata: herdrPanelMetadata,
            readGrid: readFocusedGrid,
            now: panelNow,
            sleepFor: panelSleepFor,
            randomBits: panelRandomBits
        )
        var matches: [PanelCandidateMatch] = []

        for host in selectedHosts {
            guard let alias = host.sshHostAlias else { continue }
            let candidates = registry.liveRemoteHerdrSessions(hostID: host.id)
            // Two live sockets on one host used to abstain outright (the argv
            // fallback still does — it has no way to tell the servers apart).
            // The nonce CAN tell them apart: each socket is stamped with its
            // own fresh token, and only the server this surface displays can
            // render its token. A stale socket — a session registered under a
            // previous herdr boot, inside the registry TTL — simply fails its
            // forward and is skipped (field abstention 2026-08-09). Sorted for
            // determinism; bounded like the host prefix.
            let socketPaths = Set(candidates.compactMap {
                $0.remoteSessionEnvironment?.herdrSocketPath
            }).sorted().prefix(3)

            socketLoop: for remoteSocketPath in socketPaths {
                let socketCandidates = candidates.filter {
                    $0.remoteSessionEnvironment?.herdrSocketPath == remoteSocketPath
                }
                guard let forward = await remoteHerdrForwards.open(
                    alias: alias,
                    remoteSocketPath: remoteSocketPath
                ) else {
                    let cause: HerdrPanelBindingAbstention = speculative
                        ? .speculativeForwardUnavailable : .forwardUnavailable
                    HerdrPanelBindingProbe.noteAbstention(cause)
                    continue
                }

                let socketPath = forward.localSocketPath
                guard let pane = await herdrPanes.focusedPane(socketPath: socketPath) else {
                    Self.abstainedRemoteHerdrJoin(outcome: "panel candidate focused pane unavailable")
                    forward.close()
                    continue
                }
                let paneMatches = socketCandidates.filter {
                    $0.remoteSessionEnvironment?.herdrPaneID == pane.paneID
                }
                guard paneMatches.count == 1, let snapshot = paneMatches.first else {
                    Self.abstainedRemoteHerdrJoin(
                        outcome: paneMatches.isEmpty
                            ? "panel candidate focused pane has no live session"
                            : "panel candidate focused pane is ambiguous"
                    )
                    forward.close()
                    continue
                }

                switch await probe.probe(
                    target: target,
                    socketPath: socketPath,
                    paneID: pane.paneID
                ) {
                case .matched(let match):
                    matches.append(PanelCandidateMatch(
                        host: host,
                        pane: pane,
                        snapshot: snapshot,
                        forward: forward,
                        token: match.token
                    ))
                    // One grid renders exactly one server's panel, and the
                    // forward service holds one entry per host — opening the
                    // NEXT socket would tear down this matched forward. First
                    // match ends the socket loop; the cross-HOST double-match
                    // abstention below is untouched.
                    break socketLoop
                case .noMatch(let cause):
                    HerdrPanelBindingProbe.noteAbstention(cause)
                    // Only a destination-known SINGLE-socket probe may
                    // diagnose the row: with a speculative host or a second
                    // socket in play, a token not rendering usually means the
                    // user is not looking at THAT server, not that its config
                    // is missing.
                    if cause == .settleTimeout, !speculative, socketPaths.count == 1 {
                        reportPanelStatus(.likelyNotConfigured)
                        // Named as CANDIDATES, not as a finding. A stamped
                        // token that did not render has at least four causes
                        // and this side cannot tell them apart (herdr exposes
                        // no client introspection and no config read), so
                        // asserting the first one sends the user to change a
                        // row that is often already correct — measured twice
                        // on 2026-09-05, once where the real cause was column
                        // truncation and once where the agent entry did not
                        // fit an 80x24 client. The grid geometry logged by
                        // `noteRowNotRendered` is the fact that separates them.
                        Log.claudeContext.info(
                            "Remote herdr panel token was stamped but did not render; check the agents-panel row config, the sidebar width, and whether the entry fits this client's height"
                        )
                    }
                    // A truncated row is the OPPOSITE diagnosis: the row is
                    // configured and rendering, and herdr cut the token to the
                    // sidebar's column budget. Saying "likely not configured"
                    // here sends the user to change the one thing that is
                    // already right (field abstention 2026-09-05).
                    if cause == .rowTruncated {
                        Log.claudeContext.info(
                            "Remote herdr panel row rendered a TRUNCATED token; widen the herdr sidebar or make the $lvmark row the agent entry's first row"
                        )
                    }
                    await HerdrPanelBindingProbe.clear(
                        metadata: herdrPanelMetadata,
                        socketPath: socketPath,
                        paneID: pane.paneID
                    )
                    forward.close()
                }
            }
        }

        if !matches.isEmpty { reportPanelStatus(.ok) }
        guard matches.count <= 1 else {
            HerdrPanelBindingProbe.noteAbstention(.multiHostDoubleMatch)
            for match in matches {
                await HerdrPanelBindingProbe.clear(
                    metadata: herdrPanelMetadata,
                    socketPath: match.forward.localSocketPath,
                    paneID: match.pane.paneID
                )
                match.forward.close()
            }
            return .declined
        }
        guard let match = matches.first else { return nil }

        return await confirmPanelAuthorizedRemoteHerdr(
            target: target,
            match: match,
            metadata: herdrPanelMetadata,
            herdrPanes: herdrPanes
        )
    }

    private func confirmPanelAuthorizedRemoteHerdr(
        target: TerminalScreenTarget,
        match: PanelCandidateMatch,
        metadata: any HerdrPanelMetadataReporting,
        herdrPanes: HerdrPaneQuerying
    ) async -> RemoteHerdrArmOutcome {
        let pane = match.pane
        let snapshot = match.snapshot
        let socketPath = match.forward.localSocketPath

        func refuse(_ outcome: String) async -> RemoteHerdrArmOutcome {
            Self.abstainedRemoteHerdrJoin(outcome: outcome)
            await HerdrPanelBindingProbe.clear(
                metadata: metadata,
                socketPath: socketPath,
                paneID: pane.paneID
            )
            match.forward.close()
            return .declined
        }

        // The pane-level confirmation set, unchanged in substance now that the
        // pane title is not consulted: the caller already established that
        // EXACTLY ONE live candidate of this socket claims the focused pane id
        // (`paneMatches.count == 1` above), and the two fail-closed
        // cross-checks below are what stop a REUSED pane — a session that died
        // without a SessionEnd leaves a live registry entry and its pane id
        // behind, and herdr, which watches the pane, is the party that can
        // contradict it.
        if let claimed = pane.claimedClaudeSessionID,
           Self.scopedRemoteSessionID(
               claimed: claimed, hostID: match.host.id, agent: snapshot.agent
           ) != snapshot.sessionID {
            return await refuse("pane session claim disagrees")
        }
        guard let foreground = await herdrPanes.paneForegroundInfo(
            socketPath: socketPath, paneID: pane.paneID
        ) else { return await refuse("foreground process query unavailable") }
        guard let processes = foreground.foregroundProcesses else {
            return await refuse("foreground process detection unavailable")
        }
        guard Self.remoteAgentIsForeground(
            snapshot: snapshot,
            foregroundProcesses: processes
        ) else { return await refuse("registered remote agent is not foreground") }

        let indicator = HerdrPanelMicIndicator(
            metadata: metadata,
            socketPath: socketPath,
            paneID: pane.paneID,
            token: match.token,
            forward: match.forward,
            sleepFor: indicatorSleepFor
        )
        Log.claudeContext.info(
            "Terminal pane joined to a live Claude session via remote herdr agents-panel binding"
        )
        return .joined(ClaudeSessionJoin(
            target: target,
            snapshot: snapshot,
            windowID: focusedWindowID(target.pid),
            mechanism: .remoteHerdrPane,
            herdrPane: ClaudeHerdrPaneBinding(paneID: pane.paneID, socketPath: socketPath),
            remoteHerdrForward: match.forward,
            remoteHerdrIndicator: indicator
        ))
    }

    /// The over-the-forward half: the focused pane, then the fail-closed
    /// cross-checks. Split out so the caller has exactly one `forward.close()`
    /// on the failure path. Nil is the only failure answer — with no title arm
    /// underneath, "nothing was established yet" and "something was, and a
    /// later check refused it" reach the same place.
    private func resolveRemoteHerdrPane(
        target: TerminalScreenTarget,
        hostID: String,
        candidates: [ClaudeSessionSnapshot],
        forward: ClaudeRemoteHerdrForwardHandle,
        herdrPanes: HerdrPaneQuerying
    ) async -> ClaudeSessionJoin? {
        let socketPath = forward.localSocketPath
        guard let pane = await herdrPanes.focusedPane(socketPath: socketPath) else {
            Self.abstainedRemoteHerdrJoin(outcome: "focused pane unavailable")
            return nil
        }
        // The precondition, stated precisely because a loose reading of it drew
        // a review finding: exactly one candidate for the FOCUSED PANE ID —
        // NOT one candidate per socket. Several live sessions on one herdr are
        // expected and fine; that is what a multiplexer is for, and it is the
        // case this arm exists to serve. What abstains is two candidates
        // claiming the SAME pane id, which is the only shape that would force a
        // choice. Nothing here picks: the survivor still has to be confirmed
        // by herdr's own session claim and by the foreground process below.
        let matches = candidates.filter {
            $0.remoteSessionEnvironment?.herdrPaneID == pane.paneID
        }
        guard matches.count == 1, let snapshot = matches.first else {
            Self.abstainedRemoteHerdrJoin(
                outcome: matches.isEmpty
                    ? "focused pane has no live session"
                    : "two live sessions claim the focused pane id"
            )
            return nil
        }

        // herdr's OWN claim about the pane, fail-closed exactly like the local
        // arm's (`resolveViaHerdr`). This is the check that catches a reused
        // pane: session A dies without a SessionEnd, leaving a live registry
        // entry and its pane id behind; session B starts in that same pane.
        // The pane id still names A, and herdr — which watches the pane —
        // says B. A disagreement resolves to NEITHER (review finding 3).
        //
        // Scoped by the session's own host and agent before comparing, never by
        // anything herdr says, so a claim can only ever CONFIRM the pane-id
        // join and never redirect it.
        if let claimed = pane.claimedClaudeSessionID,
           Self.scopedRemoteSessionID(
               claimed: claimed, hostID: hostID, agent: snapshot.agent
           ) != snapshot.sessionID {
            Self.abstainedRemoteHerdrJoin(outcome: "pane session claim disagrees")
            return nil
        }

        guard let foreground = await herdrPanes.paneForegroundInfo(
            socketPath: socketPath, paneID: pane.paneID
        ) else {
            Self.abstainedRemoteHerdrJoin(outcome: "foreground process query unavailable")
            return nil
        }
        guard let processes = foreground.foregroundProcesses else {
            Self.abstainedRemoteHerdrJoin(outcome: "foreground process detection unavailable")
            return nil
        }
        guard Self.remoteAgentIsForeground(snapshot: snapshot, foregroundProcesses: processes) else {
            return nil
        }

        return ClaudeSessionJoin(
            target: target,
            snapshot: snapshot,
            windowID: focusedWindowID(target.pid),
            mechanism: .remoteHerdrPane,
            herdrPane: ClaudeHerdrPaneBinding(paneID: pane.paneID, socketPath: socketPath),
            remoteHerdrForward: forward
        )
    }

    /// A raw session id as herdr reports it, in the registry's namespace.
    ///
    /// Two scopings apply to a remote session and both are recomputed here from
    /// facts WE hold (the authenticating host, the snapshot's agent) rather than
    /// from anything on the wire: the remote listener namespaces by host id, and
    /// the registry then namespaces by agent. For Claude the second is the
    /// identity function; for opencode it adds the same prefix ingest did.
    static func scopedRemoteSessionID(
        claimed: String,
        hostID: String,
        agent: ClaudeHookAgent
    ) -> String {
        ClaudeAgentSessionScope.scopedSessionID(
            agent: agent,
            sessionID: ClaudeRemoteSessionScope.scopedSessionID(
                hostID: hostID, sessionID: claimed
            )
        )
    }

    /// Is the joined pane actually running that session's agent right now?
    ///
    /// The local arm answers this with a pid, which a remote pane cannot: its
    /// numbers live in another machine's namespace. Two signals replace it, and
    /// EITHER is sufficient while NEITHER is optional:
    ///
    /// * the session's reported `hookParentPID` (the remote shim's `$PPID`) is
    ///   one of the pane's foreground pids — compared as STRINGS, because that
    ///   value is a label and must never become a number this process could
    ///   probe;
    /// * a foreground process is NAMED for the session's agent.
    ///
    /// Requiring both, as first designed, would have failed closed forever on
    /// two ordinary installs: `$PPID` is the shim's parent, which is the shell
    /// Claude Code spawns hooks through rather than Claude Code itself, and an
    /// npm-installed Claude Code appears in the process table as `node`. Either
    /// signal alone still proves the pane is running the session — and neither
    /// present (a suspended agent with the user back at the shell, the case
    /// this check exists for) still abstains.
    static func remoteAgentIsForeground(
        snapshot: ClaudeSessionSnapshot,
        foregroundProcesses: [HerdrForegroundProcess]
    ) -> Bool {
        if let hookParentPID = snapshot.remoteSessionEnvironment?.hookParentPID,
           foregroundProcesses.contains(where: { String($0.pid) == hookParentPID }) {
            return true
        }
        let agentName = snapshot.agent.rawValue
        if foregroundProcesses.contains(where: { process in
            guard let name = process.name else { return false }
            return (name as NSString).lastPathComponent == agentName
        }) {
            return true
        }
        abstainedRemoteHerdrJoin(
            outcome: "no foreground process matches the registered \(snapshot.agent.rawValue) session"
        )
        return false
    }

    /// Outcome only. Pane ids, socket paths, ssh destinations, and titles are
    /// all live join material — and the destination additionally names the
    /// user's infrastructure, which the unified log is emphatically not the
    /// place for.
    private static func abstainedRemoteHerdrJoin(outcome: String) {
        Log.claudeContext.info(
            "Remote herdr pane matched no session (\(outcome, privacy: .public)); Claude context withheld"
        )
        Self.noteAbstention("remote-herdr: \(outcome)")
    }

    /// The joined herdr pane's visible text, or nil on any refusal or failure.
    ///
    /// This is the ONLY path that issues a `pane.read`, and it can only read
    /// the pane the join resolved to: the request is keyed by the binding the
    /// herdr arm captured at resolution time, so no other pane — and no other
    /// join mechanism — can reach herdr's socket through it. The returned text
    /// is RAW wire text; the caller owns sanitization, bounding, and every
    /// consent gate (see `SocketPaneScreenContext`).
    func herdrPaneVisibleText(for join: ClaudeSessionJoin) async -> String? {
        guard join.mechanism == .herdrPane || join.mechanism == .remoteHerdrPane,
              let binding = join.herdrPane
        else {
            Log.claudeContext.info("Herdr pane read refused: join is not a herdr pane join")
            return nil
        }
        guard let herdrPanes else {
            Log.claudeContext.info("Herdr pane read refused: pane query capability unavailable")
            return nil
        }
        return await herdrPanes.paneVisibleText(
            socketPath: binding.socketPath, paneID: binding.paneID
        )
    }

    /// Pure pid cross-check kept visible to tests because a snapshot with no
    /// process cannot be produced by a successful pane-id registry lookup, but
    /// the resolver must still fail closed if that invariant ever changes.
    /// Agent-neutral (review F3): the pane may host Claude Code or opencode,
    /// and the registered pid is whichever agent process the session's records
    /// named — the abstention wording must not claim Claude for both.
    static func registeredAgentIsForeground(
        snapshot: ClaudeSessionSnapshot,
        foregroundPIDs: [Int32]
    ) -> Bool {
        guard let process = snapshot.process else {
            abstainedHerdrJoin(outcome: "registered session has no process metadata")
            return false
        }
        guard foregroundPIDs.contains(process.claudePID) else {
            abstainedHerdrJoin(
                outcome: "registered \(snapshot.agent.rawValue) process is not foreground"
            )
            return false
        }
        return true
    }

    /// Outcome only: pane ids, socket paths, tty paths, and payload contents are
    /// all live join material and never belong in the unified log.
    private static func abstainedHerdrJoin(outcome: String) {
        Log.claudeContext.info(
            "Herdr pane matched no session (\(outcome, privacy: .public)); Claude context withheld"
        )
        Self.noteAbstention("herdr: \(outcome)")
    }

    /// The cmux arm: bind the FOCUSED cmux surface to a live session by the
    /// surface id cmux itself injected into that session's environment.
    ///
    /// cmux mints `CMUX_SURFACE_ID` and puts it in the surface's process
    /// environment — and, through its own ssh relay, in the environment of a
    /// `cmux ssh` shell on another host. So the same id can come back to us from
    /// two different transports, and this arm accepts both:
    ///
    /// * LOCAL: the id arrived in `process` over the peer-UID-authenticated
    ///   AF_UNIX socket. Where both sides know a tty, they must agree — a free
    ///   cross-check that costs nothing and catches a stale environment.
    /// * REMOTE: the id arrived as an `X-Lvx-Env-*` header over the enrolled
    ///   host's authenticated channel. Nothing local is read for it; the join
    ///   only unlocks that session's own prompt/excerpts, and
    ///   `localWorkspacePath` still refuses to hand a remote cwd to the
    ///   filesystem. A compromised enrolled host could replay a surface id and
    ///   claim the focused pane — bounded by enrollment the user can revoke,
    ///   and additionally by the fresh remote-hosted evidence below.
    ///
    /// `CMUX_WORKSPACE_ID` is deliberately never consulted: cmux regenerates it
    /// when a workspace is restored, so a join keyed on it would silently start
    /// pointing at nothing after a relaunch.
    private func resolveViaCmux(target: TerminalScreenTarget) async -> ClaudeSessionJoin? {
        guard cmuxJoinEnabled() else {
            Self.abstainedCmuxJoin(outcome: "cmux join not enabled")
            return nil
        }
        guard let cmuxSurfaces else {
            Self.abstainedCmuxJoin(outcome: "surface query capability unavailable")
            return nil
        }

        let surface: CmuxFocusedSurface
        // The peer the socket must turn out to be: the frontmost cmux process
        // this join is already about. The client refuses to send the stored
        // password to anything else.
        switch await cmuxSurfaces.focusedSurface(expectedPeerPID: target.pid) {
        case .value(let focused):
            surface = focused
        case .authenticationRequired:
            // The one failure the user can fix, so it is the one failure that
            // gets a sentence in Settings instead of only a log line.
            reportCmuxStatus(.authenticationRequired)
            Self.abstainedCmuxJoin(outcome: "socket requires password mode")
            return nil
        case .unavailable:
            reportCmuxStatus(.unavailable)
            Self.abstainedCmuxJoin(outcome: "focused surface unavailable")
            return nil
        }
        reportCmuxStatus(.ok)

        let local = registry.resolve(cmuxSurfaceID: surface.surfaceID)
        let remote = registry.resolveRemote(cmuxSurfaceID: surface.surfaceID)

        // EXACTLY ONE side may have a candidate at all, and it must be a clean
        // `.resolved` while the other is a clean `.unknown`.
        //
        // The earlier rule only rejected `.resolved`/`.resolved`, which made
        // ambiguity asymmetric: two local sessions claiming the surface
        // (`.ambiguous`) next to one remote claim would fall through and join
        // the REMOTE one, and the mirror image joined the local one. Ambiguity
        // on either side is the registry saying it cannot name the session, and
        // a claim from the other origin is not the tie-breaker — it is a
        // different machine answering a question about this surface.
        // `.stale` is treated the same way: a dead claimant on one side is
        // evidence the surface changed hands, which is exactly when the other
        // side's claim deserves the least trust.
        guard Self.isCleanlyResolved(local, other: remote)
            || Self.isCleanlyResolved(remote, other: local)
        else {
            Self.abstainedCmuxJoin(outcome: Self.cmuxOutcome(local: local, remote: remote))
            return nil
        }

        if case .resolved(let snapshot) = local {
            // Belt and braces, and REQUIRED on both sides: the surface's tty
            // and the session's must both be known and equal.
            //
            // Treating an absent tty as "no evidence, carry on" waived the
            // check precisely when it was needed — a process that inherited a
            // stale `CMUX_SURFACE_ID` and then moved to another pane publishes
            // no tty we can contradict, so id-alone would join it to whatever
            // surface now carries that id. Absent evidence is not permission.
            //
            // Cost, stated plainly: a session whose publisher reports no tty
            // cannot join over this arm. That is every opencode session (its
            // server half deliberately publishes no tty, because it cannot
            // prove it owns a pane), so opencode inside cmux gets no join at
            // all. A missed join costs an excerpt; a wrong one puts another
            // session's screen in this prompt.
            guard let sessionTTY = snapshot.process?.tty else {
                Self.abstainedCmuxJoin(outcome: "session published no tty to cross-check")
                return nil
            }
            guard let surfaceTTY = surface.tty else {
                Self.abstainedCmuxJoin(outcome: "cmux reported no tty for the focused surface")
                return nil
            }
            guard sessionTTY == surfaceTTY else {
                Self.abstainedCmuxJoin(outcome: "surface tty disagrees with the session's tty")
                return nil
            }
            Log.claudeContext.info(
                "Terminal pane joined to a live local Claude session via cmux surface"
            )
            return cmuxJoin(target: target, snapshot: snapshot, surface: surface)
        }

        if case .resolved(let snapshot) = remote {
            guard Self.remoteClaimIsCurrentlyHosted(surface: surface) else { return nil }
            Log.claudeContext.info(
                "Terminal pane joined to a live remote Claude session via cmux surface"
            )
            return cmuxJoin(target: target, snapshot: snapshot, surface: surface)
        }

        Self.abstainedCmuxJoin(outcome: Self.cmuxOutcome(local: local, remote: remote))
        return nil
    }

    /// Whether cmux says the focused surface is CURRENTLY hosted by a live
    /// remote workspace — the precondition for accepting any remote claim.
    ///
    /// Without it, a remote session's surface id is a REMEMBERED LABEL and
    /// nothing more: a compromised enrolled host can publish an id it saw
    /// during an earlier `cmux ssh` session, and once that surface has gone
    /// back to a local shell the replayed claim is the sole remote candidate
    /// and joins — pairing attacker-chosen context with whatever the user is
    /// now looking at.
    ///
    /// cmux exposes no remote-ness on the surface itself (a `cmux ssh` surface
    /// is an ordinary `type: "terminal"`; the state lives on the workspace), so
    /// the evidence comes from `workspace.remote.status` for the focused
    /// surface's own workspace, read in the same connection as the focus
    /// answer. Unknown fails closed.
    ///
    /// What this does NOT prove, stated plainly: that the remote session
    /// claiming the surface is the one on the other end of THAT ssh link. With
    /// two enrolled hosts, a compromised one can still claim a surface hosted
    /// by the other. It is bounded to genuinely-remote surfaces and to
    /// enrolled hosts.
    private static func remoteClaimIsCurrentlyHosted(surface: CmuxFocusedSurface) -> Bool {
        switch surface.workspaceIsRemote {
        case true:
            return true
        case false:
            abstainedCmuxJoin(
                outcome: "a remote session claims a surface cmux reports as local"
            )
            return false
        default:
            abstainedCmuxJoin(
                outcome: "cmux would not say whether the focused surface is remote-hosted"
            )
            return false
        }
    }

    /// One side resolved to exactly one session, and the other side had no
    /// candidate whatsoever.
    private static func isCleanlyResolved(
        _ resolution: ClaudeSessionResolution,
        other: ClaudeSessionResolution
    ) -> Bool {
        guard case .resolved = resolution else { return false }
        guard case .unknown = other else { return false }
        return true
    }

    private func cmuxJoin(
        target: TerminalScreenTarget,
        snapshot: ClaudeSessionSnapshot,
        surface: CmuxFocusedSurface
    ) -> ClaudeSessionJoin {
        ClaudeSessionJoin(
            target: target,
            snapshot: snapshot,
            windowID: focusedWindowID(target.pid),
            mechanism: .cmuxSurface,
            cmuxSurface: ClaudeCmuxSurfaceBinding(surfaceID: surface.surfaceID)
        )
    }

    /// Names WHICH side had nothing, so a hook that never published the surface
    /// id is distinguishable from an ambiguous registry — the herdr arm's
    /// silent abstention cost a field afternoon (2026-07-20).
    private static func cmuxOutcome(
        local: ClaudeSessionResolution,
        remote: ClaudeSessionResolution
    ) -> String {
        switch (local, remote) {
        case (.resolved, .resolved):
            return "a local and a remote session both claim this surface"
        case (.resolved, _), (_, .resolved):
            // One side named a session and the other side had SOMETHING —
            // ambiguous or stale. Named separately from plain ambiguity because
            // this is the case that used to join the resolved side.
            return "one origin resolved but the other also claims this surface"
        case (.ambiguous, _), (_, .ambiguous):
            return "focused surface matches several sessions"
        case (.stale, _), (_, .stale):
            return "focused surface session stale"
        default:
            return "focused surface has no live session"
        }
    }

    /// The joined cmux surface's visible text, or nil on any refusal or failure.
    ///
    /// The mirror of `herdrPaneVisibleText(for:)`, and the ONLY path that issues
    /// a `surface.read_text`: the request is keyed by the binding the cmux arm
    /// captured at resolution, so no other surface — and no other join
    /// mechanism — can reach cmux's socket through it. Returns RAW wire text;
    /// the caller owns sanitization, bounding, and every consent gate.
    func cmuxSurfaceVisibleText(for join: ClaudeSessionJoin) async -> String? {
        guard join.mechanism == .cmuxSurface, let binding = join.cmuxSurface else {
            Log.claudeContext.info("cmux surface read refused: join is not a cmux surface join")
            return nil
        }
        guard cmuxJoinEnabled() else {
            Log.claudeContext.info("cmux surface read refused: cmux join not enabled")
            return nil
        }
        guard let cmuxSurfaces else {
            Log.claudeContext.info("cmux surface read refused: surface query capability unavailable")
            return nil
        }
        switch await cmuxSurfaces.surfaceText(
            surfaceID: binding.surfaceID, expectedPeerPID: join.target.pid
        ) {
        case .value(let text):
            return text
        case .authenticationRequired:
            reportCmuxStatus(.authenticationRequired)
            Log.claudeContext.info("cmux surface read refused: socket requires password mode")
            return nil
        case .unavailable:
            Log.claudeContext.info("cmux surface read failed: surface text unavailable")
            return nil
        }
    }

    /// Outcome only: surface ids and surface text are live join material and
    /// never belong in the unified log.
    private static func abstainedCmuxJoin(outcome: String) {
        Log.claudeContext.info(
            "cmux surface matched no session (\(outcome, privacy: .public))"
        )
        Self.noteAbstention("cmux: \(outcome)")
    }

    /// Re-checks at commit that the join resolved at start still names one live
    /// session, WITHOUT asking any surface a second question.
    ///
    /// The SESSION is fixed by the start resolution — that is the point of
    /// resolving once. What can still change between start and stop is that
    /// session: it can end, its process can die, or the registry can evict it.
    /// Those make the join stale, and a stale join must not attach. So this
    /// asks the registry about the SAME session id (`snapshot(sessionID:)`,
    /// the same TTL-plus-pid-liveness answer every arm resolves through)
    /// rather than re-reading a surface, which would let the answer drift to a
    /// different pane.
    /// A `.browserTab` join additionally re-checks its BINDING: the session
    /// must still report the bridge session id the tab named at start.
    ///
    /// This is what makes a Remote Control disconnect age the join out without
    /// a timer of ours. `CLAUDE_CODE_BRIDGE_SESSION_ID` is REMOVED from the
    /// hook environment when the browser connection ends, and the reducer
    /// replaces a session's reported metadata on the next non-focus record —
    /// `process` for a local session, `remoteEnvironment` for a remote one — so
    /// that record carries no bridge id and this check fails on the session's
    /// own activity, with no clock of ours involved.
    ///
    /// Two exactness caveats, both deliberate and both pinned by tests:
    /// * A record with NO process block (local) or NO allowlisted env header at
    ///   all (remote) is not a retraction — the reducer keeps the last report
    ///   (#216: "an empty report is not a retraction"). Such a session keeps its
    ///   binding until TTL. The bundled shim always reports `$PPID`, so an
    ///   honest disconnect never takes that path, and a host that strips its
    ///   headers could just as well keep sending the id.
    /// * A session that stops reporting entirely is covered by the registry's
    ///   existing freshness (TTL plus, locally, process liveness), exactly like
    ///   every other arm — on the registry's injected clock.
    func isStillLive(_ join: ClaudeSessionJoin) -> Bool {
        guard registry.snapshot(sessionID: join.snapshot.sessionID) != nil else { return false }
        guard join.mechanism == .browserTab else { return true }
        guard let binding = join.browserTab else {
            // Unreachable through `resolveViaBrowserTab`, which always binds.
            // Fail closed anyway: a browser join with nothing to re-check is
            // not a join we can still vouch for.
            Log.claudeContext.info(
                "Browser tab join carries no bridge binding; treating it as ended"
            )
            return false
        }
        // Re-ASK the registry rather than re-check the session we already
        // picked (review finding, codex on PR #218). Asking only "does my
        // session still report this id" answers a question that was already
        // settled at start; what can change afterwards is who ELSE reports it.
        // A second reporter arriving mid-dictation is exactly the case the
        // start-time arm abstains on — and a hostile enrolled remote host can
        // publish any label it likes, so "I was the sole reporter when we
        // resolved" must not be a permanent claim. Re-resolving makes the
        // abstention rules identical at both ends: unique fresh reporter, or no
        // join. It subsumes the identity check too — `.resolved` can only name
        // a session that still reports the bound id.
        guard case .resolved(let current) =
            registry.resolve(bridgeSessionID: binding.bridgeSessionID),
            current.sessionID == join.snapshot.sessionID
        else {
            Log.claudeContext.info(
                "Remote Control bridge session no longer resolves to this session alone; Claude context withheld"
            )
            return false
        }
        return true
    }
}

/// Authorizes raw screen attachment from an already-resolved join.
///
/// Holds no resolution logic of its own — it consults the dictation's single
/// join. Before this, the authorizer read the window title itself at commit
/// time, which meant the screen and the (then unbuilt) repo context could
/// resolve different sessions from two reads taken seconds apart.
@MainActor
struct TerminalScreenClaudeJoinAuthorizer: TerminalScreenRawAttachmentAuthorizing {
    private let resolver: ClaudeSessionJoinResolver
    private let currentJoin: @MainActor () -> ClaudeSessionJoin?

    init(
        resolver: ClaudeSessionJoinResolver,
        currentJoin: @escaping @MainActor () -> ClaudeSessionJoin?
    ) {
        self.resolver = resolver
        self.currentJoin = currentJoin
    }

    func isAuthorized(target: TerminalScreenTarget, windowID: CGWindowID?) -> Bool {
        guard let join = currentJoin() else { return false }
        // Exhaustive on purpose: a new join mechanism must DECIDE here rather
        // than inherit authorization from whichever arm was written first.
        switch join.mechanism {
        case .ttyDevice:
            break
        case .herdrPane, .cmuxSurface, .remoteHerdrPane:
            // AX sees herdr's composite TUI. Attaching it would let neighboring
            // panes — potentially other Claude sessions — ride into this
            // session's prompt, so a correct pane join still cannot authorize
            // raw capture.
            //
            // A cmux join is refused for a different reason with the same
            // answer: cmux draws with libghostty into a custom view that
            // exposes no AX text at all, so there is nothing here to authorize
            // — and if some future cmux build ever did expose a composite
            // surface, it must not become attachable by default. Both
            // multiplexers' screen text arrives through their own per-pane
            // socket route instead (`SocketPaneScreenContext`).
            //
            // A REMOTE herdr join is refused for the first reason, doubled: the
            // grid is not even this machine's — it is the local ssh client's
            // window, showing whatever herdr drew, panes and all.
            Log.claudeContext.info(
                "Socket-pane join cannot authorize raw AX screen attachment; withheld"
            )
            return false
        case .browserTab:
            // There is no verified screen route for a browser, and the thing on
            // screen is an arbitrary web page rather than a terminal grid. A
            // browser join buys session/repository context only.
            Log.claudeContext.info(
                "Browser tab join cannot authorize raw screen attachment; withheld"
            )
            return false
        }
        // The join must be about THIS pane. A join resolved for one target
        // says nothing about another, and a recycled PID must not inherit the
        // previous owner's authorization — hence the full target compare
        // (pid AND bundle id), not just the pid.
        guard join.target == target else {
            Log.claudeContext.info(
                "Claude join does not describe the captured pane; raw screen attachment withheld"
            )
            return false
        }
        // The target compare above cannot tell two windows of one Ghostty
        // process apart (same pid, same bundle ID), and the capture and the
        // join are two separate AX reads — a focus change between them pairs
        // one window's screen with another window's session (review F2). Only
        // two ESTABLISHED, equal identities authorize; an unknown on either
        // side is an abstention, never a match.
        guard let joinWindow = join.windowID, let captureWindow = windowID,
              joinWindow == captureWindow
        else {
            Log.claudeContext.info(
                "Claude join and screen capture do not name the same window of the target app; raw screen attachment withheld"
            )
            return false
        }
        guard resolver.isStillLive(join) else {
            Log.claudeContext.info(
                "Claude session ended since dictation start; raw screen attachment withheld"
            )
            return false
        }
        return true
    }
}
