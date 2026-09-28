import Foundation
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

    func testTheStoreOpensUnderItsOwnName() throws {
        let directory = makeDirectory()
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
