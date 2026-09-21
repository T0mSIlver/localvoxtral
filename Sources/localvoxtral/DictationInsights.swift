import Foundation

/// The stretch of history the Insights pane counts.
enum DictationInsightsPeriod: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .allTime: return "All time"
        }
    }

    /// Nil for all time.
    func start(now: Date) -> Date? {
        switch self {
        case .week: return now.addingTimeInterval(-7 * 86_400)
        case .month: return now.addingTimeInterval(-30 * 86_400)
        case .allTime: return nil
        }
    }
}

/// What a set of saved dictations adds up to. A value computed from the
/// entries and nothing else, so every number here has a test.
struct DictationInsights: Equatable, Sendable {
    /// The speed the saving is measured against. 40 words per minute is the
    /// usual figure for an average typist.
    static let typingWordsPerMinute = 40.0
    /// A recurring fix is one polishing made in at least this many dictations:
    /// the bar `LearnedTerms` uses for a habit rather than a repeat.
    static let recurringFixMinimumDictations = 3
    static let maxRecurringFixes = 8
    static let maxApps = 5
    /// A change longer than this on either side is a rephrasing, not a
    /// misheard word. Four covers a spoken file name ("local voxtral dot js").
    static let maxFixWords = 4
    /// One dictation cannot count for more than this. The start and end times
    /// are wall-clock, so a Mac that slept mid-dictation would otherwise own
    /// the total.
    static let maxDictationSeconds: TimeInterval = 3_600

    struct RecurringFix: Equatable, Sendable, Identifiable {
        /// What the recognizer wrote, lowercased.
        let heard: String
        /// What polishing wrote instead.
        let written: String
        let dictations: Int

        var id: String { "\(heard)\u{1F}\(written)" }
    }

    private struct FixKey: Hashable {
        let heard: String
        let written: String
    }

    struct AppCount: Equatable, Sendable, Identifiable {
        let bundleID: String
        let dictations: Int

        var id: String { bundleID }
    }

    var dictations = 0
    /// Words of the text each dictation ended up as.
    var words = 0
    /// Start to finish of every dictation, polishing wait taken out.
    var dictatingSeconds: TimeInterval = 0
    var notInserted = 0
    var polishFailed = 0
    /// Dictations a polish request answered for, whether or not it changed them.
    var polishRan = 0
    /// Of those, the ones it changed. A dictation only the replacement
    /// dictionary changed is in neither count.
    var polishChanged = 0
    var medianPolishSeconds: Double?
    var slowPolishSeconds: Double?
    var recurringFixes: [RecurringFix] = []
    var topApps: [AppCount] = []

    /// Nil under ten seconds of dictating, where the ratio is noise.
    var wordsPerMinute: Double? {
        guard dictatingSeconds >= 10 else { return nil }
        return Double(words) / (dictatingSeconds / 60)
    }

    /// What typing the same words would have taken, less what dictating them
    /// took. Never negative: a slow day is not a debt.
    var secondsSavedOverTyping: TimeInterval {
        max(0, Double(words) / Self.typingWordsPerMinute * 60 - dictatingSeconds)
    }

    init() {}

    init(entries: [DictationHistoryEntry]) {
        var polishSeconds: [Double] = []
        var fixDictations: [FixKey: Int] = [:]
        var appCounts: [String: Int] = [:]

        for entry in entries {
            // The pane cancels a count it no longer wants; what is returned
            // then is dropped unread.
            if Task.isCancelled { break }
            dictations += 1
            words += TranscriptDiff.wordRanges(in: entry.finalText).count
            let elapsed = entry.finishedAt.timeIntervalSince(entry.startedAt)
                - (entry.polishingDurationSeconds ?? 0)
            dictatingSeconds += min(max(0, elapsed), Self.maxDictationSeconds)
            if !entry.commitSucceeded { notInserted += 1 }
            if entry.status == .llmFailed { polishFailed += 1 }
            if entry.polishRan, let seconds = entry.polishingDurationSeconds {
                polishRan += 1
                polishSeconds.append(seconds)
            }
            if let bundleID = entry.targetAppBundleID, !bundleID.isEmpty {
                appCounts[bundleID, default: 0] += 1
            }
            if entry.polishRan, entry.textWasChanged {
                polishChanged += 1
                // A set: the same fix twice in one dictation is one dictation.
                let fixes = Self.fixes(in: entry).map { FixKey(heard: $0.heard, written: $0.written) }
                for fix in Set(fixes) { fixDictations[fix, default: 0] += 1 }
            }
        }

        polishSeconds.sort()
        medianPolishSeconds = Self.median(of: polishSeconds)
        slowPolishSeconds = Self.percentile(0.9, of: polishSeconds)
        recurringFixes = fixDictations
            .filter { $0.value >= Self.recurringFixMinimumDictations }
            .map { RecurringFix(heard: $0.key.heard, written: $0.key.written, dictations: $0.value) }
            .sorted { ($0.dictations, $1.heard) > ($1.dictations, $0.heard) }
            .prefix(Self.maxRecurringFixes).map { $0 }
        topApps = appCounts.map { AppCount(bundleID: $0.key, dictations: $0.value) }
            .sorted { ($0.dictations, $1.bundleID) > ($1.dictations, $0.bundleID) }
            .prefix(Self.maxApps).map { $0 }
    }

    static func median(of sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Nearest-rank, so the answer is always a wait that happened.
    static func percentile(_ fraction: Double, of sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// The word-for-word replacements polishing made in one dictation: short
    /// stretches where it wrote something else, not ones it only dropped
    /// (fillers), only added, only re-punctuated, or only capitalized because
    /// a sentence starts there.
    static func fixes(in entry: DictationHistoryEntry) -> [RecurringFix] {
        guard entry.polishRan, let polished = entry.polishedText else { return [] }
        let raw = entry.rawText
        return TranscriptDiff.hunks(from: raw, to: polished).compactMap { hunk in
            guard (1...maxFixWords).contains(hunk.removed.count),
                (1...maxFixWords).contains(hunk.added.count),
                let firstAdded = hunk.added.first
            else { return nil }
            // A dropped filler next to a real change lands in the same
            // stretch; without this "um so" → "So" would top every list.
            let heard = hunk.removed.map { bare(raw[$0]) }
                .filter { !$0.isEmpty && !fillers.contains($0.lowercased()) }
                .joined(separator: " ")
            let written = hunk.added.map { bare(polished[$0]) }.filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !heard.isEmpty, !written.isEmpty, heard != written else { return nil }
            // The spoken clipboard marker is stored as its placeholder, never
            // as the clipboard's content. That is the macro's work, not a fix.
            guard !written.contains(bare(Substring(ClipboardPayloadMacro.placeholder))) else {
                return nil
            }
            if heard.lowercased() == written.lowercased() {
                // Casing alone. Worth counting for a name ("claude code"),
                // not for the first word of a sentence.
                guard !startsSentence(firstAdded, in: polished) else { return nil }
                guard written.contains(where: \.isUppercase) else { return nil }
            }
            return RecurringFix(heard: heard.lowercased(), written: written, dictations: 1)
        }
    }

    /// Hesitations polishing drops. Not a language model of them: the ones
    /// Voxtral writes down in English and French.
    static let fillers: Set<String> = [
        "um", "uh", "uhm", "er", "erm", "ah", "eh", "hm", "hmm", "mm", "euh", "heu", "hum",
    ]

    /// The word without the punctuation around it; what is inside stays
    /// (`localvoxtral.js`, `--dry-run`'s hyphen between letters).
    static func bare(_ word: Substring) -> String {
        let edge = CharacterSet.punctuationCharacters.union(.symbols)
        func isEdge(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy(edge.contains)
        }
        var trimmed = word
        while let first = trimmed.first, isEdge(first) { trimmed = trimmed.dropFirst() }
        while let last = trimmed.last, isEdge(last) { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    private static func startsSentence(_ word: Range<String.Index>, in text: String) -> Bool {
        let before = text[..<word.lowerBound]
        guard let previous = before.last(where: { !$0.isWhitespace || $0.isNewline }) else {
            return true
        }
        return previous.isNewline || ".!?:".contains(previous)
    }
}

/// "2 h 14 min", "14 min", "45 s": the app's own words rather than a
/// formatter's, so the pane reads the same in every locale the rest of it
/// does not follow either.
enum DictationInsightsText {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = (total + 30) / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func share(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "—" }
        return (Double(part) / Double(whole)).formatted(.percent.precision(.fractionLength(0)))
    }
}
