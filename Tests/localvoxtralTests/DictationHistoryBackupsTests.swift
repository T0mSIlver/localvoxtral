import Foundation
import SwiftData
import Synchronization
import XCTest
@testable import localvoxtral

private final class HistoryTestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    func now() -> Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// Snapshots and quarantine: what is left to restore from when the store
/// loses rows again (#985).
@MainActor
final class DictationHistoryBackupsTests: XCTestCase {
    private let clock = HistoryTestClock()
    private let pcm = Data([1, 0, 2, 0])

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-backups-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func openStore(in directory: URL) throws -> DictationSessionStore {
        let clock = clock
        let store = try DictationSessionStore.open(directory: directory, now: { clock.now() }).get()
        store.audioStore = DictationAudioStore(
            directoryURL: directory.appendingPathComponent("dictation-audio", isDirectory: true))
        return store
    }

    private func record(_ text: String, startedAt: Date) -> DictationSessionRecord {
        DictationSessionRecord(
            startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(5), rawText: text,
            provider: "p", model: "m", outputMode: "overlay_buffer", status: .completed,
            commitSucceeded: true)
    }

    private func backups(in directory: URL) -> DictationHistoryBackups {
        let clock = clock
        return DictationHistoryBackups(
            directoryURL: DictationHistoryBackups.directory(inHistoryFolder: directory),
            now: { clock.now() })
    }

    // MARK: - Snapshots

    /// The daily snapshot is a copy that opens on its own, rows included.
    func testTheDailySnapshotHoldsTheStoreAsItWas() async throws {
        let directory = makeDirectory()
        let store = try openStore(in: directory)
        await store.save(record("one", startedAt: clock.now())).value
        clock.advance(86_401)

        _ = try openStore(in: directory)

        let daily = try XCTUnwrap(backups(in: directory).snapshots().first { $0.dictations == 1 })
        XCTAssertEqual(daily.reason, .daily)
        let copy = try DictationSessionStore.open(url: daily.url).get()
        let entries = await copy.entries()
        XCTAssertEqual(entries.map(\.rawText), ["one"])
    }

    /// A store an earlier build wrote is copied before this build migrates
    /// it, in its old layout.
    func testAStoreAboutToBeMigratedIsCopiedFirst() async throws {
        let directory = makeDirectory()
        let url = directory.appendingPathComponent("history.store")
        do {
            let schema = Schema([History18.DictationSessionRecord.self])
            let container = try ModelContainer(
                for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = ModelContext(container)
            context.insert(History18.DictationSessionRecord(rawText: "old", quickCaptureDestination: nil))
            try context.save()
        }

        _ = try openStore(in: directory)

        let migration = try XCTUnwrap(backups(in: directory).snapshots().first { $0.reason == .migration })
        XCTAssertEqual(migration.dictations, 1)
        let file = try SQLiteFile(readWrite: migration.url)
        XCTAssertFalse(try file.columnNames(of: "ZDICTATIONSESSIONRECORD").contains("ZEDITOUTCOME"))
    }

    /// A trim that deletes takes a snapshot first, at most one an hour.
    func testRetentionTakesASnapshotBeforeDeleting() async throws {
        let directory = makeDirectory()
        let store = try openStore(in: directory)
        await store.save(record("old", startedAt: clock.now())).value
        clock.advance(7_200)

        await store.trim(olderThan: clock.now()).value

        let delete = try XCTUnwrap(backups(in: directory).snapshots().first { $0.reason == .delete })
        XCTAssertEqual(delete.dictations, 1)
        let count = await store.count()
        XCTAssertEqual(count, 0)
    }

    /// An app left running for days still gets its daily copy: the check
    /// runs on every save, not only at launch.
    func testARunningAppTakesADailySnapshotOnTheNextSaveOfTheDay() async throws {
        let directory = makeDirectory()
        let store = try openStore(in: directory)
        await store.save(record("one", startedAt: clock.now())).value
        clock.advance(86_401)

        await store.save(record("two", startedAt: clock.now())).value

        let dailies = backups(in: directory).snapshots().filter { $0.reason == .daily }
        XCTAssertEqual(dailies.map(\.dictations), [2, 0])
    }

    /// A delete snapshot within the day does not stand in for the daily one:
    /// rotation keeps daily copies apart.
    func testAnEventSnapshotDoesNotSuppressTheDailyOne() async throws {
        let directory = makeDirectory()
        let store = try openStore(in: directory)
        let url = try XCTUnwrap(store.storeURL)
        let backups = backups(in: directory)
        clock.advance(86_401)
        backups.snapshot(of: url, reason: .delete)
        clock.advance(3_600)

        backups.snapshotIfDue(of: url)

        XCTAssertEqual(backups.snapshots().filter { $0.reason == .daily }.count, 2)
    }

    /// Rotation never drops the newest snapshot that holds dictations, however
    /// many empty ones came after it.
    func testRotationKeepsTheLastSnapshotThatHoldsDictations() throws {
        let directory = makeDirectory()
        let backups = backups(in: directory)
        try FileManager.default.createDirectory(at: backups.directoryURL, withIntermediateDirectories: true)
        let start = clock.now()
        let good = DictationHistoryBackups.fileName(takenAt: start, reason: .delete, dictations: 652)
        FileManager.default.createFile(atPath: backups.directoryURL.appendingPathComponent(good).path, contents: Data())
        for hour in 1...(DictationHistoryBackups.eventsKept + 3) {
            let name = DictationHistoryBackups.fileName(
                takenAt: start.addingTimeInterval(Double(hour) * 3_600), reason: .delete, dictations: 0)
            FileManager.default.createFile(atPath: backups.directoryURL.appendingPathComponent(name).path, contents: Data())
        }
        let foreign = backups.directoryURL.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: foreign.path, contents: Data())

        backups.rotate()

        let kept = backups.snapshots()
        XCTAssertEqual(kept.filter { $0.dictations == 0 }.count, DictationHistoryBackups.eventsKept)
        XCTAssertEqual(kept.filter { $0.dictations == 652 }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    // MARK: - Quarantine

    /// An orphan found by a sweep moves to the quarantine folder; the
    /// recording whose dictation is saved stays.
    func testTheSweepMovesOrphansToQuarantine() async throws {
        let directory = makeDirectory()
        let store = try openStore(in: directory)
        let audio = try XCTUnwrap(store.audioStore)
        let kept = record("kept", startedAt: clock.now())
        await store.save(kept, audio: pcm).value
        let orphan = UUID()
        try audio.write(pcm16: pcm, for: orphan)

        await store.removeOrphanedAudio().value

        XCTAssertEqual(audio.storedIDs(), [kept.id])
        let quarantined = try XCTUnwrap(store.quarantine).folder(for: "dictation-audio")
            .appendingPathComponent("\(orphan.uuidString).wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path))
    }

    /// A recording already in quarantine is never overwritten: two running
    /// copies can move the same orphan.
    func testQuarantineNeverOverwritesAFileAlreadyThere() async throws {
        let directory = makeDirectory()
        let store = try openStore(in: directory)
        let audio = try XCTUnwrap(store.audioStore)
        await store.save(record("kept", startedAt: clock.now()), audio: pcm).value
        let orphan = UUID()
        try audio.write(pcm16: pcm, for: orphan)
        let folder = try XCTUnwrap(store.quarantine).folder(for: "dictation-audio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let earlier = folder.appendingPathComponent("\(orphan.uuidString).wav")
        try Data([9]).write(to: earlier)

        await store.removeOrphanedAudio().value

        XCTAssertEqual(try Data(contentsOf: earlier), Data([9]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }

    /// More orphans than a sweep may move is a store that lost rows: nothing
    /// moves.
    func testASweepFindingTooManyOrphansMovesNothing() async throws {
        let directory = makeDirectory()
        let store = try openStore(in: directory)
        let audio = try XCTUnwrap(store.audioStore)
        await store.save(record("kept", startedAt: clock.now()), audio: pcm).value
        let limit = DictationSessionStore.maximumOrphansPerSweep
        for _ in 0...limit { try audio.write(pcm16: pcm, for: UUID()) }

        await store.removeOrphanedAudio().value

        XCTAssertEqual(audio.storedIDs().count, limit + 2)
    }

    /// The quarantine keeps a day's folder for 30 days.
    func testQuarantineEmptiesFoldersAfterThirtyDays() throws {
        let directory = makeDirectory()
        let clock = clock
        let quarantine = DictationHistoryQuarantine(
            directoryURL: DictationHistoryQuarantine.directory(inHistoryFolder: directory),
            now: { clock.now() })
        let folder = quarantine.folder(for: "dictation-audio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        clock.advance(29 * 86_400)
        quarantine.purge()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        clock.advance(2 * 86_400)
        quarantine.purge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
