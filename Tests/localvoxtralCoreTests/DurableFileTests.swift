import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore

/// `DurableFile.write`, the replace every JSON store shares (#1042): a power
/// cut must leave the old bytes or the new ones, never an empty file.
final class DurableFileTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-file-\(UUID().uuidString)")
            .appendingPathComponent("inbox.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private enum Call: Equatable {
        case sync(String)
        case rename(String, String)
    }

    private final class CallLog: Sendable {
        private let calls = Mutex<[Call]>([])
        func append(_ call: Call) { calls.withLock { $0.append(call) } }
        var recorded: [Call] { calls.withLock { $0 } }
    }

    /// The live syscalls, recorded in order; `failSync` fails the sync of
    /// the temporary file.
    private func recording(_ calls: CallLog, failSync: Bool = false) -> DurableFileSystem {
        DurableFileSystem(
            sync: { descriptor, path in
                calls.append(.sync(path))
                if failSync, path.hasSuffix(".tmp") {
                    errno = EIO
                    return -1
                }
                return DurableFileSystem.live.sync(descriptor, path)
            },
            rename: { source, destination in
                calls.append(.rename(source, destination))
                return DurableFileSystem.live.rename(source, destination)
            })
    }

    private func directoryContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path).sorted()
    }

    func testWriteSyncsTheFileBeforeTheRenameAndTheDirectoryAfterIt() throws {
        try Data("old".utf8).write(to: fileURL)
        let calls = CallLog()

        try DurableFile.write(Data("new".utf8), to: fileURL, fileSystem: recording(calls))

        let recorded = calls.recorded
        guard recorded.count == 3, case .sync(let temporary) = recorded[0] else {
            return XCTFail("calls: \(recorded)")
        }
        XCTAssertEqual(URL(fileURLWithPath: temporary).deletingLastPathComponent().path,
                       fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(recorded[1], .rename(temporary, fileURL.path))
        XCTAssertEqual(recorded[2], .sync(fileURL.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("new".utf8))
        XCTAssertEqual(try directoryContents(), ["inbox.json"], "no temporary file left")
    }

    func testAFailedSyncKeepsTheOldBytesAndRemovesTheTemporaryFile() throws {
        try Data("old".utf8).write(to: fileURL)
        let calls = CallLog()

        XCTAssertThrowsError(
            try DurableFile.write(Data("new".utf8), to: fileURL, fileSystem: recording(calls, failSync: true)))

        XCTAssertFalse(calls.recorded.contains { if case .rename = $0 { true } else { false } })
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("old".utf8))
        XCTAssertEqual(try directoryContents(), ["inbox.json"])
    }

    func testTheNewFileIsPrivate() throws {
        try DurableFile.write(Data("words".utf8), to: fileURL)

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }
}
