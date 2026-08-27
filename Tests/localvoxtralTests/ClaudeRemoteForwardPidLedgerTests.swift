import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

private final class MemoryLedgerStore: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<[String: Data]>([:])
    func read(from url: URL) throws -> Data? { contents.withLock { $0[url.path] } }
    func write(_ data: Data, to url: URL) throws { contents.withLock { $0[url.path] = data } }
}

final class ClaudeRemoteForwardPidLedgerTests: XCTestCase {
    private func makeURL() -> URL {
        URL(fileURLWithPath: "/tmp/lvx-pid-ledger-test/\(UUID().uuidString).json")
    }

    private func record(
        pid: Int32, startSeconds: UInt64 = 111
    ) -> ClaudeRemoteForwardPidRecord {
        ClaudeRemoteForwardPidRecord(
            pid: pid,
            startSeconds: startSeconds,
            startMicroseconds: 7,
            executablePath: "/usr/bin/ssh"
        )
    }

    func testRememberAndForgetRoundTrip() {
        let ledger = ClaudeRemoteForwardPidLedger(fileURL: makeURL(), io: MemoryLedgerStore())
        let recorded = record(pid: 4242)
        ledger.remember(hostID: "host", record: recorded)
        XCTAssertEqual(ledger.records(), ["host": recorded])
        ledger.forget(hostID: "host", pid: 4242)
        XCTAssertTrue(ledger.records().isEmpty)
    }

    func testARecordSurvivesReconstruction() {
        // The whole point of the ledger: the process that wrote it is dead by
        // the time anyone reads it, so the record must round-trip through the
        // store, not through the instance.
        let url = makeURL()
        let store = MemoryLedgerStore()
        let recorded = record(pid: 4242)
        ClaudeRemoteForwardPidLedger(fileURL: url, io: store)
            .remember(hostID: "host", record: recorded)
        let reloaded = ClaudeRemoteForwardPidLedger(fileURL: url, io: store)
        XCTAssertEqual(reloaded.records(), ["host": recorded])
    }

    func testForgetIsPidScoped() {
        // A forget racing a fresh spawn for the same host must not erase the
        // NEW process's record — that record is the next launch's only way to
        // find an orphan.
        let ledger = ClaudeRemoteForwardPidLedger(fileURL: makeURL(), io: MemoryLedgerStore())
        let replacement = record(pid: 4343)
        ledger.remember(hostID: "host", record: record(pid: 4242))
        ledger.remember(hostID: "host", record: replacement)
        ledger.forget(hostID: "host", pid: 4242)
        XCTAssertEqual(ledger.records(), ["host": replacement])
    }

    func testCorruptContentsReadAsEmpty() throws {
        // The ledger is a cleanup aid, not a registry: the safe reading of
        // "cannot tell what we spawned" is "kill nothing".
        let url = makeURL()
        let store = MemoryLedgerStore()
        try store.write(Data("not json".utf8), to: url)
        XCTAssertTrue(
            ClaudeRemoteForwardPidLedger(fileURL: url, io: store).records().isEmpty
        )
    }

    func testMissingFileReadsAsEmpty() {
        XCTAssertTrue(
            ClaudeRemoteForwardPidLedger(fileURL: makeURL(), io: MemoryLedgerStore())
                .records().isEmpty
        )
    }
}
