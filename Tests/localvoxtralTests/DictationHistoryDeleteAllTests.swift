import Foundation
import XCTest
@testable import localvoxtral

/// Delete All with two running copies on one data folder.
@MainActor
final class DictationHistoryDeleteAllTests: XCTestCase {
    private let pcm = Data([1, 0, 2, 0])

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-delete-all-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func openStore(in directory: URL) throws -> DictationSessionStore {
        let store = try DictationSessionStore.open(url: directory.appendingPathComponent("history.store")).get()
        store.audioStore = DictationAudioStore(
            directoryURL: directory.appendingPathComponent("dictation-audio", isDirectory: true))
        store.diagnosticRecordStore = DiagnosticRecordStore(
            directoryURL: directory.appendingPathComponent("diagnostic-records", isDirectory: true))
        return store
    }

    private func record(_ text: String) -> DictationSessionRecord {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return DictationSessionRecord(
            startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(5), rawText: text,
            provider: "p", model: "m", outputMode: "overlay_buffer", status: .completed,
            commitSucceeded: true)
    }

    private func writeDiagnosticRecord(for id: UUID, in directory: URL) throws {
        let folder = directory.appendingPathComponent("diagnostic-records", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = DiagnosticRecordFileName.name(id: id, capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try Data("{}".utf8).write(to: folder.appendingPathComponent(name))
    }

    /// Copy B saves a dictation between copy A's row deletion and its file
    /// deletion. A's Delete All takes its own dictation's files and leaves
    /// B's row, audio and diagnostic record.
    func testDeleteAllPreservesAttachmentsOfAnotherCopiesLaterSave() async throws {
        let directory = makeDirectory()
        let first = try openStore(in: directory)
        let second = try openStore(in: directory)
        let old = record("old")
        await first.save(old, audio: pcm).value
        try writeDiagnosticRecord(for: old.id, in: directory)

        let (rowsGone, rowsGoneSignal) = AsyncStream<Void>.makeStream()
        let resume = DispatchSemaphore(value: 0)
        first.debugAfterDeleteAllSave = {
            rowsGoneSignal.yield()
            resume.wait()
        }
        let deleting = first.deleteAll()
        var signals = rowsGone.makeAsyncIterator()
        await signals.next()

        let later = record("later")
        await second.save(later, audio: pcm).value
        try writeDiagnosticRecord(for: later.id, in: directory)
        resume.signal()
        await deleting.value

        let audio = try XCTUnwrap(second.audioStore)
        let records = try XCTUnwrap(second.diagnosticRecordStore)
        XCTAssertEqual(audio.storedIDs(), [later.id])
        XCTAssertEqual(records.storedIDs(), [later.id])
        let reopened = try openStore(in: directory)
        let ids = await reopened.entries().map(\.id)
        XCTAssertEqual(ids, [later.id])
    }
}
