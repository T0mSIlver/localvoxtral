import ClaudeContextWire
#if canImport(CoreGraphics)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#endif
import Foundation

extension ClaudeSessionJoinResolver {
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
    package func resolveViaBrowserTab(target: TerminalScreenTarget) async -> ClaudeSessionJoin? {
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
}
