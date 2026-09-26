import ClaudeContextWire
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

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
    /// Focus decides which session: the walk goes UP from the focused element
    /// to the nearest web view, so with two sessions side by side the one the
    /// user is typing into wins, and focus outside any session (the sidebar,
    /// the chat tab) is no join.
    ///
    /// Everything abstains rather than guesses, as in the browser arm.
    func resolveViaDesktopSession(target: TerminalScreenTarget) async -> ClaudeSessionJoin? {
        guard let address = await focusedDesktopSessionURL(target.pid) else {
            Self.abstainedDesktopSessionJoin(outcome: "focused web view address unavailable")
            return nil
        }
        guard let desktopSessionID = ClaudeDesktopSessionURL.sessionID(inWebAreaURL: address) else {
            // Never the address itself: it names what the user is looking at.
            Self.abstainedDesktopSessionJoin(outcome: "focus is not in a Claude Code session")
            return nil
        }

        switch registry.resolve(desktopSessionID: desktopSessionID) {
        case .resolved(let snapshot):
            Log.claudeContext.info(
                "Claude Desktop joined to a live Claude session via its desktop session id"
            )
            return ClaudeSessionJoin(
                target: target,
                snapshot: snapshot,
                // Nil for the browser arm's reason: a window identity pairs a
                // SCREEN capture with its join, and this mechanism has none.
                windowID: nil,
                mechanism: .desktopSession,
                desktopSession: ClaudeDesktopSessionBinding(desktopSessionID: desktopSessionID)
            )
        case .unknown:
            Self.abstainedDesktopSessionJoin(outcome: "no live session reports this desktop session")
            return nil
        case .stale:
            Self.abstainedDesktopSessionJoin(outcome: "stale")
            return nil
        case .ambiguous:
            Self.abstainedDesktopSessionJoin(outcome: "ambiguous")
            return nil
        }
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
