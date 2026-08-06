import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

private final class MemoryLedgerStore: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<[String: Data]>([:])
    func read(from url: URL) throws -> Data? { contents.withLock { $0[url.path] } }
    func write(_ data: Data, to url: URL) throws { contents.withLock { $0[url.path] = data } }
}

/// A stand-in kernel process table: what `inspect` answers, and which signals
/// actually end the process. No wall clock anywhere — the reaper polls on an
/// injected sleep that returns immediately.
private final class ProcessTableFake: @unchecked Sendable {
    private let live = Mutex<ClaudeRemoteForwardPidRecord?>(nil)
    private let sent = Mutex<[Int32]>([])
    private let lethalSignals: Set<Int32>

    init(live record: ClaudeRemoteForwardPidRecord?, dyingOn lethalSignals: Set<Int32>) {
        live.withLock { $0 = record }
        self.lethalSignals = lethalSignals
    }

    var signals: [Int32] { sent.withLock { $0 } }

    func inspect(_ pid: pid_t) -> ClaudeRemoteForwardPidRecord? {
        live.withLock { $0?.pid == Int32(pid) ? $0 : nil }
    }

    func sendSignal(_ pid: pid_t, _ signalNumber: Int32) {
        sent.withLock { $0.append(signalNumber) }
        if lethalSignals.contains(signalNumber) {
            live.withLock { $0 = nil }
        }
    }
}

final class ClaudeRemoteForwardOrphanReaperTests: XCTestCase {
    private func makeLedger(
        with records: [String: ClaudeRemoteForwardPidRecord]
    ) -> ClaudeRemoteForwardPidLedger {
        let ledger = ClaudeRemoteForwardPidLedger(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-reaper-test/\(UUID().uuidString).json"),
            io: MemoryLedgerStore()
        )
        for (hostID, record) in records { ledger.remember(hostID: hostID, record: record) }
        return ledger
    }

    private func makeReaper(
        ledger: ClaudeRemoteForwardPidLedger, table: ProcessTableFake
    ) -> ClaudeRemoteForwardOrphanReaper {
        ClaudeRemoteForwardOrphanReaper(
            ledger: ledger,
            inspect: { table.inspect($0) },
            sendSignal: { table.sendSignal($0, $1) },
            sleepFor: { _ in }
        )
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

    func testADeadRecordIsRetiredWithoutSignals() async {
        let ledger = makeLedger(with: ["host": record(pid: 4242)])
        let table = ProcessTableFake(live: nil, dyingOn: [])
        await makeReaper(ledger: ledger, table: table).reap()
        XCTAssertTrue(table.signals.isEmpty, "a dead process needs no reaping")
        XCTAssertTrue(ledger.records().isEmpty)
    }

    func testAReusedPidIsNeverSignalled() async {
        // The safety property the whole design hangs on: after a reboot the
        // recorded pid can belong to anything. Identity is pid PLUS kernel
        // start time, and a mismatch retires the record without a signal.
        let ledger = makeLedger(with: ["host": record(pid: 4242, startSeconds: 111)])
        let table = ProcessTableFake(
            live: record(pid: 4242, startSeconds: 999), dyingOn: [SIGTERM, SIGKILL]
        )
        await makeReaper(ledger: ledger, table: table).reap()
        XCTAssertTrue(table.signals.isEmpty, "an innocent process inherited this pid")
        XCTAssertTrue(ledger.records().isEmpty)
    }

    func testADifferentExecutableAtTheSamePidIsNeverSignalled() async {
        // The path is not decoration on the start-time check: a record whose
        // pid AND start time somehow both match must still be retired without
        // a signal when the executable is not the one we spawned. Pins that
        // `executablePath` participates in identity.
        let recorded = record(pid: 4242)
        var impostor = recorded
        impostor.executablePath = "/bin/cat"
        let ledger = makeLedger(with: ["host": recorded])
        let table = ProcessTableFake(live: impostor, dyingOn: [SIGTERM, SIGKILL])
        await makeReaper(ledger: ledger, table: table).reap()
        XCTAssertTrue(table.signals.isEmpty, "not the binary we spawned")
        XCTAssertTrue(ledger.records().isEmpty)
    }

    func testALiveOrphanDiesOnSIGTERMAndIsForgotten() async {
        let orphan = record(pid: 4242)
        let ledger = makeLedger(with: ["host": orphan])
        let table = ProcessTableFake(live: orphan, dyingOn: [SIGTERM])
        await makeReaper(ledger: ledger, table: table).reap()
        XCTAssertEqual(table.signals, [SIGTERM], "an orphan that honours SIGTERM is never SIGKILLed")
        XCTAssertTrue(ledger.records().isEmpty)
    }

    func testASurvivorOfSIGTERMGetsSIGKILL() async {
        let orphan = record(pid: 4242)
        let ledger = makeLedger(with: ["host": orphan])
        let table = ProcessTableFake(live: orphan, dyingOn: [SIGKILL])
        await makeReaper(ledger: ledger, table: table).reap()
        XCTAssertEqual(table.signals, [SIGTERM, SIGKILL])
        XCTAssertTrue(ledger.records().isEmpty)
    }

    func testASurvivorOfSIGKILLKeepsItsRecord() async {
        // A process wedged in an uninterruptible wait can outlive SIGKILL for
        // now. Its record still names OUR process, and keeping it is what lets
        // the next launch try again instead of going blind.
        let orphan = record(pid: 4242)
        let ledger = makeLedger(with: ["host": orphan])
        let table = ProcessTableFake(live: orphan, dyingOn: [])
        await makeReaper(ledger: ledger, table: table).reap()
        XCTAssertEqual(table.signals, [SIGTERM, SIGKILL])
        XCTAssertEqual(ledger.records(), ["host": orphan])
    }

    func testEveryRecordedHostIsReaped() async {
        let first = record(pid: 4242)
        let second = record(pid: 4343)
        let ledger = makeLedger(with: ["one": first, "two": second])
        let table = ProcessTableFake(live: first, dyingOn: [SIGTERM])
        await makeReaper(ledger: ledger, table: table).reap()
        XCTAssertEqual(table.signals, [SIGTERM], "only the live orphan is signalled")
        XCTAssertTrue(ledger.records().isEmpty)
    }

    func testPollCountCoversTheGraceWindow() {
        XCTAssertEqual(
            ClaudeRemoteForwardOrphanReaper.pollCount(
                limit: .seconds(2), interval: .milliseconds(50)
            ),
            40
        )
        XCTAssertEqual(
            ClaudeRemoteForwardOrphanReaper.pollCount(
                limit: .milliseconds(1), interval: .seconds(1)
            ),
            1, "a limit shorter than one interval still polls once"
        )
    }
}
