import Foundation

/// The user's stop phrases (#1696): a dictation that is only one of them
/// ends the joined Claude Code session's running turn through its mod. Off
/// until the user sets one: the list is empty by default.
package enum SpokenAbortPhrases {
    /// A phrase longer than this is a sentence, not a command.
    package static let maximumWords = SendTriggerPhrases.maximumWords
    package static let maximumPhrases = SendTriggerPhrases.maximumPhrases

    /// Why a list was refused. The message is the Settings row's footer.
    package enum Refusal: Error, Equatable, Sendable {
        case tooShort(String)
        case tooLong(String)
        case tooMany
        case sendPhrase(String)

        package var message: String {
            switch self {
            case .tooShort(let phrase):
                "\u{201C}\(phrase)\u{201D} is too short: use at least 3 letters."
            case .tooLong(let phrase):
                "\u{201C}\(phrase)\u{201D} is too long: use at most \(maximumWords) words."
            case .tooMany:
                "Use at most \(maximumPhrases) phrases."
            case .sendPhrase(let phrase):
                "\u{201C}\(phrase)\u{201D} is already a send phrase."
            }
        }
    }

    /// The phrases to store, normalized and without repeats, or why the
    /// list is refused. An empty list is valid and turns the stop off.
    /// The whole dictation must be the phrase, so a common word is allowed:
    /// "stop" said alone means stop.
    package static func validate(
        _ phrases: [String], sendPhrases: [String]
    ) -> Result<[String], Refusal> {
        var kept: [String] = []
        for raw in phrases {
            let normalized = SendNowCommandParser.normalizedSegment(raw)
            if normalized.isEmpty {
                if raw.trimmed.isEmpty { continue }
                return .failure(.tooShort(raw.trimmed))
            }
            let words = normalized.split(separator: " ")
            if words.count > maximumWords { return .failure(.tooLong(raw.trimmed)) }
            if normalized.filter(\.isLetter).count < 3 { return .failure(.tooShort(raw.trimmed)) }
            // A send phrase alone already presses Return; one word may not
            // mean both.
            if sendPhrases.contains(normalized) { return .failure(.sendPhrase(raw.trimmed)) }
            if !kept.contains(normalized) { kept.append(normalized) }
        }
        guard kept.count <= maximumPhrases else { return .failure(.tooMany) }
        return .success(kept)
    }

    /// A stored list read back at launch. Anything that no longer validates
    /// loads as no phrase at all: the stop is opt-in.
    package static func loaded(_ stored: [String]?, sendPhrases: [String]) -> [String] {
        guard let stored, case .success(let phrases) = validate(stored, sendPhrases: sendPhrases) else {
            return []
        }
        return phrases
    }

    /// Whether the whole dictation is one of `phrases`, punctuation and case
    /// aside.
    package static func isStopPhrase(_ text: String, phrases: [String]) -> Bool {
        guard !phrases.isEmpty else { return false }
        let normalized = SendNowCommandParser.normalizedSegment(text)
        return !normalized.isEmpty && phrases.contains(normalized)
    }
}
