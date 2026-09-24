import Foundation
import XCTest
@testable import localvoxtral

final class DictationLearningTrendTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 86_400

    /// A dictation `weeksAgo` full weeks before now, in the middle of its week.
    private func entry(
        weeksAgo: Int,
        _ rawText: String,
        polished: String? = nil,
        polishSeconds: Double? = nil,
        status: DictationSessionStatus = .completed
    ) -> DictationHistoryEntry {
        let startedAt = now.addingTimeInterval(-Double(weeksAgo) * week - week / 2)
        return DictationHistoryEntry(
            id: UUID(), startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(20),
            rawText: rawText, polishedText: polished, polishingDurationSeconds: polishSeconds,
            provider: "p", model: "m", outputMode: "overlay_buffer", targetAppBundleID: nil,
            status: status, commitSucceeded: true, polishProfile: nil,
            polishContextSummary: nil)
    }

    private func repeated(_ count: Int, _ make: () -> DictationHistoryEntry) -> [DictationHistoryEntry] {
        (0..<count).map { _ in make() }
    }

    func testNoHistoryIsTwelveEmptyWeeksWithNoValues() {
        let trend = DictationLearningTrend(entries: [], terms: ["Qwen"], now: now)

        XCTAssertEqual(trend.weeks.count, DictationLearningTrend.weekCount)
        XCTAssertEqual(trend.weeks.first?.start, now.addingTimeInterval(-12 * week))
        XCTAssertEqual(trend.weeks.last?.start, now.addingTimeInterval(-week))
        XCTAssertFalse(trend.hasTermValues)
        XCTAssertFalse(trend.hasPolishValues)
    }

    /// The fixture a user who is being learned produces: early on the
    /// recognizer mangles "Qwen" and polishing fixes it; later the transcript
    /// already spells it, and polishing has nothing left to change.
    func testATermTheRecognizerLearnsRisesAndSoDoesTheKeptTranscript() {
        let early = repeated(5) {
            entry(weeksAgo: 9, "ask quen about it", polished: "Ask Qwen about it.", polishSeconds: 1)
        }
        let middle =
            repeated(3) {
                entry(weeksAgo: 5, "ask quen about it", polished: "Ask Qwen about it.", polishSeconds: 1)
            }
            + repeated(3) {
                entry(weeksAgo: 5, "Ask Qwen about it.", polished: "Ask Qwen about it.", polishSeconds: 1)
            }
        let late = repeated(6) {
            entry(weeksAgo: 0, "Ask Qwen about it.", polishSeconds: 1)
        }

        let trend = DictationLearningTrend(
            entries: early + middle + late, terms: ["Qwen"], now: now)
        let shares = trend.weeks.map(\.termsSpelledRightShare)
        let kept = trend.weeks.map(\.transcriptKeptShare)

        XCTAssertEqual(shares[2], 0)
        XCTAssertEqual(shares[6], 0.5)
        XCTAssertEqual(shares[11], 1)
        XCTAssertEqual(kept[2], 0)
        XCTAssertEqual(kept[6], 0.5)
        XCTAssertEqual(kept[11], 1)
        // Every other week had no dictation.
        XCTAssertEqual(shares.compactMap { $0 }.count, 3)
    }

    func testAWeekUnderTheMinimumShowsNoValue() {
        let entries = repeated(DictationLearningTrend.minimumDictations - 1) {
            entry(weeksAgo: 0, "Qwen", polishSeconds: 1)
        }
        let trend = DictationLearningTrend(entries: entries, terms: ["Qwen"], now: now)

        XCTAssertEqual(trend.weeks.last?.termMentions, 4)
        XCTAssertNil(trend.weeks.last?.termsSpelledRightShare)
        XCTAssertNil(trend.weeks.last?.transcriptKeptShare)
    }

    func testManyTermsInOneDictationAreStillOneDictation() {
        let entries = repeated(DictationLearningTrend.minimumDictations - 1) {
            entry(weeksAgo: 0, "Qwen MLX vLLM Ghostty herdr")
        }
        let trend = DictationLearningTrend(
            entries: entries, terms: ["Qwen", "MLX", "vLLM", "Ghostty", "herdr"], now: now)

        XCTAssertEqual(trend.weeks.last?.termMentions, 20)
        XCTAssertNil(trend.weeks.last?.termsSpelledRightShare)
    }

    func testAPolishedDictationThatWasNeverInsertedIsNotCounted() {
        let entries = (0..<DictationLearningTrend.minimumDictations).map { _ in
            DictationHistoryEntry(
                id: UUID(), startedAt: now.addingTimeInterval(-86_400),
                finishedAt: now.addingTimeInterval(-86_380), rawText: "hello",
                polishedText: nil, polishingDurationSeconds: 1, provider: "p", model: "m",
                outputMode: "overlay_buffer", targetAppBundleID: nil, status: .completed,
                commitSucceeded: false, polishProfile: nil, polishContextSummary: nil)
        }
        let trend = DictationLearningTrend(entries: entries, terms: [], now: now)

        XCTAssertEqual(trend.weeks.last?.polished, 0)
    }

    func testACombiningMarkAfterATermMakesItAnotherWord() {
        let counts = DictationLearningTrend.termCounts(
            in: entry(weeksAgo: 0, "Cafe\u{301} ouvert", polished: "Cafe ouvert"),
            matchers: DictationLearningTrend.matchers(for: ["Cafe"]))

        XCTAssertEqual(counts.mentions, 1)
        XCTAssertEqual(counts.spelledRight, 0)
    }

    func testWrongCasingInTheTranscriptIsNotSpelledRight() {
        let counts = DictationLearningTrend.termCounts(
            in: entry(weeksAgo: 0, "open claude code and vllm", polished: "Open Claude Code and vLLM."),
            matchers: DictationLearningTrend.matchers(for: ["Claude Code", "vLLM"]))

        XCTAssertEqual(counts.mentions, 2)
        XCTAssertEqual(counts.spelledRight, 0)
    }

    func testATermCountsOncePerDictationAndOnlyAsAWholeWord() {
        let matchers = DictationLearningTrend.matchers(for: ["Qwen", "qwen", "MLX"])
        // "qwen" is a case-insensitive duplicate of "Qwen": one matcher.
        XCTAssertEqual(matchers.count, 2)

        let counts = DictationLearningTrend.termCounts(
            in: entry(weeksAgo: 0, "Qwen and Qwen again, mlxs aside"), matchers: matchers)
        XCTAssertEqual(counts.mentions, 1)
        XCTAssertEqual(counts.spelledRight, 1)
    }

    func testAMissedTermNothingFixedIsNotCounted() {
        // Without polishing the final text is the transcript: "quen" never
        // became "Qwen", so there is no mention to score.
        let counts = DictationLearningTrend.termCounts(
            in: entry(weeksAgo: 0, "ask quen"),
            matchers: DictationLearningTrend.matchers(for: ["Qwen"]))

        XCTAssertEqual(counts.mentions, 0)
    }

    func testAFailedPolishIsNotAPolishAndAnOldOrFutureDictationIsOutside() {
        let entries = [
            entry(weeksAgo: 0, "hello", polishSeconds: 1, status: .llmFailed),
            entry(weeksAgo: 12, "hello", polishSeconds: 1),
            entry(weeksAgo: -1, "hello", polishSeconds: 1),
        ]
        let trend = DictationLearningTrend(entries: entries, terms: [], now: now)

        XCTAssertEqual(trend.weeks.reduce(0) { $0 + $1.polished }, 0)
    }
}
