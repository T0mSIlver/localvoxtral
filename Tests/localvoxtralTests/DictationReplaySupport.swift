import Foundation
@testable import localvoxtral

/// The pure half of `testReplayStoredDictations`: reading an exported replay
/// set, and scoring what each arm wrote against the text the user kept.
///
/// A replay set is a directory `scripts/export-dictation-replay.sh` fills on
/// the user's Mac:
///
///   default.store            a consistent copy of the history store
///   dictation-audio/<id>.wav the opt-in recordings, one per dictation
///   learned-terms.json       the learned terms, as the app stores them
///   speaker-terms.json       Names and terms, a JSON array of strings
enum DictationReplaySupport {
    struct ReplaySetError: Error, CustomStringConvertible {
        let description: String
    }

    struct ReplaySet {
        let storeURL: URL
        let audioDirectory: URL
        /// Confirmed learned terms from every project: what "today" adds.
        let learnedTerms: [String]
        /// Names and terms, given to both arms.
        let speakerTerms: [String]
    }

    static func loadSet(at directory: URL) throws -> ReplaySet {
        let storeURL = directory.appendingPathComponent("default.store")
        let audioDirectory = directory.appendingPathComponent("dictation-audio", isDirectory: true)
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            throw ReplaySetError(description: "no default.store in \(directory.path)")
        }
        guard FileManager.default.fileExists(atPath: audioDirectory.path) else {
            throw ReplaySetError(description: "no dictation-audio/ in \(directory.path)")
        }
        let learned = (try? Data(contentsOf: directory.appendingPathComponent("learned-terms.json")))
            .map(LearnedTermStore.terms(fromFileContents:)) ?? LearnedTerms()
        let speaker = (try? Data(contentsOf: directory.appendingPathComponent("speaker-terms.json")))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return ReplaySet(
            storeURL: storeURL,
            audioDirectory: audioDirectory,
            learnedTerms: learned.confirmedEverywhere().map(\.term),
            speakerTerms: SpeakerTerms.sanitized(speaker)
        )
    }

    /// Of the terms the kept text spells, how many the output spells the same
    /// way. Whole words, exact spelling, each term once.
    static func termHits(
        terms: [String], reference: String, output: String
    ) -> (present: Int, recalled: Int) {
        var seen = Set<String>()
        var present = 0
        var recalled = 0
        for term in terms where seen.insert(term.caseFoldedForMatching).inserted {
            guard contains(term, in: reference) else { continue }
            present += 1
            if contains(term, in: output) { recalled += 1 }
        }
        return (present, recalled)
    }

    private static func contains(_ term: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{M}\\p{N}])\(escaped)(?![\\p{L}\\p{M}\\p{N}])")
        else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    struct ArmScore: Equatable {
        var dictations = 0
        var wordAccuracySum = 0.0
        var termsPresent = 0
        var termsRecalled = 0

        mutating func add(reference: String, output: String, terms: [String]) {
            dictations += 1
            wordAccuracySum += IntegrationTestSupport.wordAccuracy(
                expected: reference, actual: output)
            let hits = DictationReplaySupport.termHits(
                terms: terms, reference: reference, output: output)
            termsPresent += hits.present
            termsRecalled += hits.recalled
        }

        var wordAccuracy: Double? {
            dictations == 0 ? nil : wordAccuracySum / Double(dictations)
        }
    }

    /// Numbers only: a replay runs on a user's own dictations, and its log
    /// may be pasted in a public PR.
    static func renderScoreboard(
        header: String, arms: [(name: String, score: ArmScore)]
    ) -> String {
        var lines = ["replay: \(header)", "replay: arm          word accuracy  term recall"]
        for (name, score) in arms {
            let accuracy = score.wordAccuracy.map { String(format: "%.3f", $0) } ?? "-"
            let recall = score.termsPresent == 0
                ? "-"
                : String(
                    format: "%d/%d (%.0f %%)", score.termsRecalled, score.termsPresent,
                    100 * Double(score.termsRecalled) / Double(score.termsPresent))
            lines.append(
                "replay: " + name.padding(toLength: 13, withPad: " ", startingAt: 0)
                    + accuracy.padding(toLength: 15, withPad: " ", startingAt: 0) + recall)
        }
        return lines.joined(separator: "\n")
    }
}
