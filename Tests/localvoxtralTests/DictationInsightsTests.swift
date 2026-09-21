import Foundation
import XCTest
@testable import localvoxtral

final class DictationInsightsTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
        _ rawText: String,
        polished: String? = nil,
        seconds: TimeInterval = 30,
        polishSeconds: Double? = nil,
        bundleID: String? = nil,
        status: DictationSessionStatus = .completed,
        commitSucceeded: Bool = true
    ) -> DictationHistoryEntry {
        DictationHistoryEntry(
            id: UUID(), startedAt: origin, finishedAt: origin.addingTimeInterval(seconds),
            rawText: rawText, polishedText: polished, polishingDurationSeconds: polishSeconds,
            provider: "p", model: "m", outputMode: "overlay_buffer", targetAppBundleID: bundleID,
            status: status, commitSucceeded: commitSucceeded, polishProfile: nil,
            polishContextSummary: nil)
    }

    func testNoDictationsIsAllZeroesAndNoRatios() {
        let insights = DictationInsights(entries: [])
        XCTAssertEqual(insights, DictationInsights())
        XCTAssertNil(insights.wordsPerMinute)
        XCTAssertNil(insights.medianPolishSeconds)
        XCTAssertEqual(insights.secondsSavedOverTyping, 0)
    }

    func testWordsCountTheFinalTextAndTimeLeavesThePolishWaitOut() {
        let insights = DictationInsights(entries: [
            // 32 s start to finish, 2 s of it waiting for the polish.
            entry("one two three", polished: "One, two, three, four.", seconds: 32, polishSeconds: 2),
            entry("five six", seconds: 30),
        ])

        XCTAssertEqual(insights.dictations, 2)
        XCTAssertEqual(insights.words, 6)
        XCTAssertEqual(insights.dictatingSeconds, 60)
        XCTAssertEqual(insights.wordsPerMinute, 6)
    }

    func testTimeSavedIsTypingTimeLessDictatingTimeAndNeverNegative() {
        // 80 words at 40 words per minute is 120 s of typing.
        let fast = DictationInsights(entries: [
            entry(Array(repeating: "word", count: 80).joined(separator: " "), seconds: 30)
        ])
        XCTAssertEqual(fast.secondsSavedOverTyping, 90)

        let slow = DictationInsights(entries: [entry("two words", seconds: 600)])
        XCTAssertEqual(slow.secondsSavedOverTyping, 0)
    }

    func testADictationThatSpansASleepCountsForAnHourAtMost() {
        let insights = DictationInsights(entries: [entry("hello", seconds: 86_400)])
        XCTAssertEqual(insights.dictatingSeconds, DictationInsights.maxDictationSeconds)
    }

    func testReliabilityCountsLostInsertionsAndFailedPolishes() {
        let insights = DictationInsights(entries: [
            entry("fine"),
            entry("lost", commitSucceeded: false),
            entry("unpolished", polishSeconds: 40, status: .llmFailed),
        ])
        XCTAssertEqual(insights.notInserted, 1)
        XCTAssertEqual(insights.polishFailed, 1)
        XCTAssertEqual(insights.polishRan, 0, "a failed polish is not a wait the user got text for")
    }

    func testPolishWaitsAreTheMedianAndTheNinetiethPercentileThatHappened() throws {
        let waits = [0.5, 0.7, 0.9, 1.0, 1.1, 1.2, 1.4, 1.6, 2.0, 9.0]
        let insights = DictationInsights(
            entries: waits.map { entry("raw", polished: "Raw.", polishSeconds: $0) })

        XCTAssertEqual(insights.polishRan, 10)
        XCTAssertEqual(insights.polishChanged, 10)
        // Ten waits: the median is between the fifth and the sixth.
        XCTAssertEqual(try XCTUnwrap(insights.medianPolishSeconds), 1.15, accuracy: 1e-9)
        XCTAssertEqual(insights.slowPolishSeconds, 2.0)
        XCTAssertEqual(DictationInsights.median(of: [1, 9]), 5)
        XCTAssertEqual(DictationInsights.median(of: [1, 2, 9]), 2)
        XCTAssertEqual(DictationInsights.percentile(0.9, of: [3]), 3)
    }

    /// With polishing off the replacement dictionary still rewrites the text,
    /// and the record keeps the result where a polish would go.
    func testAChangeNoModelMadeIsNotCountedAsPolishing() {
        let byDictionary = entry("foo", polished: "bar")
        let insights = DictationInsights(entries: [
            byDictionary, byDictionary, byDictionary,
            entry("kept as is", polishSeconds: 1),
        ])

        XCTAssertEqual(insights.polishRan, 1)
        XCTAssertEqual(insights.polishChanged, 0, "or the pane reads 300% of 1 polished")
        XCTAssertEqual(insights.recurringFixes, [])
    }

    func testTheClipboardMarkersPlaceholderIsNotAFix() {
        let pasted = entry(
            "summarize paste clipboard please",
            polished: "Summarize \(ClipboardPayloadMacro.placeholder) please", polishSeconds: 1)
        XCTAssertEqual(DictationInsights.fixes(in: pasted).map(\.written), [])
    }

    func testAFixCountsOncePerDictationAndShowsFromThreeDictations() {
        let qwen = entry(
            "ask quen and then quen again", polished: "ask Qwen and then Qwen again",
            polishSeconds: 1)
        let twice = entry("the clawd code docs", polished: "the Claude Code docs", polishSeconds: 1)
        let insights = DictationInsights(entries: [qwen, qwen, qwen, twice, twice])

        XCTAssertEqual(
            insights.recurringFixes,
            [DictationInsights.RecurringFix(heard: "quen", written: "Qwen", dictations: 3)])
    }

    func testFixesSkipFillersPunctuationSentenceCapitalsAndRephrasing() {
        func fixes(_ raw: String, _ polished: String) -> [String] {
            DictationInsights.fixes(in: entry(raw, polished: polished, polishSeconds: 1))
                .map { "\($0.heard)>\($0.written)" }
        }

        XCTAssertEqual(fixes("um so we ship today", "So we ship today."), [])
        XCTAssertEqual(fixes("it works. then we ship", "It works. Then we ship"), [])
        XCTAssertEqual(
            fixes("we should probably maybe think about shipping", "Let's ship"), [],
            "a rewrite of more than four words is not a misheard word")
        // Casing alone counts for a name in the middle of a sentence.
        XCTAssertEqual(fixes("open claude code now", "open Claude Code now"), ["claude code>Claude Code"])
        // What is inside the word survives; the quotes around it do not.
        XCTAssertEqual(
            fixes("check local voxtral dot js please", "check `localvoxtral.js` please"),
            ["local voxtral dot js>localvoxtral.js"])
    }

    func testTopAppsRankByDictationsAndIgnoreDictationsWithoutOne() {
        let insights = DictationInsights(entries: [
            entry("a", bundleID: "com.example.editor"),
            entry("b", bundleID: "com.example.terminal"),
            entry("c", bundleID: "com.example.terminal"),
            entry("live mode"),
        ])
        XCTAssertEqual(
            insights.topApps,
            [
                DictationInsights.AppCount(bundleID: "com.example.terminal", dictations: 2),
                DictationInsights.AppCount(bundleID: "com.example.editor", dictations: 1),
            ])
    }

    func testPeriodStartsCountBackFromNow() {
        XCTAssertEqual(
            DictationInsightsPeriod.week.start(now: origin), origin.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(
            DictationInsightsPeriod.month.start(now: origin), origin.addingTimeInterval(-30 * 86_400))
        XCTAssertNil(DictationInsightsPeriod.allTime.start(now: origin))
    }

    func testDurationsReadInTheLargestTwoUnits() {
        XCTAssertEqual(DictationInsightsText.duration(45), "45 s")
        XCTAssertEqual(DictationInsightsText.duration(14 * 60 + 20), "14 min")
        XCTAssertEqual(DictationInsightsText.duration(2 * 3_600 + 14 * 60), "2 h 14 min")
        XCTAssertEqual(DictationInsightsText.duration(3 * 3_600), "3 h")
        XCTAssertEqual(DictationInsightsText.share(1, of: 0), "—")
    }
}

final class TranscriptDiffHunkTests: XCTestCase {
    func testHunksPairWhatWasRemovedWithWhatReplacedItInReadingOrder() {
        let before = "um restart the quen server uh now"
        let after = "Restart the Qwen server now"

        let hunks = TranscriptDiff.hunks(from: before, to: after).map { hunk in
            (hunk.removed.map { String(before[$0]) }, hunk.added.map { String(after[$0]) })
        }

        XCTAssertEqual(hunks.map(\.0), [["um", "restart"], ["quen"], ["uh"]])
        XCTAssertEqual(hunks.map(\.1), [["Restart"], ["Qwen"], []])
    }
}
