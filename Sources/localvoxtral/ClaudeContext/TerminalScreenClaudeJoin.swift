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
/// different moment. So the marker is read at START, from the pane the user was
/// looking at when they began speaking, and that answer is what every consumer
/// gets.
enum ClaudeSessionJoinMechanism: Sendable, Equatable {
    case ttyDevice
    case titleMarker
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
    /// The broker-allocated marker used for commit-time liveness. A title join
    /// reads it from AX; TTY and herdr joins take it from the resolved snapshot.
    let marker: ClaudeSessionMarker
    /// The session as the registry described it at start.
    let snapshot: ClaudeSessionSnapshot
    /// The identity of the WINDOW the marker was read from. `target` cannot
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

    init(
        target: TerminalScreenTarget,
        marker: ClaudeSessionMarker,
        snapshot: ClaudeSessionSnapshot,
        windowID: CGWindowID?,
        mechanism: ClaudeSessionJoinMechanism,
        herdrPane: ClaudeHerdrPaneBinding? = nil,
        browserTab: ClaudeBrowserTabBinding? = nil,
        cmuxSurface: ClaudeCmuxSurfaceBinding? = nil,
        remoteHerdrForward: ClaudeRemoteHerdrForwardHandle? = nil
    ) {
        self.target = target
        self.marker = marker
        self.snapshot = snapshot
        self.windowID = windowID
        self.mechanism = mechanism
        self.herdrPane = herdrPane
        self.browserTab = browserTab
        self.cmuxSurface = cmuxSurface
        self.remoteHerdrForward = remoteHerdrForward
    }

    /// The per-pane socket route this join owns, if any: the herdr pane id or
    /// the cmux surface id. Lets the shared socket-pane screen path key its
    /// start/stop reconciliation without knowing which multiplexer answered.
    var socketPaneKey: String? {
        switch mechanism {
        case .herdrPane, .remoteHerdrPane: return herdrPane?.paneID
        case .cmuxSurface: return cmuxSurface?.surfaceID
        case .ttyDevice, .titleMarker, .browserTab: return nil
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
/// wait for. The chain it requires is deliberately end-to-end, with no step
/// inferred from another:
///
/// 1. The broker allocated a marker for a session it authenticated from PEER
///    CREDENTIALS (`ClaudeTransportOrigin`), so a marker existing at all means
///    a local process running as this user reported that session.
/// 2. Claude Code wrote that marker into its window title (`ClaudeMarkerSequence`).
/// 3. We read the title back from the PID we captured — never system-wide focus
///    — and parse exactly one marker out of it (`ClaudeMarkerTitleParser`).
/// 4. The registry still resolves that marker to ONE live session.
///
/// Every link abstains rather than guesses, because the failure modes are not
/// symmetric: a wrong `true` renders an unrelated terminal's scrollback into
/// someone's prompt, while a wrong `false` costs only an excerpt whose terms the
/// vocabulary matcher already extracted. So:
///
/// - a title with no marker (plain Ghostty, an editor, a shell the user opened
///   themselves) → no join. This is what keeps arbitrary scrollback out.
/// - a title with TWO markers → the parser abstains → no join.
/// - `unknown` (marker we never issued, or a stale title left behind after the
///   session ended and the registry evicted it) → no join.
/// - `stale` (past TTL, or the Claude process is gone) → no join.
/// - `ambiguous` (more than one live session matches) → no join.
///
/// Note what is NOT here: any inference from the cwd, the window title text, or
/// "there is only one live session so it must be that one". A sole-session
/// heuristic is wrong precisely when it matters — the user has one Claude
/// session open and is dictating into an unrelated shell — and it would attach
/// that session's repo to a prompt that has nothing to do with it.
@MainActor
struct ClaudeSessionJoinResolver {
    private let registry: ClaudeSessionRegistry
    private let markerInWindowTitle: (pid_t) -> TerminalScreenAXReader.FocusedWindowMarkerRead?
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
    private let remoteHerdrForwards: (any ClaudeRemoteHerdrForwarding)?

    /// - Parameters:
    ///   - markerInWindowTitle: reads the PID-pinned focused window title,
    ///     parses a marker out of it, and reports which WINDOW it read.
    ///     Injected so the whole truth table is unit-testable without a live
    ///     AX tree — the same reason every other live read in this feature is
    ///     a seam.
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
    ///   - focusedWindowID: the tty join's window identity. A marker join
    ///     learns its window from the marker read itself, but a tty join never
    ///     consults the title — so the focused window is identified by this
    ///     separate PID-pinned AX read. Nil means unknown, which the
    ///     authorizer refuses, exactly like a nil marker-read identity
    ///     (review F2).
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
    ///   - remoteHerdrForwards: opens the app-managed `ssh -L`. Nil means the
    ///     arm can never spawn anything, which is what a test that forgets to
    ///     inject must get.
    init(
        registry: ClaudeSessionRegistry,
        markerInWindowTitle: @escaping (pid_t) -> TerminalScreenAXReader.FocusedWindowMarkerRead? = {
            TerminalScreenAXReader.markerInFocusedWindowTitle(applicationPID: $0)
        },
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
            .undeterminable
        },
        enrolledHosts: @escaping @MainActor (String) -> [ClaudeRemoteHost] = { _ in [] },
        remoteHerdrForwards: (any ClaudeRemoteHerdrForwarding)? = nil
    ) {
        self.registry = registry
        self.markerInWindowTitle = markerInWindowTitle
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
        self.remoteHerdrForwards = remoteHerdrForwards
    }

    /// The join for `target`, or nil on any abstention.
    ///
    /// TTY first, then herdr when that TTY belongs to an attached client, then
    /// marker. The TTY compares the focused pane's device
    /// against what the hook publisher reported from inside the session — the
    /// process table cannot be clobbered by whoever wrote the window title
    /// last, so it keeps joining while Claude Code's own conversation titles
    /// own the visible one. A TTY non-answer falls through to the marker path
    /// unless the outer surface is positively bound to herdr; that path is
    /// herdr-or-nothing because Ghostty's title cannot identify an inner pane.
    /// No TTY answer at all still uses the marker unchanged. Remote sessions
    /// can ONLY join via marker, because their TTY names another machine's
    /// device and `resolve(tty:)` refuses remote candidates outright.
    ///
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
                // The tty join carries a window identity exactly like the
                // marker join: without one, the authorizer cannot tell two
                // windows of one Ghostty process apart and must refuse raw
                // attachment (review F2). Read here, once, at join time.
                return ClaudeSessionJoin(
                    target: target,
                    marker: snapshot.marker,
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

            // A focused surface positively bound to herdr is herdr-or-nothing.
            // Ghostty's title describes the outer client, not an inner pane; a
            // lingering marker there could only mis-join the pane now visible.
            if herdrClientProbe(tty) {
                return await resolveViaHerdr(target: target)
            }

            // The surface is not a local herdr client. It may still be an ssh
            // session into an enrolled host that is running one.
            switch await resolveViaRemoteHerdr(target: target, tty: tty) {
            case .joined(let join):
                return join
            case .abstained:
                // Herdr-or-nothing, for the local arm's reason transposed: the
                // remote pane's marker lives in herdr's captured pane title,
                // and any marker in the OUTER window belongs to something else
                // — most likely this same host BEFORE the user attached herdr.
                return nil
            case .notApplicable:
                break
            }
        }

        // cmux has no AppleScript TTY reader, so the block above never answers
        // for it and this is where its surface arm runs. Unlike herdr's, an
        // abstention here FALLS THROUGH to the marker: cmux forwards an inner
        // OSC 2 to the window title, so a local session under the title-fallback
        // opt-in can still be joined the old way. (It is not reliable — a custom
        // workspace name or cmux's AI auto-naming replaces the title — which is
        // exactly why the surface arm exists, and exactly why it must not be the
        // only chance.)
        if TerminalScreenAllowlist.isSocketCaptureSupported(target.bundleID),
           let join = await resolveViaCmux(target: target) {
            return join
        }

        return resolveViaMarker(target: target)
    }

    /// Outcome only, never the device path. A silent abstention here made a
    /// broken hook-side tty capture indistinguishable from a failed pane read
    /// in the field (2026-07-20) — the marker fallback may still answer, but
    /// the non-answer must say which side of the join went missing.
    private func abstainedTTYJoin(outcome: String) {
        Log.claudeContext.info(
            "Focused-pane tty matched no session (\(outcome, privacy: .public)); trying title marker"
        )
        #if LOCALVOXTRAL_DOGFOOD
        DogfoodCaptureTap.shared.noteJoinAbstention("tty: \(outcome)")
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
                marker: snapshot.marker,
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
        #if LOCALVOXTRAL_DOGFOOD
        DogfoodCaptureTap.shared.noteJoinAbstention("browserTab: \(outcome)")
        #endif
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
            marker: snapshot.marker,
            snapshot: snapshot,
            windowID: focusedWindowID(target.pid),
            mechanism: .herdrPane,
            herdrPane: ClaudeHerdrPaneBinding(paneID: pane.paneID, socketPath: socketPath)
        )
    }

    /// What the remote herdr arm concluded.
    ///
    /// `notApplicable` and `abstained` are NOT the same answer and the
    /// difference is the whole safety argument: the arm falls through to the
    /// title marker only while nothing has bound it to a remote herdr, and
    /// stops the dictation's join dead once something has.
    enum RemoteHerdrArmOutcome {
        /// Nothing here is about a remote herdr; other arms may still answer.
        case notApplicable
        /// This surface IS an enrolled host's herdr and the join still failed.
        case abstained
        case joined(ClaudeSessionJoin)
    }

    /// A Claude Code session inside a herdr on an ENROLLED REMOTE host.
    ///
    /// Bindings, all required, in cost order — the free local reads first, so an
    /// ordinary ssh session never pays for a forward:
    ///
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
    ///    FOCUSED pane id (two claiming the same pane id abstain), and that
    ///    pane's captured title carries exactly that session's broker-allocated
    ///    marker;
    /// 5. herdr's own session claim for the pane does not disagree, and the pane
    ///    is running that session's agent.
    ///
    /// Every one of these can only ever CONFIRM. No step picks a session because
    /// it is the only one, the most recent, or the one whose cwd looks right.
    ///
    /// The `notApplicable`/`abstained` split is exactly steps 1–3 vs 4–5: until
    /// this terminal's connection is bound to a herdr that has candidates, a
    /// non-answer must leave the title-marker arm alone — an unrelated herdr on
    /// the host must not cost a plain remote session the join it has always had.
    private func resolveViaRemoteHerdr(
        target: TerminalScreenTarget,
        tty: String
    ) async -> RemoteHerdrArmOutcome {
        let connection: SSHSurfaceConnection
        switch sshDestinationProbe(tty) {
        case .noSSHClient:
            // The overwhelmingly common case: a local shell. Not logged — this
            // is not an abstention, it is the arm not applying.
            return .notApplicable
        case .undeterminable:
            Self.abstainedRemoteHerdrJoin(outcome: "ssh session undeterminable")
            return .notApplicable
        case .connection(let value):
            connection = value
        }

        let hosts = enrolledHosts(connection.destination)
        guard !hosts.isEmpty else {
            // An ssh session to a host the user never enrolled. There is no
            // context to join, and the title marker still deserves its chance:
            // a plain remote session joins that way and always has.
            return .notApplicable
        }
        guard hosts.count == 1, let host = hosts.first, let alias = host.sshHostAlias else {
            Self.abstainedRemoteHerdrJoin(outcome: "ssh destination matches multiple enrolled hosts")
            return .notApplicable
        }

        let candidates = registry.liveRemoteHerdrSessions(hostID: host.id)
        guard !candidates.isEmpty else {
            // Enrolled, but nothing on it reported a herdr pane — a plain
            // remote Claude session. Marker arm, exactly as before.
            return .notApplicable
        }
        let socketPaths = Set(candidates.compactMap { $0.remoteSessionEnvironment?.herdrSocketPath })
        guard socketPaths.count == 1, let remoteSocketPath = socketPaths.first else {
            // Mirror of the local single-socket rule: two herdr servers on one
            // host, and no way to tell which one the surface is attached to.
            Self.abstainedRemoteHerdrJoin(outcome: "multiple live herdr sockets on this host")
            return .notApplicable
        }

        // The connection-level bind, and it takes BOTH facts.
        //
        // Uniqueness alone was a mis-join (review round 5b): it says nothing
        // about what this terminal DISPLAYS. A herdr whose client detached —
        // or whose pane still carries a marker and a running agent inside the
        // registry TTL — keeps answering `pane.current` with that pane, so a
        // later sole `ssh builder` passed the gate and every remaining check
        // (pane id, marker, session claim, foreground) agreed about a session
        // the user cannot see.
        //
        // The honest fix is to require positive evidence that THIS connection
        // is a herdr client, and herdr does not expose one: verified against
        // the 0.7.5 socket schema and the 0.8.0 docs, the only `client.*`
        // methods are `window_title.set`/`clear` — both MUTATIONS, so neither
        // is usable as a probe — and `session.snapshot` carries no attachment
        // field. So the evidence has to come from the invocation itself, and
        // `indicatesHerdr` is promoted from corroboration to a REQUIREMENT.
        //
        // The cost, stated accurately: the manual flow — `ssh host`, then type
        // `herdr` — gets no HERDR join. It does not get "no context": this
        // returns `.notApplicable`, so the title-marker arm still runs, and a
        // marker left in the OUTER title by an earlier session on that host can
        // still win. That residual is pre-existing (it is what a remote session
        // has always done) and cannot be closed from here — nothing on the
        // surface tells us a remote herdr is running inside it. A wrong HERDR
        // join is what this refuses.
        //
        // Uniqueness stays REQUIRED alongside it: argv is written by whoever
        // launched the process, so it must never be the only thing standing
        // between two terminals and each other's sessions.
        guard connection.isOnlyConnectionToDestination else {
            Self.abstainedRemoteHerdrJoin(
                outcome: "another terminal holds an ssh session to this destination"
            )
            return .notApplicable
        }
        guard connection.indicatesHerdr else {
            Self.abstainedRemoteHerdrJoin(
                outcome: "the ssh command on this terminal is not herdr itself"
            )
            return .notApplicable
        }

        // NOT yet herdr-or-nothing. Registry candidates existing on the host is
        // not a binding for THIS connection — a detached herdr, or one whose
        // sessions are merely still inside their TTL, would otherwise cost a
        // sole plain ssh session the outer marker join it has always had
        // (review round 3, blocker 1b). Everything up to and including the
        // pane-id + marker confirmation therefore still falls through.
        guard let remoteHerdrForwards else {
            Self.abstainedRemoteHerdrJoin(outcome: "forward capability unavailable")
            return .notApplicable
        }
        guard let herdrPanes else {
            Self.abstainedRemoteHerdrJoin(outcome: "pane query capability unavailable")
            return .notApplicable
        }
        guard let forward = await remoteHerdrForwards.open(
            alias: alias, remoteSocketPath: remoteSocketPath
        ) else {
            Self.abstainedRemoteHerdrJoin(outcome: "forward unavailable")
            return .notApplicable
        }

        switch await resolveRemoteHerdrPane(
            target: target,
            hostID: host.id,
            candidates: candidates,
            forward: forward,
            herdrPanes: herdrPanes
        ) {
        case .joined(let join):
            Log.claudeContext.info(
                "Terminal pane joined to a live Claude session via remote herdr pane"
            )
            return .joined(join)
        case .unconfirmed:
            // The herdr on the other end never confirmed that THIS connection
            // displays one of our sessions. Nothing was established, so the
            // marker arm keeps its chance.
            forward.close()
            return .notApplicable
        case .refusedAfterConfirmation:
            // The focused pane IS this session's — pane id and the
            // broker-allocated marker both said so — and a later fail-closed
            // check refused it. NOW a marker in the outer window could only
            // describe something else, so the dictation joins nothing.
            forward.close()
            return .abstained
        }
    }

    /// What the over-the-forward half concluded.
    ///
    /// The `unconfirmed`/`refusedAfterConfirmation` split is where
    /// herdr-or-nothing begins: only a pane id AND marker match prove this
    /// connection is displaying one of our sessions.
    private enum RemoteHerdrPaneOutcome {
        case joined(ClaudeSessionJoin)
        case unconfirmed
        case refusedAfterConfirmation
    }

    /// The over-the-forward half: focused pane, marker, then the fail-closed
    /// cross-checks. Split out so the failure paths have exactly one
    /// `forward.close()` and one place deciding which side of the
    /// herdr-or-nothing line each failure falls on.
    private func resolveRemoteHerdrPane(
        target: TerminalScreenTarget,
        hostID: String,
        candidates: [ClaudeSessionSnapshot],
        forward: ClaudeRemoteHerdrForwardHandle,
        herdrPanes: HerdrPaneQuerying
    ) async -> RemoteHerdrPaneOutcome {
        let socketPath = forward.localSocketPath
        guard let pane = await herdrPanes.focusedPane(socketPath: socketPath) else {
            Self.abstainedRemoteHerdrJoin(outcome: "focused pane unavailable")
            return .unconfirmed
        }
        // The precondition, stated precisely because a loose reading of it drew
        // a review finding: exactly one candidate for the FOCUSED PANE ID —
        // NOT one candidate per socket. Several live sessions on one herdr are
        // expected and fine; that is what a multiplexer is for, and it is the
        // case this arm exists to serve. What abstains is two candidates
        // claiming the SAME pane id, which is the only shape that would force a
        // choice. Nothing here picks: the survivor still has to be confirmed by
        // the marker, by herdr's own session claim, and by the foreground
        // process below.
        let matches = candidates.filter {
            $0.remoteSessionEnvironment?.herdrPaneID == pane.paneID
        }
        guard matches.count == 1, let snapshot = matches.first else {
            Self.abstainedRemoteHerdrJoin(
                outcome: matches.isEmpty
                    ? "focused pane has no live session"
                    : "two live sessions claim the focused pane id"
            )
            return .unconfirmed
        }

        // The marker is the second, independent binding — pane id equality
        // alone rests entirely on labels the host chose. This marker was
        // ALLOCATED HERE, handed to that session over its own authenticated
        // request, and written into the pane by Claude Code itself; a host
        // cannot invent one, and a marker from another session cannot match.
        guard let title = pane.terminalTitle else {
            Self.abstainedRemoteHerdrJoin(outcome: "focused pane reported no title")
            return .unconfirmed
        }
        guard let marker = ClaudeMarkerTitleParser.marker(inTitle: title) else {
            // Zero markers (a plain title) or two (the parser abstains) —
            // both are "this pane does not name one session".
            Self.abstainedRemoteHerdrJoin(outcome: "focused pane title carries no single marker")
            return .unconfirmed
        }
        guard marker == snapshot.marker else {
            Self.abstainedRemoteHerdrJoin(outcome: "focused pane title marker names another session")
            return .unconfirmed
        }

        // CONFIRMED: the focused pane of the herdr this connection reaches is
        // this session's, proven by a pane id AND a marker we allocated
        // ourselves. Failures from here are herdr-or-nothing.

        // herdr's OWN claim about the pane, fail-closed exactly like the local
        // arm's (`resolveViaHerdr`). This is the check that catches a reused
        // pane: session A dies without a SessionEnd, leaving a fresh marker and
        // pane id in the registry; session B starts in that same pane. Pane id
        // and even a stale title can still name A, and herdr — which watches the
        // pane — says B. A disagreement resolves to NEITHER (review finding 3).
        //
        // Scoped by the session's own host and agent before comparing, never by
        // anything herdr says, so a claim can only ever CONFIRM the pane-id
        // join and never redirect it.
        if let claimed = pane.claimedClaudeSessionID,
           Self.scopedRemoteSessionID(
               claimed: claimed, hostID: hostID, agent: snapshot.agent
           ) != snapshot.sessionID {
            Self.abstainedRemoteHerdrJoin(outcome: "pane session claim disagrees")
            return .refusedAfterConfirmation
        }

        guard let foreground = await herdrPanes.paneForegroundInfo(
            socketPath: socketPath, paneID: pane.paneID
        ) else {
            Self.abstainedRemoteHerdrJoin(outcome: "foreground process query unavailable")
            return .refusedAfterConfirmation
        }
        guard let processes = foreground.foregroundProcesses else {
            Self.abstainedRemoteHerdrJoin(outcome: "foreground process detection unavailable")
            return .refusedAfterConfirmation
        }
        guard Self.remoteAgentIsForeground(snapshot: snapshot, foregroundProcesses: processes) else {
            return .refusedAfterConfirmation
        }

        return .joined(ClaudeSessionJoin(
            target: target,
            marker: snapshot.marker,
            snapshot: snapshot,
            windowID: focusedWindowID(target.pid),
            mechanism: .remoteHerdrPane,
            herdrPane: ClaudeHerdrPaneBinding(paneID: pane.paneID, socketPath: socketPath),
            remoteHerdrForward: forward
        ))
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
        #if LOCALVOXTRAL_DOGFOOD
        DogfoodCaptureTap.shared.noteJoinAbstention("remote-herdr: \(outcome)")
        #endif
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
        #if LOCALVOXTRAL_DOGFOOD
        DogfoodCaptureTap.shared.noteJoinAbstention("herdr: \(outcome)")
        #endif
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
    ///   claim the focused pane — the same trust class as the existing remote
    ///   marker join, no worse, and bounded by enrollment the user can revoke.
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
            // prove it owns a pane), and opencode never receives a title
            // marker either — so opencode inside cmux gets no join at all. A
            // missed join costs an excerpt; a wrong one puts another session's
            // screen in this prompt.
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
    /// now looking at. That made this arm strictly weaker than the title
    /// marker, which at least has to ride the PTY the session presently
    /// controls.
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
    /// by the other. It is bounded to genuinely-remote surfaces and to enrolled
    /// hosts, which is the same bound the remote marker join has.
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
        _ resolution: ClaudeMarkerResolution,
        other: ClaudeMarkerResolution
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
            marker: snapshot.marker,
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
        local: ClaudeMarkerResolution,
        remote: ClaudeMarkerResolution
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
            "cmux surface matched no session (\(outcome, privacy: .public)); trying title marker"
        )
        #if LOCALVOXTRAL_DOGFOOD
        DogfoodCaptureTap.shared.noteJoinAbstention("cmux: \(outcome)")
        #endif
    }

    private func resolveViaMarker(target: TerminalScreenTarget) -> ClaudeSessionJoin? {
        guard let read = markerInWindowTitle(target.pid) else {
            // No marker on screen: this pane is not a joined Claude session, or
            // we cannot tell. Either way there is nothing to resolve.
            Log.claudeContext.info("Terminal pane carries no Claude session marker")
            #if LOCALVOXTRAL_DOGFOOD
            DogfoodCaptureTap.shared.noteJoinAbstention("marker: no marker in title")
            #endif
            return nil
        }

        switch registry.resolve(marker: read.marker) {
        case .resolved(let snapshot):
            Log.claudeContext.info("Terminal pane joined to a live Claude session via title marker")
            return ClaudeSessionJoin(
                target: target,
                marker: read.marker,
                snapshot: snapshot,
                windowID: read.windowID,
                mechanism: .titleMarker
            )
        case .unknown, .stale, .ambiguous:
            // Count-only: the marker itself is not logged. It is a live handle
            // to a session's context, and a log is the wrong place for it.
            Log.claudeContext.info(
                "Terminal pane not joined to a live Claude session; Claude context withheld"
            )
            #if LOCALVOXTRAL_DOGFOOD
            DogfoodCaptureTap.shared.noteJoinAbstention("marker: unknown/stale/ambiguous")
            #endif
            return nil
        }
    }

    /// Re-checks at commit that the join resolved at start still names one live
    /// session, WITHOUT reading the title again.
    ///
    /// The marker is fixed by the start read — that is the point of resolving
    /// once. What can still change between start and stop is the session: it
    /// can end, its process can die, or the registry can evict it. Those make
    /// the join stale, and a stale join must not attach. So this asks the
    /// registry about the SAME marker rather than asking the screen a second
    /// question, which would let the answer drift to a different pane.
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
        guard case .resolved(let snapshot) = registry.resolve(marker: join.marker),
              snapshot.sessionID == join.snapshot.sessionID
        else { return false }
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
        case .ttyDevice, .titleMarker:
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
