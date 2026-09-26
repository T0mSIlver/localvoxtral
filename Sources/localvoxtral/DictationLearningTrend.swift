import Foundation

/// Whether localvoxtral is learning the speaker, week by week, from the saved
/// dictations. Two numbers, because they are the two that move:
///
/// - **Terms spelled right by the recognizer**: of the speaker's terms (Names
///   and terms plus the confirmed learned terms) that a dictation ended up
///   containing, the share the transcript already spelled exactly.
/// - **Transcripts kept as they were**: of the polished dictations that were
///   inserted, the share whose final text is the transcript unchanged. (A
///   replacement or a pre-applied term counts as a change: the record keeps
///   the transcript and the final text, not what the model was sent.)
///
/// Neither isolates the recognizer. History only knows the terms that reached
/// the final text: a term the transcript missed and polishing also missed is
/// counted nowhere, so a week where polishing fixes fewer terms can read
/// better on both numbers. They are a trend to watch, not a measurement; the
/// replay of stored audio is the measurement, on identical input.
///
/// A value computed from the entries and the terms and nothing else, so the
/// numbers have tests. Weeks count back from `now` in 7-day steps, not
/// calendar weeks, so the last bar is always a full week.
struct DictationLearningTrend: Equatable, Sendable {
    static let weekCount = 12
    /// A week with fewer dictations than this shows no value: one dictation
    /// would swing it from 0 to 100 %.
    static let minimumDictations = 5

    struct Week: Equatable, Sendable, Identifiable {
        let start: Date
        /// Dictations whose final text holds at least one speaker term.
        var dictationsWithTerms = 0
        /// Distinct speaker terms found in the final texts, one per dictation.
        var termMentions = 0
        /// Of those, the ones the transcript already spelled exactly.
        var termsSpelledRight = 0
        var polished = 0
        var transcriptKept = 0

        var id: Date { start }

        /// Counted by dictation, not by term: five terms in one dictation are
        /// still one dictation's say.
        var termsSpelledRightShare: Double? {
            guard dictationsWithTerms >= DictationLearningTrend.minimumDictations else { return nil }
            return Double(termsSpelledRight) / Double(termMentions)
        }

        var transcriptKeptShare: Double? {
            guard polished >= DictationLearningTrend.minimumDictations else { return nil }
            return Double(transcriptKept) / Double(polished)
        }
    }

    /// Oldest first.
    var weeks: [Week] = []

    init() {}

    static func start(now: Date) -> Date {
        now.addingTimeInterval(-Double(weekCount) * 7 * 86_400)
    }

    init(entries: [DictationHistoryEntry], terms: [String], now: Date) {
        let origin = Self.start(now: now)
        weeks = (0..<Self.weekCount).map {
            Week(start: origin.addingTimeInterval(Double($0) * 7 * 86_400))
        }
        let matchers = Self.matchers(for: terms)
        for entry in entries {
            if Task.isCancelled { break }
            let offset = entry.startedAt.timeIntervalSince(origin)
            guard offset >= 0, entry.startedAt < now else { continue }
            let index = min(Int(offset / (7 * 86_400)), Self.weekCount - 1)
            // A failed insertion never showed its text anywhere; whether it
            // matched the transcript says nothing about what was inserted.
            if entry.polishRan, entry.commitSucceeded {
                weeks[index].polished += 1
                if !entry.textWasChanged {
                    weeks[index].transcriptKept += 1
                }
            }
            let (mentions, spelledRight) = Self.termCounts(in: entry, matchers: matchers)
            if mentions > 0 { weeks[index].dictationsWithTerms += 1 }
            weeks[index].termMentions += mentions
            weeks[index].termsSpelledRight += spelledRight
        }
    }

    var hasTermValues: Bool { weeks.contains { $0.termsSpelledRightShare != nil } }
    var hasPolishValues: Bool { weeks.contains { $0.transcriptKeptShare != nil } }

    // MARK: Term matching

    /// Built per count and used by that count alone: the regexes compile on
    /// first use, and most terms never get that far.
    final class TermMatcher {
        let folded: String
        /// The folded term's words (`words(in:)`). A text lacking one cannot
        /// hold the term, and a set lookup says so for a fraction of what a
        /// substring search costs.
        let foldedWords: [Substring]
        private let pattern: String

        init(folded: String, pattern: String) {
            self.folded = folded
            foldedWords = DictationLearningTrend.words(in: folded)
            self.pattern = pattern
        }

        /// Case-insensitive, whole words: the term somewhere in the text.
        private(set) lazy var anyCase = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive])
        /// The exact spelling, whole words.
        private(set) lazy var exact = try? NSRegularExpression(pattern: pattern)
    }

    /// One matcher per term, a case-insensitive duplicate dropped.
    static func matchers(for terms: [String]) -> [TermMatcher] {
        var seen = Set<String>()
        return terms.compactMap { term in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let folded = trimmed.caseFoldedForMatching
            guard !folded.isEmpty, seen.insert(folded).inserted else { return nil }
            let escaped = NSRegularExpression.escapedPattern(for: trimmed)
            // Marks count as part of a word: "Cafe" is not in a decomposed
            // "Café".
            let pattern = "(?<![\\p{L}\\p{M}\\p{N}])\(escaped)(?![\\p{L}\\p{M}\\p{N}])"
            return TermMatcher(folded: folded, pattern: pattern)
        }
    }

    /// Terms the final text contains, and of those, the ones the transcript
    /// spelled exactly. Each term counts once per dictation.
    static func termCounts(
        in entry: DictationHistoryEntry, matchers: [TermMatcher]
    ) -> (mentions: Int, spelledRight: Int) {
        let final = entry.finalText
        let foldedFinal = final.caseFoldedForMatching
        let finalWords = Set(words(in: foldedFinal))
        var mentions = 0
        var spelledRight = 0
        for matcher in matchers {
            // Cheap tests first: most terms are in most texts nowhere, and
            // twelve weeks of history times a few hundred terms is too many
            // substring searches, let alone regex runs, for a pane that is
            // opening.
            guard matcher.foldedWords.allSatisfy(finalWords.contains),
                foldedFinal.contains(matcher.folded),
                let anyCase = matcher.anyCase, matches(anyCase, final)
            else { continue }
            mentions += 1
            if let exact = matcher.exact, matches(exact, entry.rawText) { spelledRight += 1 }
        }
        return (mentions, spelledRight)
    }

    /// The runs of letters, marks and digits: what the matchers' word
    /// boundaries are drawn between. Case folding keeps a scalar on its side
    /// of that line, so a term found in a text has each of its folded words
    /// among the folded text's.
    static func words(in text: String) -> [Substring] {
        let scalars = text.unicodeScalars
        var words: [Substring] = []
        var start: String.Index?
        for index in scalars.indices {
            if isWordScalar(scalars[index]) {
                if start == nil { start = index }
            } else if let wordStart = start {
                words.append(Substring(scalars[wordStart..<index]))
                start = nil
            }
        }
        if let start { words.append(Substring(scalars[start...])) }
        return words
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .nonspacingMark, .spacingMark, .enclosingMark,
            .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
