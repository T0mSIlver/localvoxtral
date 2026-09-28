import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import localvoxtral

/// The history store's file, against what wiped it on 2026-09-28 (#985).
/// SwiftData's default `default.store` is shared by every non-sandboxed
/// process that names no URL: Apple's `icloudmailagent` opened it with its own
/// model, and Core Data's inferred migration dropped our table. Builds with
/// fewer `DictationSessionRecord` fields migrated it down the same way.
@MainActor
final class DictationHistoryStoreFileTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func record(_ text: String) -> DictationSessionRecord {
        DictationSessionRecord(
            startedAt: origin, finishedAt: origin.addingTimeInterval(5), rawText: text,
            provider: "p", model: "m", outputMode: "overlay_buffer", status: .completed,
            commitSucceeded: true)
    }

    /// A store at `url` holding `texts`, written and released so the next
    /// open starts from the file.
    private func seedStore(at url: URL, texts: [String]) async throws {
        let store = try DictationSessionStore.open(url: url).get()
        for text in texts { store.save(record(text)) }
        _ = await store.count()
    }

    private func rawTexts<Model: PersistentModel>(
        _ model: Model.Type, at url: URL, _ text: KeyPath<Model, String>
    ) throws -> [String] {
        let container = try ModelContainer(
            for: Schema([model]), configurations: [ModelConfiguration(schema: Schema([model]), url: url)])
        return try ModelContext(container).fetch(FetchDescriptor<Model>()).map { $0[keyPath: text] }.sorted()
    }

    // MARK: - What happened

    /// The wipe itself: another model opening our file drops our table, and
    /// ours opening it again recreates the table empty. The store now refuses
    /// the file instead of opening it.
    func testAnotherProgramsModelOpeningTheFileDropsEveryDictation() async throws {
        let url = makeDirectory().appendingPathComponent("history.store")
        try await seedStore(at: url, texts: ["one", "two"])

        _ = try rawTexts(ForeignRequestModel.self, at: url, \.path)

        guard case let .failure(failure) = DictationSessionStore.open(url: url) else {
            return XCTFail("a file holding another model's table must not open")
        }
        XCTAssertEqual(failure, .unknownContents(tables: ["ZFOREIGNREQUESTMODEL"], columns: []))
        // What opening it anyway does, and what the app did at 16:48 UTC.
        XCTAssertEqual(try rawTexts(DictationSessionRecord.self, at: url, \.rawText), [])
    }

    /// Up and down between builds: an older schema keeps the rows and drops
    /// the newer build's column. The store refuses a file with a column its
    /// model lacks.
    func testAnOlderSchemaDropsTheColumnANewerBuildAdded() async throws {
        let url = makeDirectory().appendingPathComponent("history.store")
        XCTAssertEqual(
            Schema([NewerHistory.DictationSessionRecord.self]).entities.map(\.name),
            ["DictationSessionRecord"])
        try await seedStore(at: url, texts: ["one"])

        // A newer build opens the file and fills its new field.
        do {
            let newer = Schema([NewerHistory.DictationSessionRecord.self])
            let container = try ModelContainer(
                for: newer, configurations: [ModelConfiguration(schema: newer, url: url)])
            let context = ModelContext(container)
            for row in try context.fetch(FetchDescriptor<NewerHistory.DictationSessionRecord>()) {
                row.reviewNote = "kept"
            }
            try context.save()
        }

        guard case let .failure(failure) = DictationSessionStore.open(url: url) else {
            return XCTFail("a file with a newer build's column must not open")
        }
        XCTAssertEqual(failure, .unknownContents(tables: [], columns: ["ZREVIEWNOTE"]))

        // What an older build did before the check: migrate down, then up.
        XCTAssertEqual(try rawTexts(DictationSessionRecord.self, at: url, \.rawText), ["one"])
        let newer = Schema([NewerHistory.DictationSessionRecord.self])
        let container = try ModelContainer(
            for: newer, configurations: [ModelConfiguration(schema: newer, url: url)])
        let rows = try ModelContext(container).fetch(FetchDescriptor<NewerHistory.DictationSessionRecord>())
        XCTAssertEqual(rows.map(\.rawText), ["one"])
        XCTAssertEqual(rows.map(\.reviewNote), [nil], "the round trip lost the newer column")
    }

    /// The store's own columns are all known, so a file this build wrote
    /// opens again.
    func testAFileThisBuildWroteOpensAgain() async throws {
        let url = makeDirectory().appendingPathComponent("history.store")
        try await seedStore(at: url, texts: ["one"])

        let store = try DictationSessionStore.open(url: url).get()
        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.rawText), ["one"])
    }

    /// What the app lived through from 15:10 to 16:28: another program
    /// migrates the file under a running store. Reads fail, the store says so,
    /// and the launch sweep keeps every recording.
    func testAStoreWhoseFileIsMigratedAwayFailsLoudlyAndDeletesNothing() async throws {
        let directory = makeDirectory()
        let url = directory.appendingPathComponent("history.store")
        let store = try DictationSessionStore.open(url: url).get()
        let audio = DictationAudioStore(
            directoryURL: directory.appendingPathComponent("dictation-audio", isDirectory: true))
        store.audioStore = audio
        var reported: [String?] = []
        store.onAccessFailureChange = { reported.append($0) }
        let saved = record("one")
        await store.save(saved, audio: Data([1, 0, 2, 0])).value

        _ = try rawTexts(ForeignRequestModel.self, at: url, \.path)
        _ = await store.entries()

        XCTAssertTrue(store.isFailing, "a store whose table is gone must not read as empty")
        XCTAssertEqual(reported.count, 1)
        await store.removeOrphanedAudio().value
        await store.trim(olderThan: origin.addingTimeInterval(86_400)).value
        XCTAssertEqual(audio.storedIDs(), [saved.id])
    }

    // MARK: - Upgrades from the schemas users have

    /// Each layout a shipped build wrote opens with every field kept.
    func testStoresFromEarlierSchemasOpenWithEveryRowAndField() async throws {
        let directory = makeDirectory()
        let before751 = directory.appendingPathComponent("17.store")
        let before800 = directory.appendingPathComponent("18.store")
        do {
            let schema = Schema([History17.DictationSessionRecord.self])
            let container = try ModelContainer(
                for: schema, configurations: [ModelConfiguration(schema: schema, url: before751)])
            let context = ModelContext(container)
            context.insert(History17.DictationSessionRecord(rawText: "old", joinedAgent: "claude"))
            try context.save()
        }
        do {
            let schema = Schema([History18.DictationSessionRecord.self])
            let container = try ModelContainer(
                for: schema, configurations: [ModelConfiguration(schema: schema, url: before800)])
            let context = ModelContext(container)
            context.insert(History18.DictationSessionRecord(rawText: "newer", quickCaptureDestination: "Inbox"))
            try context.save()
        }

        let old = try DictationSessionStore.open(url: before751).get()
        let oldEntries = await old.entries()
        XCTAssertEqual(oldEntries.map(\.rawText), ["old"])
        XCTAssertEqual(oldEntries.map(\.joinedAgent), ["claude"])
        XCTAssertEqual(oldEntries.map(\.editOutcome), [nil])
        let newer = try DictationSessionStore.open(url: before800).get()
        let newerEntries = await newer.entries()
        XCTAssertEqual(newerEntries.map(\.rawText), ["newer"])
        XCTAssertEqual(newerEntries.map(\.quickCaptureDestination), ["Inbox"])
    }

    // MARK: - Moving off default.store

    func testTheLegacyStoreIsCopiedOnceAndNeverChanged() async throws {
        let directory = makeDirectory()
        let legacy = directory.appendingPathComponent("default.store")
        let destination = directory.appendingPathComponent("localvoxtral/history.store")
        try await seedStore(at: legacy, texts: ["one", "two"])
        let before = try legacyFiles(legacy)

        XCTAssertEqual(
            DictationHistoryStoreFile.importLegacyStore(from: legacy, to: destination), .imported)
        XCTAssertEqual(
            DictationHistoryStoreFile.importLegacyStore(from: legacy, to: destination), .storeExists)

        XCTAssertEqual(try legacyFiles(legacy), before)
        let store = try DictationSessionStore.open(url: destination).get()
        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.rawText).sorted(), ["one", "two"])
    }

    func testALegacyStoreHoldingAnotherModelIsNotCopied() throws {
        let directory = makeDirectory()
        let legacy = directory.appendingPathComponent("default.store")
        let destination = directory.appendingPathComponent("localvoxtral/history.store")
        _ = try rawTexts(ForeignRequestModel.self, at: legacy, \.path)

        XCTAssertEqual(
            DictationHistoryStoreFile.importLegacyStore(from: legacy, to: destination),
            .legacyHoldsNoHistory(tables: ["ZFOREIGNREQUESTMODEL"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// What the mail agent left: our table gone. The app copies nothing,
    /// keeps the file, starts an empty store and says why.
    func testALegacyStoreTheMailAgentMigratedIsNotCopiedAndIsKept() async throws {
        let directory = makeDirectory()
        let legacy = directory.appendingPathComponent("default.store")
        try await seedStore(at: legacy, texts: ["one"])
        _ = try rawTexts(ForeignRequestModel.self, at: legacy, \.path)
        let before = try legacyFiles(legacy)

        let store = try DictationSessionStore.open(
            directory: directory.appendingPathComponent("localvoxtral"), legacyStore: legacy).get()

        XCTAssertEqual(store.legacyImport, .legacyHoldsNoHistory(tables: ["ZFOREIGNREQUESTMODEL"]))
        XCTAssertEqual(try legacyFiles(legacy), before)
        let count = await store.count()
        XCTAssertEqual(count, 0)
    }

    /// Our table recreated empty, as the migration back left it: an empty
    /// history is not a history to import.
    func testALegacyStoreWithAnEmptyTableIsNotCopied() async throws {
        let directory = makeDirectory()
        let legacy = directory.appendingPathComponent("default.store")
        let destination = directory.appendingPathComponent("localvoxtral/history.store")
        try await seedStore(at: legacy, texts: [])

        XCTAssertEqual(
            DictationHistoryStoreFile.importLegacyStore(from: legacy, to: destination),
            .legacyHoldsNoHistory(tables: ["ZDICTATIONSESSIONRECORD"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// A Core Data file without our table lost it; opening it would only
    /// recreate the table empty.
    func testAStoreWithoutTheDictationTableIsRefused() async throws {
        let url = makeDirectory().appendingPathComponent("history.store")
        try await seedStore(at: url, texts: ["one"])
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE ZDICTATIONSESSIONRECORD", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        guard case let .failure(failure) = DictationSessionStore.open(url: url) else {
            return XCTFail("a store without its table must not open")
        }
        XCTAssertEqual(failure, .missingHistoryTable)
    }

    func testTheStoreOpensUnderItsOwnName() throws {
        let directory = makeDirectory().appendingPathComponent("not-yet-created", isDirectory: true)
        _ = try DictationSessionStore.open(directory: directory).get()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("history.store").path))
        XCTAssertEqual(DictationHistoryStoreFile.defaultDirectoryURL().lastPathComponent, "localvoxtral")
    }

    private func legacyFiles(_ url: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            files[suffix] = try Data(contentsOf: URL(fileURLWithPath: url.path + suffix))
        }
        return files
    }
}

/// Another program's model, like `icloudmailagent`'s `APIRequestModel`.
@Model
final class ForeignRequestModel {
    var path: String
    init(path: String) { self.path = path }
}

/// `DictationSessionRecord` as a later build might write it: every field this
/// build has, plus one.
enum NewerHistory {
    @Model
    final class DictationSessionRecord {
        var id: UUID
        var startedAt: Date
        var finishedAt: Date
        var rawText: String
        var polishedText: String?
        var polishingDurationSeconds: Double?
        var provider: String
        var model: String
        var outputMode: String
        var targetAppBundleID: String?
        var status: String
        var commitSucceeded: Bool
        var polishProfile: String?
        var polishContextSummary: String?
        var projectKey: String?
        var projectName: String?
        var joinedAgent: String?
        var quickCaptureDestination: String?
        var editOutcome: String?
        var reviewNote: String?

        init(rawText: String) {
            id = UUID()
            startedAt = Date(timeIntervalSince1970: 0)
            finishedAt = Date(timeIntervalSince1970: 0)
            self.rawText = rawText
            provider = ""
            model = ""
            outputMode = ""
            status = ""
            commitSucceeded = true
        }
    }
}

/// `DictationSessionRecord` before quick capture (#751): the 20-column layout.
enum History17 {
    @Model
    final class DictationSessionRecord {
        var id: UUID
        var startedAt: Date
        var finishedAt: Date
        var rawText: String
        var polishedText: String?
        var polishingDurationSeconds: Double?
        var provider: String
        var model: String
        var outputMode: String
        var targetAppBundleID: String?
        var status: String
        var commitSucceeded: Bool
        var polishProfile: String?
        var polishContextSummary: String?
        var projectKey: String?
        var projectName: String?
        var joinedAgent: String?

        init(rawText: String, joinedAgent: String?) {
            id = UUID()
            startedAt = Date(timeIntervalSince1970: 1_800_000_000)
            finishedAt = Date(timeIntervalSince1970: 1_800_000_005)
            self.rawText = rawText
            provider = "p"
            model = "m"
            outputMode = "overlay_buffer"
            status = "completed"
            commitSucceeded = true
            self.joinedAgent = joinedAgent
        }
    }
}

/// `DictationSessionRecord` after quick capture, before the edit verdict
/// (#800): the 21-column layout.
enum History18 {
    @Model
    final class DictationSessionRecord {
        var id: UUID
        var startedAt: Date
        var finishedAt: Date
        var rawText: String
        var polishedText: String?
        var polishingDurationSeconds: Double?
        var provider: String
        var model: String
        var outputMode: String
        var targetAppBundleID: String?
        var status: String
        var commitSucceeded: Bool
        var polishProfile: String?
        var polishContextSummary: String?
        var projectKey: String?
        var projectName: String?
        var joinedAgent: String?
        var quickCaptureDestination: String?

        init(rawText: String, quickCaptureDestination: String?) {
            id = UUID()
            startedAt = Date(timeIntervalSince1970: 1_800_000_000)
            finishedAt = Date(timeIntervalSince1970: 1_800_000_005)
            self.rawText = rawText
            provider = "p"
            model = "m"
            outputMode = "overlay_buffer"
            status = "completed"
            commitSucceeded = true
            self.quickCaptureDestination = quickCaptureDestination
        }
    }
}
