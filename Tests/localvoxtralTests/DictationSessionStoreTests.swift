import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class DictationSessionStoreTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> DictationSessionStore {
        try XCTUnwrap(DictationSessionStore(inMemory: true))
    }

    /// `daysAgo` orders the records; the store sorts on `startedAt`.
    private func record(
        _ rawText: String,
        polished: String? = nil,
        daysAgo: Double = 0,
        status: DictationSessionStatus = .completed,
        commitSucceeded: Bool = true
    ) -> DictationSessionRecord {
        let startedAt = origin.addingTimeInterval(-daysAgo * day)
        return DictationSessionRecord(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(5),
            rawText: rawText,
            polishedText: polished,
            provider: "mistral",
            model: "voxtral",
            outputMode: "overlay_buffer",
            targetAppBundleID: "com.mitchellh.ghostty",
            status: status,
            commitSucceeded: commitSucceeded
        )
    }

    func testEntriesComeBackNewestFirstWithEveryField() async throws {
        let store = try makeStore()
        store.save(record("older", daysAgo: 2))
        store.save(record("newer raw", polished: "Newer polished.", daysAgo: 1))

        let entries = await store.entries()

        XCTAssertEqual(entries.map(\.rawText), ["newer raw", "older"])
        let newest = try XCTUnwrap(entries.first)
        XCTAssertEqual(newest.finalText, "Newer polished.")
        XCTAssertTrue(newest.polishChangedText)
        XCTAssertEqual(newest.targetAppBundleID, "com.mitchellh.ghostty")
        XCTAssertEqual(newest.status, .completed)
        XCTAssertFalse(try XCTUnwrap(entries.last).polishChangedText)
    }

    func testSearchMatchesTranscriptOrPolishedTextIgnoringCaseAndAccents() async throws {
        let store = try makeStore()
        store.save(record("restart the quen server", polished: "Restart the Qwen server.", daysAgo: 3))
        store.save(record("le resume est pret", polished: "Le résumé est prêt.", daysAgo: 2))
        store.save(record("nothing to see", daysAgo: 1))

        var query = DictationHistoryQuery()
        query.searchText = "QWEN"
        let polishedHit = await store.entries(matching: query)
        XCTAssertEqual(polishedHit.map(\.rawText), ["restart the quen server"])

        query.searchText = "quen"
        let rawHit = await store.entries(matching: query)
        XCTAssertEqual(rawHit.map(\.rawText), ["restart the quen server"])

        query.searchText = "resume"
        let accentHit = await store.entries(matching: query)
        XCTAssertEqual(accentHit.map(\.rawText), ["le resume est pret"])

        query.searchText = "  "
        let blank = await store.entries(matching: query)
        XCTAssertEqual(blank.count, 3)
    }

    func testFiltersKeepOnlyTheDictationsThatNeedRecovering() async throws {
        let store = try makeStore()
        store.save(record("inserted", daysAgo: 3))
        store.save(record("lost", daysAgo: 2, commitSucceeded: false))
        store.save(record("unpolished", daysAgo: 1, status: .llmFailed))

        var query = DictationHistoryQuery()
        query.filter = .notInserted
        let notInserted = await store.entries(matching: query)
        XCTAssertEqual(notInserted.map(\.rawText), ["lost"])

        query.filter = .polishFailed
        let polishFailed = await store.entries(matching: query)
        XCTAssertEqual(polishFailed.map(\.rawText), ["unpolished"])

        query.searchText = "lost"
        let both = await store.entries(matching: query)
        XCTAssertEqual(both, [])
    }

    func testLimitKeepsTheNewest() async throws {
        let store = try makeStore()
        for age in 1...5 { store.save(record("dictation \(age)", daysAgo: Double(age))) }

        var query = DictationHistoryQuery()
        query.limit = 2
        let entries = await store.entries(matching: query)

        XCTAssertEqual(entries.map(\.rawText), ["dictation 1", "dictation 2"])
        let texts = await store.recentFinalTexts(limit: 1)
        XCTAssertEqual(texts, ["dictation 1"])
    }

    func testDeleteRemovesOneDictationAndLeavesTheRest() async throws {
        let store = try makeStore()
        let doomed = record("delete me", daysAgo: 1)
        store.save(doomed)
        store.save(record("keep me", daysAgo: 2))

        store.delete(id: doomed.id)

        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.rawText), ["keep me"])
    }

    func testDeleteAllEmptiesTheStoreIncludingASaveQueuedJustBefore() async throws {
        let store = try makeStore()
        store.save(record("one", daysAgo: 1))
        store.save(record("two", daysAgo: 2))

        store.deleteAll()

        let count = await store.count()
        XCTAssertEqual(count, 0)
    }

    func testTrimDeletesOnlyWhatStartedBeforeTheCutoff() async throws {
        let store = try makeStore()
        store.save(record("fresh", daysAgo: 1))
        store.save(record("a month old", daysAgo: 31))
        store.save(record("a year old", daysAgo: 365))

        let cutoff = try XCTUnwrap(DictationHistoryRetention.days30.cutoff(now: origin))
        store.trim(olderThan: cutoff)

        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.rawText), ["fresh"])
    }

    func testEntriesSinceCountsFromTheGivenDate() async throws {
        let store = try makeStore()
        store.save(record("this week", daysAgo: 2))
        store.save(record("last month", daysAgo: 40))

        let recent = await store.entries(since: origin.addingTimeInterval(-7 * day))
        let everything = await store.entries(since: nil)

        XCTAssertEqual(recent.map(\.rawText), ["this week"])
        XCTAssertEqual(everything.count, 2)
    }

    func testOnChangeFiresForWritesThatChangedSomething() async throws {
        let store = try makeStore()
        var changes = 0
        store.onChange = { changes += 1 }

        await store.save(record("one")).value
        await store.delete(id: UUID()).value
        await store.deleteAll().value

        XCTAssertEqual(changes, 2, "deleting an id that is not there changes nothing")
    }
}

final class DictationHistoryRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCutoffIsTheRuleAppliedToNow() {
        XCTAssertNil(DictationHistoryRetention.forever.cutoff(now: now))
        XCTAssertEqual(
            DictationHistoryRetention.days7.cutoff(now: now),
            now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(
            DictationHistoryRetention.days90.cutoff(now: now),
            now.addingTimeInterval(-90 * 86_400))
        XCTAssertEqual(DictationHistoryRetention.off.cutoff(now: now), .distantFuture)
    }

    func testOnlyOffStopsSaving() {
        for rule in DictationHistoryRetention.allCases {
            XCTAssertEqual(rule.savesDictations, rule != .off, rule.rawValue)
        }
    }

    func testKeepsLongerOrdersTheRulesByWhatTheyDelete() {
        XCTAssertTrue(DictationHistoryRetention.forever.keepsLonger(than: .days90))
        XCTAssertTrue(DictationHistoryRetention.days30.keepsLonger(than: .days7))
        XCTAssertTrue(DictationHistoryRetention.days7.keepsLonger(than: .off))
        XCTAssertFalse(DictationHistoryRetention.days7.keepsLonger(than: .days30))
        XCTAssertFalse(DictationHistoryRetention.forever.keepsLonger(than: .forever))
    }

    @MainActor
    func testTheSettingDefaultsToForeverAndPersists() {
        let suiteName = "localvoxtral.DictationHistoryRetentionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        XCTAssertEqual(settings.dictationHistoryRetention, .forever)

        settings.dictationHistoryRetention = .days30
        let reloaded = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        XCTAssertEqual(reloaded.dictationHistoryRetention, .days30)
    }
}
