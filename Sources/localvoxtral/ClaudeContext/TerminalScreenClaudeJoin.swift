import ClaudeContextWire
import Foundation

/// Joins a captured terminal pane to a live Claude Code session, and authorizes
/// raw screen attachment only when that join is unambiguous.
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
///   themselves) → false. This is what keeps arbitrary scrollback out.
/// - a title with TWO markers → the parser abstains → false.
/// - `unknown` (marker we never issued, or a stale title left behind after the
///   session ended and the registry evicted it) → false.
/// - `stale` (past TTL, or the Claude process is gone) → false.
/// - `ambiguous` (more than one live session matches) → false.
///
/// Only `.resolved` authorizes.
@MainActor
struct TerminalScreenClaudeJoinAuthorizer: TerminalScreenRawAttachmentAuthorizing {
    private let registry: ClaudeSessionRegistry
    private let markerInWindowTitle: (pid_t) -> ClaudeSessionMarker?

    /// - Parameter markerInWindowTitle: reads the PID-pinned focused window
    ///   title and parses a marker out of it. Injected so the whole truth table
    ///   is unit-testable without a live AX tree — the same reason every other
    ///   live read in this feature is a seam.
    init(
        registry: ClaudeSessionRegistry,
        markerInWindowTitle: @escaping (pid_t) -> ClaudeSessionMarker? = {
            TerminalScreenAXReader.markerInFocusedWindowTitle(applicationPID: $0)
        }
    ) {
        self.registry = registry
        self.markerInWindowTitle = markerInWindowTitle
    }

    func isAuthorized(target: TerminalScreenTarget) -> Bool {
        // The allowlist is re-checked here even though the capture gate already
        // enforced it. This object is reachable independently of that gate, and
        // "only a verified single-AXTextArea grid" is a precondition of reading
        // this app at all — not something to inherit on trust from a caller.
        guard TerminalScreenAllowlist.isSupported(target.bundleID) else { return false }

        guard let marker = markerInWindowTitle(target.pid) else {
            // No marker on screen: this pane is not a joined Claude session, or
            // we cannot tell. Either way there is nothing to authorize.
            return false
        }

        switch registry.resolve(marker: marker) {
        case .resolved:
            Log.claudeContext.info("Terminal pane joined to a live Claude session")
            return true
        case .unknown, .stale, .ambiguous:
            // Count-only: the marker itself is not logged. It is a live handle
            // to a session's context, and a log is the wrong place for it.
            Log.claudeContext.info(
                "Terminal pane not joined to a live Claude session; raw screen attachment withheld"
            )
            return false
        }
    }
}
