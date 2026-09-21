import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class DictationHistoryModelTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private var copied: [String] = []

    private func makeStore(dictations count: Int = 0) throws -> DictationSessionStore {
        let store = try XCTUnwrap(DictationSessionStore(inMemory: true))
        for index in 0..<count { store.save(record("dictation \(index)", minutesAgo: index)) }
        return store
    }

    private func record(
        _ rawText: String, polished: String? = nil, minutesAgo: Int = 0,
        bundleID: String? = nil, commitSucceeded: Bool = true
    ) -> DictationSessionRecord {
        let startedAt = origin.addingTimeInterval(-Double(minutesAgo) * 60)
        return DictationSessionRecord(
            startedAt: startedAt, finishedAt: startedAt, rawText: rawText, polishedText: polished,
            provider: "p", model: "m", outputMode: "overlay_buffer", targetAppBundleID: bundleID,
            status: .completed, commitSucceeded: commitSucceeded)
    }

    private func makeModel(
        _ store: DictationSessionStore?, appName: @escaping @MainActor (String) -> String? = { _ in nil }
    ) -> DictationHistoryModel {
        DictationHistoryModel(
            store: { store },
            copyToPasteboard: { [unowned self] in self.copied.append($0) },
            appName: appName)
    }

    func testReloadShowsOnePageAndShowMoreGrowsIt() async throws {
        let store = try makeStore(dictations: DictationHistoryModel.pageSize + 5)
        let model = makeModel(store)

        await model.reload()
        XCTAssertEqual(model.entries.count, DictationHistoryModel.pageSize)
        XCTAssertEqual(model.entries.first?.rawText, "dictation 0")
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(model.totalCount, DictationHistoryModel.pageSize + 5)

        await model.showMore()
        XCTAssertEqual(model.entries.count, DictationHistoryModel.pageSize + 5)
        XCTAssertFalse(model.hasMore)
    }

    func testAStoreWriteKeepsThePagesShownAndANewSearchStartsOver() async throws {
        let store = try makeStore(dictations: DictationHistoryModel.pageSize + 5)
        let model = makeModel(store)
        await model.reload()
        await model.showMore()

        store.save(record("just now", minutesAgo: -1))
        await model.reload()
        XCTAssertEqual(model.entries.count, DictationHistoryModel.pageSize + 6)

        model.searchText = "dictation"
        await model.reload()
        XCTAssertEqual(model.entries.count, DictationHistoryModel.pageSize)
        XCTAssertTrue(model.hasMore)
        XCTAssertTrue(model.isFiltering)
    }

    func testSearchAndFilterNarrowTheListButNotTheTotal() async throws {
        let store = try makeStore()
        store.save(record("deploy the server", minutesAgo: 3))
        store.save(record("lost words", minutesAgo: 2, commitSucceeded: false))
        store.save(record("lunch order", minutesAgo: 1))
        let model = makeModel(store)

        model.searchText = "SERVER"
        await model.reload()
        XCTAssertEqual(model.entries.map(\.rawText), ["deploy the server"])
        XCTAssertEqual(model.totalCount, 3)

        model.searchText = ""
        model.filter = .notInserted
        await model.reload()
        XCTAssertEqual(model.entries.map(\.rawText), ["lost words"])
    }

    func testDeleteRemovesTheRowFromTheListAndTheStore() async throws {
        let store = try makeStore(dictations: 3)
        let model = makeModel(store)
        await model.reload()
        let doomed = try XCTUnwrap(model.entries.first)
        model.toggleExpanded(doomed)

        await model.delete(doomed)

        XCTAssertEqual(model.entries.map(\.rawText), ["dictation 1", "dictation 2"])
        XCTAssertNil(model.expandedEntryID, "a deleted row cannot stay expanded")
        let stored = await store.count()
        XCTAssertEqual(stored, 2)
    }

    func testDeleteAllEmptiesBoth() async throws {
        let store = try makeStore(dictations: 3)
        let model = makeModel(store)
        await model.reload()

        await model.deleteAll()

        XCTAssertEqual(model.entries, [])
        XCTAssertEqual(model.totalCount, 0)
        let stored = await store.count()
        XCTAssertEqual(stored, 0)
    }

    func testCopyTakesThePolishedTextAndCopyTranscriptTheRawOne() async throws {
        let store = try makeStore()
        store.save(record("hello world", polished: "Hello, world."))
        let model = makeModel(store)
        await model.reload()
        let entry = try XCTUnwrap(model.entries.first)

        model.copyFinalText(of: entry)
        model.copyTranscript(of: entry)

        XCTAssertEqual(copied, ["Hello, world.", "hello world"])
    }

    func testCountDeletedByARetentionCountsWhatItsCutoffCovers() async throws {
        let store = try makeStore()
        store.save(record("fresh", minutesAgo: 60))
        store.save(record("old", minutesAgo: 60 * 24 * 10))
        let model = makeModel(store)

        let byWeek = await model.countDeleted(by: .days7, now: origin)
        let byOff = await model.countDeleted(by: .off, now: origin)
        let byForever = await model.countDeleted(by: .forever, now: origin)

        XCTAssertEqual(byWeek, 1)
        XCTAssertEqual(byOff, 2)
        XCTAssertEqual(byForever, 0)
    }

    func testTargetAppNameAsksOncePerBundleIDAndRemembersAMiss() async throws {
        let store = try makeStore()
        store.save(record("one", minutesAgo: 2, bundleID: "com.example.gone"))
        store.save(record("two", minutesAgo: 1, bundleID: "com.example.gone"))
        store.save(record("live mode", minutesAgo: 0))
        var lookups: [String] = []
        let model = makeModel(store) { bundleID in
            lookups.append(bundleID)
            return nil
        }
        await model.reload()

        for entry in model.entries { XCTAssertNil(model.targetAppName(for: entry)) }

        XCTAssertEqual(lookups, ["com.example.gone"])
    }

    func testWithoutAStoreTheListIsEmptyAndLoaded() async {
        let model = makeModel(nil)
        await model.reload()
        XCTAssertEqual(model.entries, [])
        XCTAssertTrue(model.hasLoaded)
    }
}

final class DictationHistoryRowTextTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let locale = Locale(identifier: "en_GB")
    /// 2027-01-15 08:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func timestamp(hoursAgo: Double) -> String {
        DictationHistoryRowText.timestamp(
            for: now.addingTimeInterval(-hoursAgo * 3_600), now: now, calendar: calendar,
            locale: locale)
    }

    func testTimestampNamesTodayAndYesterdayByCalendarDayNotBy24Hours() {
        XCTAssertEqual(timestamp(hoursAgo: 1), "Today 7:00")
        // Nine hours ago is 23:00 the day before.
        XCTAssertEqual(timestamp(hoursAgo: 9), "Yesterday 23:00")
        XCTAssertEqual(timestamp(hoursAgo: 24 * 3), "12 Jan 2027 8:00")
    }

    private func entry(
        commitSucceeded: Bool = true, status: DictationSessionStatus = .completed,
        polishSeconds: Double? = nil, profile: String? = nil
    ) -> DictationHistoryEntry {
        DictationHistoryEntry(
            id: UUID(), startedAt: now, finishedAt: now, rawText: "raw", polishedText: nil,
            polishingDurationSeconds: polishSeconds, provider: "mistral", model: "voxtral-mini",
            outputMode: "overlay_buffer", targetAppBundleID: nil, status: status,
            commitSucceeded: commitSucceeded, polishProfile: profile, polishContextSummary: nil)
    }

    func testProblemPutsALostInsertionBeforeAFailedPolish() {
        XCTAssertNil(DictationHistoryRowText.problem(for: entry()))
        XCTAssertEqual(DictationHistoryRowText.problem(for: entry(status: .llmFailed)), "Polish failed")
        XCTAssertEqual(
            DictationHistoryRowText.problem(for: entry(commitSucceeded: false, status: .llmFailed)),
            "Not inserted")
    }

    func testDetailsListTheModelThenWhatPolishingDid() {
        XCTAssertEqual(DictationHistoryRowText.details(for: entry()), "voxtral-mini")
        XCTAssertTrue(
            DictationHistoryRowText.details(for: entry(polishSeconds: 1.26, profile: "agent"))
                .hasSuffix("s · agent"))
    }
}

final class TranscriptDiffTests: XCTestCase {
    private func words(_ ranges: [Range<String.Index>], in text: String) -> [String] {
        ranges.map { String(text[$0]) }
    }

    func testIdenticalTextsHaveNoDifference() {
        XCTAssertTrue(TranscriptDiff.words(from: "same words here", to: "same words here").isEmpty)
        XCTAssertTrue(TranscriptDiff.words(from: "", to: "").isEmpty)
    }

    func testAReplacedWordIsRemovedOnOneSideAndAddedOnTheOther() {
        let before = "restart the quen server now"
        let after = "restart the Qwen server now"
        let diff = TranscriptDiff.words(from: before, to: after)
        XCTAssertEqual(words(diff.removed, in: before), ["quen"])
        XCTAssertEqual(words(diff.added, in: after), ["Qwen"])
    }

    func testDroppedFillersAndAddedPunctuationAreEachMarkedOnTheirOwnSide() {
        let before = "um so we should uh ship it today"
        let after = "So we should ship it today."
        let diff = TranscriptDiff.words(from: before, to: after)
        XCTAssertEqual(words(diff.removed, in: before), ["um", "so", "uh", "today"])
        XCTAssertEqual(words(diff.added, in: after), ["So", "today."])
    }

    func testRangesPointIntoTheOriginalStringsAcrossLineBreaks() {
        let before = "first line\nsecond lin"
        let after = "first line\n\nsecond line"
        let diff = TranscriptDiff.words(from: before, to: after)
        XCTAssertEqual(words(diff.removed, in: before), ["lin"])
        XCTAssertEqual(words(diff.added, in: after), ["line"])
    }

    func testEverythingAddedOrEverythingRemoved() {
        let text = "brand new text"
        XCTAssertEqual(words(TranscriptDiff.words(from: "", to: text).added, in: text).count, 3)
        XCTAssertEqual(words(TranscriptDiff.words(from: text, to: "").removed, in: text).count, 3)
    }

    func testARewriteLargerThanTheTableMarksTheWholeMiddleAndKeepsTheSharedEnds() {
        let middleBefore = (0...TranscriptDiff.maxComparedWords).map { "b\($0)" }
        let middleAfter = (0...TranscriptDiff.maxComparedWords).map { "a\($0)" }
        let before = (["start"] + middleBefore + ["end"]).joined(separator: " ")
        let after = (["start"] + middleAfter + ["end"]).joined(separator: " ")

        let diff = TranscriptDiff.words(from: before, to: after)

        XCTAssertEqual(words(diff.removed, in: before), middleBefore)
        XCTAssertEqual(words(diff.added, in: after), middleAfter)
    }
}
