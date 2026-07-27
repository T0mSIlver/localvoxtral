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
}

/// The herdr pane a `.herdrPane` join resolved to. Captured at resolution so
/// the pane-text fetch can only ever be keyed by the pane the join is ABOUT —
/// there is no other place a pane id enters that path.
struct ClaudeHerdrPaneBinding: Sendable, Equatable {
    let paneID: String
    let socketPath: String
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
    /// Non-nil exactly for `.herdrPane` joins: the pane whose clean, per-pane
    /// text (`pane.read`) may stand in for the composite screen capture.
    let herdrPane: ClaudeHerdrPaneBinding?

    init(
        target: TerminalScreenTarget,
        marker: ClaudeSessionMarker,
        snapshot: ClaudeSessionSnapshot,
        windowID: CGWindowID?,
        mechanism: ClaudeSessionJoinMechanism,
        herdrPane: ClaudeHerdrPaneBinding? = nil
    ) {
        self.target = target
        self.marker = marker
        self.snapshot = snapshot
        self.windowID = windowID
        self.mechanism = mechanism
        self.herdrPane = herdrPane
    }

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
    private let focusedWindowID: (pid_t) -> CGWindowID?
    private let herdrClientProbe: @Sendable (String) -> Bool
    private let herdrPanes: HerdrPaneQuerying?

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
    init(
        registry: ClaudeSessionRegistry,
        markerInWindowTitle: @escaping (pid_t) -> TerminalScreenAXReader.FocusedWindowMarkerRead? = {
            TerminalScreenAXReader.markerInFocusedWindowTitle(applicationPID: $0)
        },
        focusedTerminalTTY: @escaping (String) async -> String? = { _ in nil },
        focusedWindowID: @escaping (pid_t) -> CGWindowID? = {
            TerminalScreenAXReader.focusedWindowIdentity(applicationPID: $0)
        },
        herdrClientProbe: @escaping @Sendable (String) -> Bool = { _ in false },
        herdrPanes: HerdrPaneQuerying? = nil
    ) {
        self.registry = registry
        self.markerInWindowTitle = markerInWindowTitle
        self.focusedTerminalTTY = focusedTerminalTTY
        self.focusedWindowID = focusedWindowID
        self.herdrClientProbe = herdrClientProbe
        self.herdrPanes = herdrPanes
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
        guard Self.registeredClaudeIsForeground(
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

    /// The joined herdr pane's visible text, or nil on any refusal or failure.
    ///
    /// This is the ONLY path that issues a `pane.read`, and it can only read
    /// the pane the join resolved to: the request is keyed by the binding the
    /// herdr arm captured at resolution time, so no other pane — and no other
    /// join mechanism — can reach herdr's socket through it. The returned text
    /// is RAW wire text; the caller owns sanitization, bounding, and every
    /// consent gate (see `HerdrPaneScreenContext`).
    func herdrPaneVisibleText(for join: ClaudeSessionJoin) async -> String? {
        guard join.mechanism == .herdrPane, let binding = join.herdrPane else {
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
    static func registeredClaudeIsForeground(
        snapshot: ClaudeSessionSnapshot,
        foregroundPIDs: [Int32]
    ) -> Bool {
        guard let process = snapshot.process else {
            abstainedHerdrJoin(outcome: "registered session has no process metadata")
            return false
        }
        guard foregroundPIDs.contains(process.claudePID) else {
            abstainedHerdrJoin(outcome: "registered Claude process is not foreground")
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
    func isStillLive(_ join: ClaudeSessionJoin) -> Bool {
        if case .resolved(let snapshot) = registry.resolve(marker: join.marker) {
            return snapshot.sessionID == join.snapshot.sessionID
        }
        return false
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
        // AX sees herdr's composite TUI. Attaching it would let neighboring
        // panes — potentially other Claude sessions — ride into this session's
        // prompt, so a correct pane join still cannot authorize raw capture.
        guard join.mechanism != .herdrPane else {
            Log.claudeContext.info(
                "Herdr pane join cannot authorize composite raw screen attachment; withheld"
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
