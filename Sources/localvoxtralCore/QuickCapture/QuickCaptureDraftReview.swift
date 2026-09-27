import Foundation

// Ready drafts in the needs-you cue, and their spoken review (#927, #909
// direction 1). Owner rulings, 2026-09-27: a finished draft lights the menu
// bar mark and the popover line, with no banner and no sound, and only at the
// user's next break (a dictation stops, or an agent the user was watching
// finishes). The answer shortcut opens the oldest one in the overlay, where
// "file it" files, "drop it" discards, and anything else is a change the
// drafter reruns with. The overlay shows one draft, so a spoken "file it"
// can only mean that one.

/// The drafts the cue holds: `held` wait for the user's next break, `shown`
/// light the mark. Kept in memory: a draft ready before a relaunch waits in
/// the Inbox without a cue.
package struct QuickCaptureDraftCue: Equatable, Sendable {
    package struct Entry: Equatable, Sendable {
        package var id: UUID
        package var projectName: String
        package var readyAt: Date

        package init(id: UUID, projectName: String, readyAt: Date) {
            self.id = id
            self.projectName = projectName
            self.readyAt = readyAt
        }
    }

    package private(set) var held: [Entry] = []
    package private(set) var shown: [Entry] = []

    package init() {}

    /// A draft finished. It waits for the next break, even when it was shown
    /// before (a redraft is a new draft).
    package mutating func draftReady(_ entry: Entry) {
        remove(id: entry.id)
        held.append(entry)
    }

    /// The user reached a break: every held draft is shown. Returns whether
    /// anything changed.
    @discardableResult
    package mutating func atBreak() -> Bool {
        guard !held.isEmpty else { return false }
        shown.append(contentsOf: held)
        held.removeAll()
        return true
    }

    package mutating func remove(id: UUID) {
        held.removeAll { $0.id == id }
        shown.removeAll { $0.id == id }
    }

    /// Keeps the drafts `stillReady` says are still ready drafts under the
    /// project they were cued for: one filed, discarded, moved or being
    /// redrafted leaves the cue.
    package mutating func retain(where stillReady: (Entry) -> Bool) {
        held.removeAll { !stillReady($0) }
        shown.removeAll { !stillReady($0) }
    }

    package mutating func clear() {
        held.removeAll()
        shown.removeAll()
    }

    /// The shown drafts, oldest first: the order the answer shortcut opens them.
    package var shownOldestFirst: [Entry] {
        shown.sorted { ($0.readyAt, $0.id.uuidString) < ($1.readyAt, $1.id.uuidString) }
    }
}

/// One draft as the overlay showed it: what a spoken "file it" files, and
/// only while the Inbox still holds exactly this.
package struct QuickCaptureDraftSnapshot: Equatable, Sendable {
    package var id: UUID
    package var projectName: String
    package var title: String
    package var body: String

    package init(id: UUID, projectName: String, title: String, body: String) {
        self.id = id
        self.projectName = projectName
        self.title = title
        self.body = body
    }

    /// The overlay's lines of the body: the first `maxExcerptCharacters`,
    /// cut at a word, so the panel's height can be measured from the text.
    package static let maxExcerptCharacters = 240

    package var bodyExcerpt: String {
        let flat = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flat.count > Self.maxExcerptCharacters else { return flat }
        let cut = flat.prefix(Self.maxExcerptCharacters)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(atWord) + "…"
    }
}

/// What the words of a review dictation ask for.
package enum QuickCaptureSpokenReview: Equatable, Sendable {
    case file
    case drop
    /// Anything else said: the drafter reruns with it.
    case change(String)
    /// Nothing said.
    case nothing

    package static let filePhrase = "file it"
    package static let dropPhrase = "drop it"

    /// A trailing send phrase ends the dictation (#839) and is never part of
    /// the change. "file it" and "drop it" count only as the whole of what
    /// was said, so "file it under polish" is a change.
    package static func parse(_ text: String, sendPhrases: [String]) -> QuickCaptureSpokenReview {
        let words: String
        switch SendNowCommandParser.parse(text, triggerPhrases: sendPhrases) {
        case .none, .pressReturn: return .nothing
        case .insertTextAndPressReturn(let before): words = before
        case .insertText(let all): words = all
        }
        switch SendNowCommandParser.normalizedSegment(words) {
        case "": return .nothing
        case filePhrase: return .file
        case dropPhrase: return .drop
        default: return .change(words.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Whether the words are "file it" or "drop it" alone, which stop the
    /// dictation by voice like a send phrase.
    package static func isCommand(_ text: String) -> Bool {
        [filePhrase, dropPhrase].contains(SendNowCommandParser.normalizedSegment(text))
    }

    /// What the drafter reads for a redraft: the dictated words, the draft
    /// the user heard about, and every change asked for so far. The drafter's
    /// prompt is unchanged; this rides in its capture text.
    package static func redraftCapture(original: String, title: String, body: String, changes: [String]) -> String {
        var text = original + "\n\nA first draft of this idea was:\n\nTitle: \(title)\n\n\(body)"
        text += changes.count == 1
            ? "\n\nRewrite the draft with this change from the user: \(changes[0])"
            : "\n\nRewrite the draft with these changes from the user, in order:\n"
                + changes.map { "- \($0)" }.joined(separator: "\n")
        return text
    }
}

/// The popover sentences of the draft cue and the review.
package enum QuickCaptureDraftCueText {
    /// "Draft ready: Inbox for " is 23 characters of the popover's 44.
    package static let maxProjectNameLength = 21

    package static func sentence(_ entry: QuickCaptureDraftCue.Entry) -> String {
        let name = AgentAttentionText.shortened(entry.projectName, to: maxProjectNameLength)
        return "Draft ready: Inbox for \(name)"
    }
}
