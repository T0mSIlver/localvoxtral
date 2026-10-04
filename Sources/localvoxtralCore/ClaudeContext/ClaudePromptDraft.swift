import ClaudeContextWire
import Foundation

/// What a Claude Code session's prompt box held when the dictation stopped,
/// as its mod read it (`$.prompt.read`, #1406): the text around the cursor
/// and where the cursor sits.
///
/// The person's own unsent words. They go to polish only under the session
/// block's gates, and never into a log or a diagnostic record
/// (`docs/agent/invariants.md`, "The prompt draft").
package struct ClaudePromptDraft: Sendable, Equatable {
    package let sessionID: String
    /// The text before the cursor.
    package let beforeCursor: String
    /// The text after the cursor.
    package let afterCursor: String

    package init(sessionID: String, beforeCursor: String, afterCursor: String) {
        self.sessionID = sessionID
        self.beforeCursor = beforeCursor
        self.afterCursor = afterCursor
    }

    /// The draft a `draft` reply carries, or nil for a reply that is not one:
    /// not `ok`, another session's, no text, or a cursor outside the text.
    package init?(reply: ClaudeModChannelWire.Reply, sessionID: String) {
        guard reply.ok, reply.sessionID == sessionID, let text = reply.text else { return nil }
        let utf16 = text.utf16
        let offset = reply.cursor ?? utf16.count
        guard offset >= 0, offset <= utf16.count,
              let cursor = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
              let split = cursor.samePosition(in: text)
        else { return nil }
        self.init(
            sessionID: sessionID,
            beforeCursor: String(text[..<split]),
            afterCursor: String(text[split...])
        )
    }

    /// How long the stop waits for the mod's answer. The repository reads
    /// it overlaps take longer, so it rarely costs the commit anything.
    package static let readTimeout: Duration = .milliseconds(1500)

    /// Whether `join`'s prompt box is this Mac's to ask about: a Claude Code
    /// session on this Mac, joined by a mechanism that names it exactly. A
    /// remote session's mod has no channel to the app (#1412).
    package static func isReadable(through join: ClaudeSessionJoin) -> Bool {
        let exact: [ClaudeSessionJoinMechanism] = [.ttyDevice, .herdrPane, .cmuxSurface, .desktopSession]
        return join.snapshot.agent == .claude
            && join.snapshot.origin.isLocalAuthenticated
            && exact.contains(join.mechanism)
    }

    /// Whether this draft, rather than the guess from the last commit,
    /// decides the commit's leading space. An empty answer from Claude
    /// Desktop does not: a surface that draws its own prompt box gives the
    /// mod `""` whatever it holds (`$.prompt.read`), and the Code tab binds
    /// none: its fill answers `no_composer` (measured on Claude Code
    /// 2.1.287, #1643).
    package func decidesLeadingSpace(for join: ClaudeSessionJoin) -> Bool {
        guard join.snapshot.sessionID == sessionID else { return false }
        return !isEmpty || join.mechanism != .desktopSession
    }

    package var isEmpty: Bool { beforeCursor.isEmpty && afterCursor.isEmpty }

    /// Whether a commit at the cursor needs a space in front: the cursor
    /// follows a character that is not whitespace. An empty box, or a cursor
    /// at the start or after a space or newline, takes the text as it is, so
    /// `/compact` stays a command (#802).
    package var commitNeedsLeadingSpace: Bool {
        guard let last = beforeCursor.last else { return false }
        return !last.isWhitespace
    }

    /// Heads the draft's text before the cursor in the session block. The
    /// diagnostic record finds the draft by it to leave it out.
    package static let beforeCursorLabel =
        "unsent text already in the prompt box, which the working text continues at the cursor (do not repeat it): "
    /// Heads the draft's text after the cursor, when there is any.
    package static let afterCursorLabel = "unsent text after the cursor in the prompt box: "

    /// The draft as lines of the session block: one line per side of the
    /// cursor, so a budget cut keeps or drops each side whole and the record
    /// withholds it from its label to the line's end. Empty for an empty box.
    package var sessionBlockLines: [String] {
        var lines: [String] = []
        if !beforeCursor.isEmpty {
            lines.append(Self.beforeCursorLabel + Self.oneLine(beforeCursor))
        }
        if !afterCursor.isEmpty {
            lines.append(Self.afterCursorLabel + Self.oneLine(afterCursor))
        }
        return lines
    }

    /// The draft's own line breaks as ` / `, so it stays one line.
    package static func oneLine(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: " / ")
    }
}

extension ClaudeModChannelHub {
    /// Asks `sessionID`'s mod for its prompt box. Nil when the session has
    /// no mod, the mod is older than `draft`, or no answer came in `timeout`;
    /// the caller then knows nothing about the box.
    package func promptDraft(of sessionID: String, timeout: Duration) async -> ClaudePromptDraft? {
        if case .read(let draft) = await readPromptDraft(of: sessionID, timeout: timeout) { return draft }
        return nil
    }

    /// What a `draft` request found out about the session's prompt box.
    package enum PromptDraftRead: Equatable, Sendable {
        /// The box, or nil when the mod said nothing about it.
        case read(ClaudePromptDraft?)
        /// The mod's process left the session (`/clear` or resume, #1651):
        /// whatever pane showed it shows another session now.
        case sessionChanged
    }

    /// `promptDraft`, keeping a `session_changed` refusal, which a caller
    /// that writes into the session must not treat as "no answer".
    package func readPromptDraft(of sessionID: String, timeout: Duration) async -> PromptDraftRead {
        guard isAttached(sessionID) else { return .read(nil) }
        guard let reply = await send(.init(kind: .draft), to: sessionID, timeout: timeout) else {
            Log.claudeContext.notice("Mod channel: no draft from the session's mod")
            return .read(nil)
        }
        if !reply.ok, reply.reason == ClaudeModChannelWire.Reply.sessionChangedReason {
            return .sessionChanged
        }
        guard let draft = ClaudePromptDraft(reply: reply, sessionID: sessionID) else {
            Log.claudeContext.notice(
                "Mod channel: the mod did not give its draft (\(reply.reason ?? "malformed", privacy: .public))"
            )
            return .read(nil)
        }
        // Counts only: the draft is the person's unsent words.
        Log.claudeContext.info(
            "Mod channel: draft read, \(draft.beforeCursor.count, privacy: .public) characters before the cursor, \(draft.afterCursor.count, privacy: .public) after"
        )
        return .read(draft)
    }
}
