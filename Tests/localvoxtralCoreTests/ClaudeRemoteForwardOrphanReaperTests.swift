import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore

private final class MemoryLedgerStore: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<[String: Data]>([:])
    func read(from url: URL) throws -> Data? { contents.withLock { $0[url.path] } }
    func write(_ data: Data, to url: URL) throws { contents.withLock { $0[url.path] = data } }
}

/// A stand-in kernel process table: what `inspect` answers, and which signals
/// actually end the process. No wall clock anywhere — the reaper polls on an
/// injected sleep that returns immediately.
private final class ProcessTableFake: @unchecked Sendable {
    private let live = Mutex<[Int32: ClaudeRemoteForwardPidRecord]>([:])
    private let sent = Mutex<[Int32]>([])
    private let signalTargets = Mutex<[pid_t]>([])
    private let lethalSignals: Set<Int32>

    /// - Parameter running: other live processes, such as the app copies that
    ///   spawned the forwards. Signals end only the process they target.
    init(
        live record: ClaudeRemoteForwardPidRecord?,
        running: [ClaudeRemoteForwardPidRecord] = [],
        dyingOn lethalSignals: Set<Int32>
    ) {
        live.withLock { table in
            for process in running + [record].compactMap({ $0 }) { table[process.pid] = process }
        }
        self.lethalSignals = lethalSignals
    }

    var signals: [Int32] { sent.withLock { $0 } }
    var targets: [pid_t] { signalTargets.withLock { $0 } }

    func inspect(_ pid: pid_t) -> ClaudeRemoteForwardPidRecord? {
        live.withLock { $0[Int32(pid)] }
    }

    func sendSignal(_ pid: pid_t, _ signalNumber: Int32) {
        signalTargets.withLock { $0.append(pid) }
        sent.withLock { $0.append(signalNumber) }
        if lethalSignals.contains(signalNumber) {
            _ = live.withLock { $0.removeValue(forKey: abs(Int32(pid))) }
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
        ledger: ClaudeRemoteForwardPidLedger,
        table: ProcessTableFake,
        ownCopy: ClaudeRemoteForwardOwner? = nil
    ) -> ClaudeRemoteForwardOrphanReaper {
        ClaudeRemoteForwardOrphanReaper(
            ledger: ledger,
            ownCopy: ownCopy,
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

    func testAPosixSpawnForwardReapsItsOwnedProcessGroup() async {
        var orphan = record(pid: 4242)
        orphan.processGroupID = 4242
        let ledger = makeLedger(with: ["herdr-local:host": orphan])
        let table = ProcessTableFake(live: orphan, dyingOn: [SIGTERM])

        await makeReaper(ledger: ledger, table: table).reap()

        XCTAssertEqual(table.targets, [-4242])
        XCTAssertEqual(table.signals, [SIGTERM])
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

    // MARK: - Which copy of the app spawned the forward (#892)

    private let installed = "/Applications/localvoxtral.app/Contents/MacOS/localvoxtral"
    private let smokeCopy = "/private/var/folders/xy/T/tmp.K2wQ/localvoxtral.app/Contents/MacOS/localvoxtral"

    private func copy(pid: Int32, at path: String) -> ClaudeRemoteForwardPidRecord {
        ClaudeRemoteForwardPidRecord(pid: pid, startSeconds: 222, startMicroseconds: 3, executablePath: path)
    }

    private func forward(pid: Int32, spawnedBy owner: ClaudeRemoteForwardPidRecord) -> ClaudeRemoteForwardPidRecord {
        var forward = record(pid: pid)
        forward.owner = ClaudeRemoteForwardOwner(owner)
        return forward
    }

    /// Two copies of the same install share Application Support, so the
    /// second copy's ledger reads the first's record. The reap that runs
    /// before the second copy's first forward starts must not touch it.
    func testASecondCopysForwardStartLeavesARunningCopysForwardAlone() async {
        let store = MemoryLedgerStore()
        let fileURL = URL(fileURLWithPath: "/tmp/lvx-reaper-test/\(UUID().uuidString).json")
        let first = copy(pid: 29_873, at: installed)
        let firstForward = forward(pid: 96_199, spawnedBy: first)
        ClaudeRemoteForwardPidLedger(fileURL: fileURL, io: store).remember(hostID: "ha2c72ef6", record: firstForward)

        let second = copy(pid: 68_513, at: installed)
        let secondLedger = ClaudeRemoteForwardPidLedger(fileURL: fileURL, io: store)
        let table = ProcessTableFake(live: firstForward, running: [first, second], dyingOn: [SIGTERM, SIGKILL])
        await makeReaper(ledger: secondLedger, table: table, ownCopy: ClaudeRemoteForwardOwner(second)).reap()

        XCTAssertTrue(table.signals.isEmpty, "the first copy's forward is not an orphan")
        XCTAssertEqual(secondLedger.records(), ["ha2c72ef6": firstForward], "its record stays for its own copy")
    }

    /// The field case: a CI launch smoke, a temporary copy, ran after the
    /// copy that spawned the forward had quit.
    func testAnotherInstallsLeftoverForwardIsLeftAlone() async {
        let quit = copy(pid: 29_873, at: installed)
        let leftover = forward(pid: 96_199, spawnedBy: quit)
        let ledger = makeLedger(with: ["ha2c72ef6": leftover])
        let table = ProcessTableFake(live: leftover, dyingOn: [SIGTERM, SIGKILL])
        await makeReaper(
            ledger: ledger, table: table, ownCopy: ClaudeRemoteForwardOwner(copy(pid: 19_523, at: smokeCopy))
        ).reap()

        XCTAssertTrue(table.signals.isEmpty)
        XCTAssertEqual(ledger.records(), ["ha2c72ef6": leftover])
    }

    func testThisInstallsForwardIsReapedOnceTheCopyThatSpawnedItIsGone() async {
        let crashed = copy(pid: 29_873, at: installed)
        let orphan = forward(pid: 96_199, spawnedBy: crashed)
        let ledger = makeLedger(with: ["ha2c72ef6": orphan])
        let table = ProcessTableFake(live: orphan, dyingOn: [SIGTERM])
        await makeReaper(
            ledger: ledger, table: table, ownCopy: ClaudeRemoteForwardOwner(copy(pid: 68_513, at: installed))
        ).reap()

        XCTAssertEqual(table.signals, [SIGTERM])
        XCTAssertTrue(ledger.records().isEmpty)
    }

    /// A pid reused by another process does not keep the dead copy alive.
    func testACopyWhosePidWasReusedCountsAsGone() async {
        let crashed = copy(pid: 29_873, at: installed)
        let orphan = forward(pid: 96_199, spawnedBy: crashed)
        var reused = crashed
        reused.startSeconds = 999
        let ledger = makeLedger(with: ["ha2c72ef6": orphan])
        let table = ProcessTableFake(live: orphan, running: [reused], dyingOn: [SIGTERM])
        await makeReaper(
            ledger: ledger, table: table, ownCopy: ClaudeRemoteForwardOwner(copy(pid: 68_513, at: installed))
        ).reap()

        XCTAssertEqual(table.signals, [SIGTERM])
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
