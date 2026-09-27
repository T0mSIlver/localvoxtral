import ClaudeContextWire
import Foundation

/// How the `localvoxtral capture` commands name and find an Inbox item
/// (#923). The user tells their agent "look at the capture about X", so a
/// title, or any unique part of one, finds it as surely as its id.
package enum AgentCLICaptureLookup {
    package enum Match: Equatable {
        case found(QuickCaptureItem)
        case none
        case ambiguous([QuickCaptureItem])
    }

    /// The id's first characters, as `capture list` prints it.
    package static let shortIDLength = 8
    /// An id prefix shorter than this is read as a title.
    package static let minimumIDPrefix = 4
    package static let maxDerivedTitleCharacters = 60

    /// The first tier with any match decides: the whole id, the whole title,
    /// an id prefix, a title prefix, then a part of a title. Case and
    /// accents are ignored.
    package static func find(_ reference: String, in items: [QuickCaptureItem]) -> Match {
        let wanted = fold(reference)
        guard !wanted.isEmpty else { return .none }
        let isIDPrefix = wanted.count >= minimumIDPrefix
            && wanted.allSatisfy { $0.isHexDigit || $0 == "-" }
        let tiers: [(QuickCaptureItem) -> Bool] = [
            { $0.id.uuidString.lowercased() == wanted },
            { fold(title(of: $0)) == wanted },
            { isIDPrefix && $0.id.uuidString.lowercased().hasPrefix(wanted) },
            { fold(title(of: $0)).hasPrefix(wanted) },
            { fold(title(of: $0)).contains(wanted) },
        ]
        for tier in tiers {
            let matches = items.filter(tier)
            if matches.count == 1 { return .found(matches[0]) }
            if matches.count > 1 { return .ambiguous(matches) }
        }
        return .none
    }

    /// The draft's title, or the capture's first words while there is none.
    package static func title(of item: QuickCaptureItem) -> String {
        let drafted = QuickCaptureDraft.oneLine(item.title, limit: QuickCaptureDraft.maxTitleCharacters)
        if !drafted.isEmpty { return drafted }
        let words = QuickCaptureDraft.oneLine(item.text, limit: .max).split(separator: " ")
        var title = ""
        for word in words {
            let next = title.isEmpty ? String(word) : title + " " + word
            if next.count > maxDerivedTitleCharacters {
                return (title.isEmpty ? String(word.prefix(maxDerivedTitleCharacters - 1)) : title) + "…"
            }
            title = next
        }
        return title
    }

    package static func shortID(_ item: QuickCaptureItem) -> String {
        String(item.id.uuidString.lowercased().prefix(shortIDLength))
    }

    /// What the command reports. `detail` adds the words and the draft.
    package static func capture(_ item: QuickCaptureItem, detail: Bool) -> AgentCLICapture {
        let drafted = !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return AgentCLICapture(
            id: item.id.uuidString.lowercased(),
            capturedAt: item.capturedAt,
            project: item.projectKey.map { AgentCLIProject(key: $0, name: item.projectName ?? $0) },
            // #918 adds question, task and note; every draft is an issue
            // until then.
            kind: drafted ? "issue" : nil,
            title: title(of: item),
            state: AgentCLICapture.State(rawValue: item.state.rawValue) ?? .ready,
            repository: item.repository,
            relation: item.relation == .none ? nil : item.relation.rawValue,
            relatedIssue: item.relatedIssue,
            note: item.note,
            filedURL: item.filedURL,
            text: detail ? item.text : nil,
            body: detail && drafted ? item.body : nil,
            issueBody: detail ? item.bodyToFile : nil
        )
    }

    private static func fold(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
