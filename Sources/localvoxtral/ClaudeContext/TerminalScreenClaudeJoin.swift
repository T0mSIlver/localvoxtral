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
struct ClaudeSessionJoin: Sendable, Equatable {
    /// The pane the marker was read from. Consumers re-check this rather than
    /// assuming the join is about whatever target they happen to hold.
    let target: TerminalScreenTarget
    /// The broker-allocated marker, read out of the PID-pinned window title.
    let marker: ClaudeSessionMarker
    /// The session as the registry described it at start.
    let snapshot: ClaudeSessionSnapshot
    /// The identity of the WINDOW the marker was read from. `target` cannot
    /// tell two windows of one Ghostty process apart, and the screen capture is
    /// a SEPARATE read that can land on a different window if focus moves
    /// between the two — so authorization compares windows, not just targets
    /// (review F2). Nil means unknown, which never authorizes.
    let windowID: CGWindowID?

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

    /// - Parameters:
    ///   - markerInWindowTitle: reads the PID-pinned focused window title,
    ///     parses a marker out of it, and reports which WINDOW it read.
    ///     Injected so the whole truth table is unit-testable without a live
    ///     AX tree — the same reason every other live read in this feature is
    ///     a seam.
    ///   - focusedTerminalTTY: reads the focused pane's controlling TTY for a
    ///     bundle id (Ghostty ≥ 1.4 over AppleScript). Unlike the AX seam this
    ///     DEFAULTS TO ABSTAIN, not to the live reader: an Apple event is not
    ///     an AX read — the first one triggers the Automation consent prompt,
    ///     and a defaulted live reader would send real events (and hang the
    ///     suite on that prompt) from any test that forgets to inject. The app
    ///     wires `GhosttyFocusedTerminalTTYReader` explicitly.
    ///   - focusedWindowID: the tty join's window identity. A marker join
    ///     learns its window from the marker read itself, but a tty join never
    ///     consults the title — so the focused window is identified by this
    ///     separate PID-pinned AX read. Nil means unknown, which the
    ///     authorizer refuses, exactly like a nil marker-read identity
    ///     (review F2).
    init(
        registry: ClaudeSessionRegistry,
        markerInWindowTitle: @escaping (pid_t) -> TerminalScreenAXReader.FocusedWindowMarkerRead? = {
            TerminalScreenAXReader.markerInFocusedWindowTitle(applicationPID: $0)
        },
        focusedTerminalTTY: @escaping (String) async -> String? = { _ in nil },
        focusedWindowID: @escaping (pid_t) -> CGWindowID? = {
            TerminalScreenAXReader.focusedWindowIdentity(applicationPID: $0)
        }
    ) {
        self.registry = registry
        self.markerInWindowTitle = markerInWindowTitle
        self.focusedTerminalTTY = focusedTerminalTTY
        self.focusedWindowID = focusedWindowID
    }

    /// The join for `target`, or nil on any abstention.
    ///
    /// TTY first, marker second. The TTY compares the focused pane's device
    /// against what the hook publisher reported from inside the session — the
    /// process table cannot be clobbered by whoever wrote the window title
    /// last, so it keeps joining while Claude Code's own conversation titles
    /// own the visible one. Any TTY non-answer (old Ghostty, Automation
    /// denied, no local session on that device, two sessions claiming it)
    /// falls through to the marker path unchanged; remote sessions can ONLY
    /// join via marker, because their TTY names another machine's device and
    /// `resolve(tty:)` refuses remote candidates outright.
    ///
    /// This remains the only place a join is resolved, once per dictation, at
    /// start — whichever mechanism answers.
    func resolve(target: TerminalScreenTarget) async -> ClaudeSessionJoin? {
        // The allowlist is re-checked here even though the capture gate already
        // enforced it. This object is reachable independently of that gate, and
        // "only a verified single-AXTextArea grid" is a precondition of reading
        // this app at all — not something to inherit on trust from a caller.
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
                    windowID: focusedWindowID(target.pid)
                )
            case .unknown:
                abstainedTTYJoin(outcome: "no live session on this device")
            case .stale:
                abstainedTTYJoin(outcome: "stale")
            case .ambiguous:
                abstainedTTYJoin(outcome: "ambiguous")
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
    }

    private func resolveViaMarker(target: TerminalScreenTarget) -> ClaudeSessionJoin? {
        guard let read = markerInWindowTitle(target.pid) else {
            // No marker on screen: this pane is not a joined Claude session, or
            // we cannot tell. Either way there is nothing to resolve.
            Log.claudeContext.info("Terminal pane carries no Claude session marker")
            return nil
        }

        switch registry.resolve(marker: read.marker) {
        case .resolved(let snapshot):
            Log.claudeContext.info("Terminal pane joined to a live Claude session via title marker")
            return ClaudeSessionJoin(
                target: target, marker: read.marker, snapshot: snapshot, windowID: read.windowID
            )
        case .unknown, .stale, .ambiguous:
            // Count-only: the marker itself is not logged. It is a live handle
            // to a session's context, and a log is the wrong place for it.
            Log.claudeContext.info(
                "Terminal pane not joined to a live Claude session; Claude context withheld"
            )
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
