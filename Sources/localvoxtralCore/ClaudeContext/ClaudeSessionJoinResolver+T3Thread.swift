import ClaudeContextWire
import Foundation

/// What one read of T3 Code's focused web view found: the address of the view
/// whose thread composer holds focus, or why the reader gave none
/// (`AXT3CodeThreadURLReader`). Each refusal reaches the dictation's
/// abstention causes as itself, as Claude Desktop's do.
package enum T3CodeFocusRead: Equatable, Sendable {
    case address(String)
    case refused(T3CodeFocusRefusal)

    package var foundAddress: String? {
        guard case .address(let address) = self else { return nil }
        return address
    }
}

/// Why the T3 Code reader gave no address. Each raw value is the abstention
/// cause the diagnostic record keeps: a category, never an address.
package enum T3CodeFocusRefusal: String, Equatable, Sendable {
    /// Focus is in the window but not in a thread's composer: the sidebar,
    /// the integrated terminal or browser, a dialog, or a layout whose
    /// composer class changed.
    case outsideComposer = "focus is not in a T3 Code thread's composer"
    /// No web view above the focused element, even after the tree-build wait.
    case noWebView = "focus is not inside a T3 Code web view"
    /// Nothing focused, an AX error or timeout, or an address that is not a URL.
    case unavailable = "focused T3 Code view address unavailable"
}

extension ClaudeSessionJoinResolver {
    /// The T3 Code arm (LVX-55): the thread id in the address of the web view
    /// whose thread composer holds keyboard focus, matched by exact equality
    /// against the `T3CODE_THREAD_ID` a live session's own hooks published.
    ///
    /// The Claude Desktop arm's shape with a different reader and key. T3
    /// Code shows a thread at `t3code://app/#/<environmentId>/<threadId>` and
    /// runs the thread's Claude Code session with the same thread id in its
    /// environment, on this Mac or on a machine T3 Code connects to, so the id
    /// spans both origins. Focus outside the composer (T3's own terminal, its
    /// browser, the sidebar) is no join: the dictation is not going to the
    /// thread's agent.
    package func resolveViaT3Thread(target: TerminalScreenTarget) async -> ClaudeJoinResolution {
        let address: String
        switch await focusedT3ThreadURL(target.pid) {
        case .address(let found):
            address = found
        case .refused(let refusal):
            Self.abstainedT3ThreadJoin(outcome: refusal.rawValue)
            return ClaudeJoinResolution(join: nil)
        }
        guard let threadID = T3CodeThreadURL.threadID(inWebAreaURL: address) else {
            // A new-thread draft, settings or another page. Never the address
            // itself: it names what the user is looking at.
            Self.abstainedT3ThreadJoin(outcome: "focus is not in a T3 Code thread")
            return ClaudeJoinResolution(join: nil)
        }

        switch registry.resolve(t3ThreadID: threadID) {
        case .resolved(let snapshot):
            Log.claudeContext.info("T3 Code joined to a live Claude session via its thread id")
            return ClaudeJoinResolution(join: ClaudeSessionJoin(
                target: target,
                snapshot: snapshot,
                // No screen capture to pair, as for Claude Desktop.
                windowID: nil,
                mechanism: .t3Thread,
                t3Thread: ClaudeT3ThreadBinding(t3ThreadID: threadID)
            ))
        case .unknown:
            Self.abstainedT3ThreadJoin(outcome: "no live session reports this T3 Code thread")
        case .stale:
            Self.abstainedT3ThreadJoin(outcome: "stale")
        case .ambiguous:
            Self.abstainedT3ThreadJoin(outcome: "ambiguous")
        }
        return ClaudeJoinResolution(join: nil, focusedSessionUnmatched: true)
    }

    /// The `.t3Thread` half of `isStillLive`: the bound id must still resolve
    /// to THIS session alone, re-asked for the desktop arm's reason.
    func t3ThreadStillResolves(_ join: ClaudeSessionJoin) -> Bool {
        guard let binding = join.t3Thread,
              case .resolved(let current) = registry.resolve(t3ThreadID: binding.t3ThreadID),
              current.sessionID == join.snapshot.sessionID
        else {
            Log.claudeContext.info(
                "T3 Code thread no longer resolves to this session alone; Claude context withheld"
            )
            return false
        }
        return true
    }

    /// Outcome only. The thread id is a live handle to a session's context;
    /// it does not belong in the log.
    private static func abstainedT3ThreadJoin(outcome: String) {
        Log.claudeContext.info(
            "T3 Code matched no session (\(outcome, privacy: .public)); Claude context withheld"
        )
        Self.noteAbstention("t3Thread: \(outcome)")
    }
}
