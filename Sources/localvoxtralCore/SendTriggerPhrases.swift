import Foundation

/// The user's spoken send phrases (#839): the words that press Return at the
/// end of a dictation, in Live Auto-Paste and in Overlay Buffer, and stop an
/// Overlay Buffer dictation by voice. `SendNowCommandParser` matches them.
package enum SendTriggerPhrases {
    /// A phrase longer than this is a sentence, not a command.
    package static let maximumWords = 4
    package static let maximumPhrases = 8

    /// Why a list was refused. The message is the Settings row's footer.
    package enum Refusal: Error, Equatable, Sendable {
        case empty
        case commonWord(String)
        case tooLong(String)
        case tooMany

        package var message: String {
            switch self {
            case .empty:
                "Enter at least one phrase."
            case .commonWord(let phrase):
                "\u{201C}\(phrase)\u{201D} is too common a word: it would send in the middle of what you say."
            case .tooLong(let phrase):
                "\u{201C}\(phrase)\u{201D} is too long: use at most \(maximumWords) words."
            case .tooMany:
                "Use at most \(maximumPhrases) phrases."
            }
        }
    }

    /// The list typed in Settings: comma- or newline-separated phrases.
    package static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline }).map(String.init)
    }

    /// The phrases to store, normalized (lowercase, single spaces, no edge
    /// punctuation) and without repeats, or why the list is refused. Any
    /// refused phrase refuses the whole list, so what is saved is always
    /// what the row shows.
    package static func validate(_ phrases: [String]) -> Result<[String], Refusal> {
        var kept: [String] = []
        for raw in phrases {
            let normalized = SendNowCommandParser.normalizedSegment(raw)
            guard !normalized.isEmpty else {
                // "send it, , send now": an empty entry between commas is
                // a typo, not a phrase.
                if raw.trimmed.isEmpty { continue }
                return .failure(.empty)
            }
            let words = normalized.split(separator: " ")
            if words.count > maximumWords { return .failure(.tooLong(raw.trimmed)) }
            if words.count == 1, isCommonWord(normalized) {
                return .failure(.commonWord(raw.trimmed))
            }
            if !kept.contains(normalized) { kept.append(normalized) }
        }
        guard !kept.isEmpty else { return .failure(.empty) }
        guard kept.count <= maximumPhrases else { return .failure(.tooMany) }
        return .success(kept)
    }

    /// A stored list read back at launch. Anything that no longer
    /// validates (edited defaults, a list from a build with other rules)
    /// falls back to the default, never to no trigger at all.
    package static func loaded(_ stored: [String]?) -> [String] {
        guard let stored, case .success(let phrases) = validate(stored) else {
            return SendNowCommandParser.defaultTriggerPhrases
        }
        return phrases
    }

    /// A one-word phrase is refused when it is a word people say in any
    /// prompt, or two letters or fewer. Multi-word phrases are allowed even
    /// when every word is common ("send it"): the parser only fires on the
    /// last words of a dictation, and a pair is rare there by chance.
    package static func isCommonWord(_ word: String) -> Bool {
        word.count <= 2 || commonWords.contains(word)
    }

    /// Frequent English words, plus the words the other voice commands
    /// start with ("go to", "call this session", "send that to").
    private static let commonWords: Set<String> = [
        "about", "after", "again", "all", "also", "and", "any", "are", "back", "because",
        "been", "before", "but", "call", "can", "come", "could", "day", "did", "done",
        "down", "each", "even", "fine", "first", "for", "from", "get", "give", "going",
        "good", "got", "had", "has", "have", "her", "here", "him", "his", "how",
        "into", "its", "just", "know", "last", "later", "like", "look", "make", "more",
        "most", "much", "name", "need", "new", "next", "not", "now", "okay", "one",
        "only", "other", "our", "out", "over", "please", "right", "run", "said", "same",
        "say", "see", "send", "she", "should", "some", "stop", "submit", "take", "than",
        "thank", "thanks", "that", "the", "their", "them", "then", "there", "these", "they",
        "thing", "think", "this", "those", "time", "too", "try", "two", "under", "use",
        "very", "want", "was", "way", "well", "went", "were", "what", "when", "where",
        "which", "while", "who", "why", "will", "with", "work", "would", "yeah", "yes",
        "you", "your", "enter", "return", "go", "ok", "test", "tests", "fix", "file",
        "code", "change", "yep", "sure", "cool", "great", "nice", "finish",
    ]
}

/// How long a trailing send phrase waits for new words before it stops the
/// dictation (#1009): the setting "Wait before pressing Return". The default
/// was measured on the owner's 138 Overlay Buffer dictations with audio
/// (2026-09-26/27, PR for #839): 9.4 % of speech pauses reach 2 s and 5.6 %
/// reach 3 s, and the one "send it" said mid-sentence was followed by a
/// 2.4 s pause. A false stop sends half a prompt and cannot be undone; a
/// late one costs a key press at most. Nothing goes under 1 s: streaming ASR
/// delivers words 0.5–1 s behind speech, so a shorter wait can fire before
/// the rest of the sentence arrives.
package enum SpokenStopWait: Int, CaseIterable, Identifiable, Sendable {
    case oneSecond = 1000
    case oneAndAHalfSeconds = 1500
    case twoSeconds = 2000
    case threeSeconds = 3000

    package static let `default` = SpokenStopWait.threeSeconds

    package var id: Int { rawValue }

    package var duration: Duration { .milliseconds(rawValue) }

    /// "1 s", "1.5 s": whole seconds without a decimal.
    package var displayName: String {
        rawValue % 1000 == 0 ? "\(rawValue / 1000) s" : "\(Double(rawValue) / 1000) s"
    }
}

/// Stopping a dictation by voice (#839, #840): a trailing send phrase
/// followed by silence stops the dictation the way the stop key does. The
/// one place that decides, so a shortcut model can call it.
package enum SpokenStopRule {
    /// How the dictation was started, as far as a voice stop cares.
    package enum Gesture: Equatable, Sendable {
        /// Toggled on by a tap or press: the next press stops it.
        case toggled
        /// Held (push to talk): the release is the stop.
        case held
        /// A capture to the Inbox, toggled.
        case quickCapture
    }

    /// Whether a trailing send phrase stops a dictation started this way.
    /// A held dictation never waits for silence: its release commits at
    /// once, and a stop while the key is still down would leave a release
    /// with nothing to stop.
    package static func stopsByVoice(_ gesture: Gesture) -> Bool {
        switch gesture {
        case .toggled, .quickCapture: true
        case .held: false
        }
    }

    /// Whether the dictation's words end in one of `phrases`.
    package static func endsInSendPhrase(_ text: String, phrases: [String]) -> Bool {
        SendNowCommandParser.parse(text, triggerPhrases: phrases).pressesReturn
    }
}
