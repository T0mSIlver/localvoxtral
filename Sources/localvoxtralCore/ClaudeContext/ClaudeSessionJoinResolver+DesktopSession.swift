import ClaudeContextWire
#if canImport(CoreGraphics)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#endif
import Foundation

/// What one read of Claude Desktop's focused web view found: the address of
/// the view holding the prompt, or why the reader gave none
/// (`AXClaudeDesktopSessionURLReader`).
///
/// Each refusal reaches the dictation's abstention causes as itself. With one
/// reason for all of them, 64 diagnostic records (Oct 2026) could not tell
/// focus in the sidebar from a Desktop layout the reader no longer recognizes.
package enum ClaudeDesktopFocusRead: Equatable, Sendable {
    case address(String)
    case refused(ClaudeDesktopFocusRefusal)

    /// The address, or `.unavailable` for nil.
    package init(address: String?) {
        if let address { self = .address(address) } else { self = .refused(.unavailable) }
    }

    package var foundAddress: String? {
        guard case .address(let address) = self else { return nil }
        return address
    }
}

/// Why the reader gave no address. Each raw value is the abstention cause the
/// diagnostic record keeps: a category, never an address.
package enum ClaudeDesktopFocusRefusal: String, Equatable, Sendable {
    /// The second pane of a split view, whose session the address does not name.
    case secondaryPane = "focus is in the second pane of a split view"
    /// The primary pane outside its chat panel: a terminal, files or changes panel.
    case primaryPaneOutsideChat = "focus is in a session's terminal, files or changes panel"
    /// Outside every pane: the sidebar, or a layout whose pane class changed.
    case outsidePanes = "focus is outside every session pane"
    /// No web view above the focused element, even after the tree-build wait.
    case noWebView = "focus is not inside a web view"
    /// Nothing focused, an AX error or timeout, or an address that is not a URL.
    case unavailable = "focused web view address unavailable"
}

extension ClaudeSessionJoinResolver {
    /// The Claude Desktop arm: the `local_…` id in the address of the web view
    /// holding keyboard focus, matched by exact equality against the
    /// `CLAUDE_CODE_HOST_SESSION_ID` a live session's own hooks published.
    ///
    /// The browser arm's shape with a different reader. Claude Desktop hosts
    /// each Code-tab session in a web view at
    /// `https://claude.ai/epitaxy/local_<uuid>` and exports the same id into
    /// the session's environment, whether the session runs on this Mac or on
    /// an ssh host — so, like a bridge session id, it spans both origins.
    /// The address names the session in the window's primary pane, so the
    /// reader returns it only when focus is in that pane's chat panel: focus
    /// in the second pane of a split view, a terminal panel or the sidebar is
    /// no join.
    ///
    /// Everything abstains rather than guesses, as in the browser arm. An
    /// abstention AFTER focus was found inside a session's web view says so
    /// (`focusedSessionUnmatched`): the user is looking at a Claude Code
    /// session that did not join, which the overlay badge reports even when
    /// the registry holds no live session at all — the dead-tunnel case.
    package func resolveViaDesktopSession(target: TerminalScreenTarget) async -> ClaudeJoinResolution {
        let address: String
        switch await focusedDesktopSessionURL(target.pid) {
        case .address(let found):
            address = found
        case .refused(let refusal):
            Self.abstainedDesktopSessionJoin(outcome: refusal.rawValue)
            return ClaudeJoinResolution(join: nil)
        }
        if ClaudeProjectPageURL.isProjectPage(address) {
            Self.abstainedDesktopSessionJoin(outcome: "focus is in a Claude project, whose page names no session")
            return ClaudeJoinResolution(join: nil, focusedClaudeProject: true)
        }
        guard let desktopSessionID = ClaudeDesktopSessionURL.sessionID(inWebAreaURL: address) else {
            // Never the address itself: it names what the user is looking at.
            Self.abstainedDesktopSessionJoin(outcome: "focus is not in a Claude Code session")
            return ClaudeJoinResolution(join: nil)
        }

        switch registry.resolve(desktopSessionID: desktopSessionID) {
        case .resolved(let snapshot):
            Log.claudeContext.info(
                "Claude Desktop joined to a live Claude session via its desktop session id"
            )
            return ClaudeJoinResolution(join: ClaudeSessionJoin(
                target: target,
                snapshot: snapshot,
                // Nil for the browser arm's reason: a window identity pairs a
                // SCREEN capture with its join, and this mechanism has none.
                windowID: nil,
                mechanism: .desktopSession,
                desktopSession: ClaudeDesktopSessionBinding(desktopSessionID: desktopSessionID)
            ))
        case .unknown:
            Self.abstainedDesktopSessionJoin(outcome: "no live session reports this desktop session")
        case .stale:
            Self.abstainedDesktopSessionJoin(outcome: "stale")
        case .ambiguous:
            Self.abstainedDesktopSessionJoin(outcome: "ambiguous")
        }
        return ClaudeJoinResolution(join: nil, focusedSessionUnmatched: true)
    }

    /// Outcome only. The desktop session id is a live handle to a session's
    /// context; it does not belong in the log.
    private static func abstainedDesktopSessionJoin(outcome: String) {
        Log.claudeContext.info(
            "Claude Desktop matched no session (\(outcome, privacy: .public)); Claude context withheld"
        )
        Self.noteAbstention("desktopSession: \(outcome)")
    }
}
