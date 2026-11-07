import Foundation
import SQLite3
import XCTest
import localvoxtralTestSupport
@testable import localvoxtral

@MainActor
final class DictationSessionStoreTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> DictationSessionStore {
        try XCTUnwrap(DictationSessionStore.inMemory())
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
        XCTAssertTrue(newest.textWasChanged)
        XCTAssertEqual(newest.targetAppBundleID, "com.mitchellh.ghostty")
        XCTAssertEqual(newest.status, .completed)
        XCTAssertFalse(try XCTUnwrap(entries.last).textWasChanged)
    }

    func testPolishRanOnlyWhenAPolishAnswered() async throws {
        let store = try makeStore()
        // The replacement dictionary changed this one with polishing off.
        store.save(record("foo", polished: "bar", daysAgo: 3))
        let polished = record("hello", polished: "Hello.", daysAgo: 2)
        polished.polishingDurationSeconds = 1.2
        store.save(polished)
        let failed = record("timed out", daysAgo: 1, status: .llmFailed)
        failed.polishingDurationSeconds = 40
        store.save(failed)

        let entries = await store.entries()

        XCTAssertEqual(entries.map(\.polishRan), [false, true, false])
        XCTAssertEqual(entries.map(\.textWasChanged), [false, true, true])
    }

    func testSearchTreatsPercentAndUnderscoreAsTextNotWildcards() async throws {
        let store = try makeStore()
        store.save(record("a 50% discount", daysAgo: 2))
        store.save(record("a 50 dollar discount", daysAgo: 1))
        store.save(record("snake_case name", daysAgo: 3))
        store.save(record("snakeXcase name", daysAgo: 4))

        var query = DictationHistoryQuery()
        query.searchText = "50%"
        let percent = await store.entries(matching: query)
        XCTAssertEqual(percent.map(\.rawText), ["a 50% discount"])

        query.searchText = "snake_case"
        let underscore = await store.entries(matching: query)
        XCTAssertEqual(underscore.map(\.rawText), ["snake_case name"])
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
        let recent = await store.recentEntries(limit: 1)
        XCTAssertEqual(recent.map(\.rawText), ["dictation 1"])
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

    /// Delete, a retention trim and Delete All each leave the store file and
    /// its WAL without the deleted text (LVX-101). macOS's SQLite deletes
    /// with `secure_delete = FAST`, which zeroes a row inside its page but
    /// not the overflow pages a long dictation spills into: those go to the
    /// free list with the text, readable by anyone who opens the file.
    func testDeletesLeaveNoTraceOfTheTextInTheStoreFile() async throws {
        let operations: [(String, (DictationSessionStore, DictationSessionRecord) -> Task<Void, Never>)] = [
            ("delete", { store, doomed in store.delete(id: doomed.id) }),
            ("trim", { store, _ in
                store.trim(olderThan: DictationHistoryRetention.days30.cutoff(now: self.origin)!)
            }),
            ("delete all", { store, _ in store.deleteAll() }),
        ]
        for (name, deleting) in operations {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lv-scrub-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("history.store")
            let store = try DictationSessionStore.open(url: url).get()
            let marker = "quokkamarker\(UUID().uuidString.prefix(8))"
            // Several pages of speech, the marker past the first.
            let speech = String(repeating: "and then we shipped it tonight ", count: 400)
            let doomed = record(speech + marker, polished: speech + marker + ".", daysAgo: 60)
            store.save(record("fresh", daysAgo: 1))
            store.save(doomed)
            _ = await store.count()
            XCTAssertTrue(try storeBytes(url).contains(Data(marker.utf8)), "\(name): the marker was never written")

            await deleting(store, doomed).value

            XCTAssertFalse(try storeBytes(url).contains(Data(marker.utf8)), "\(name) left the text in the file")
            withExtendedLifetime(store) {}
        }
    }

    /// The store file and its WAL after a checkpoint, as anyone reading the
    /// files would see them.
    private func storeBytes(_ url: URL) throws -> Data {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        sqlite3_busy_timeout(db, 5_000)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        var bytes = try Data(contentsOf: url)
        bytes.append((try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))) ?? Data())
        return bytes
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
        let defaults = makeTestDefaults()

        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        XCTAssertEqual(settings.dictationHistoryRetention, .forever)

        settings.dictationHistoryRetention = .days30
        let reloaded = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        XCTAssertEqual(reloaded.dictationHistoryRetention, .days30)
    }
}
