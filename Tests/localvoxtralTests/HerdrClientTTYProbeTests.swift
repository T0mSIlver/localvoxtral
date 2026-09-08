import Darwin
import Synchronization
import XCTest
@testable import localvoxtral

#if canImport(Darwin)
final class HerdrClientTTYProbeTests: XCTestCase {
    func testStatFailureRefusesWithoutReadingProcessTable() {
        let processTableReads = Mutex(0)
        let result = HerdrClientTTYProbe.isHerdrClient(
            onTTYDevicePath: "/dev/not-present",
            deviceID: { _ in nil },
            processNames: { _ in
                processTableReads.withLock { $0 += 1 }
                return ["herdr"]
            }
        )

        XCTAssertFalse(result)
        XCTAssertEqual(processTableReads.withLock { $0 }, 0)
    }

    func testProcessTableFailureRefuses() {
        XCTAssertFalse(
            HerdrClientTTYProbe.isHerdrClient(
                onTTYDevicePath: "/dev/ttys001",
                deviceID: { _ in dev_t(123) },
                processNames: { _ in nil }
            )
        )
    }

    func testHerdrDecisionRequiresExactProcessCommandMatch() {
        XCTAssertTrue(
            HerdrClientTTYProbe.isHerdrClient(
                onTTYDevicePath: "/dev/ttys001",
                deviceID: { _ in dev_t(123) },
                processNames: { _ in ["zsh", "herdr"] }
            )
        )
        XCTAssertFalse(
            HerdrClientTTYProbe.isHerdrClient(
                onTTYDevicePath: "/dev/ttys001",
                deviceID: { _ in dev_t(123) },
                processNames: { _ in ["zsh", "herdr-helper"] }
            )
        )
    }

    // MARK: - Counting client surfaces (issue #286)

    private func entry(
        pid: Int32, name: String, tty: dev_t?, uid: uid_t = 0, group: Int32 = 700
    ) -> TTYProcessTable.Entry {
        TTYProcessTable.Entry(
            pid: pid,
            effectiveUserID: uid == 0 ? geteuid() : uid,
            name: name,
            ttyDevice: tty,
            processGroupID: group
        )
    }

    // Two panes of one client are one surface, and the detached server has no
    // controlling terminal to be counted on.
    func testClientSurfaceCountCountsJobsNotProcesses() {
        let count = HerdrClientTTYProbe.clientSurfaceCount(processes: [
            entry(pid: 1, name: "herdr", tty: dev_t(11), group: 700),
            entry(pid: 2, name: "herdr", tty: dev_t(11), group: 700),
            entry(pid: 3, name: "herdr", tty: dev_t(12), group: 900),
            entry(pid: 4, name: "herdr", tty: nil, group: 1),
            entry(pid: 5, name: "zsh", tty: dev_t(13), group: 950)
        ])
        XCTAssertEqual(count, 2)
    }

    // Suspend one client, start another in the same terminal: one device, two
    // jobs, and two surfaces the single machine selection cannot speak for.
    func testClientSurfaceCountSeesTwoJobsOnOneDevice() {
        let count = HerdrClientTTYProbe.clientSurfaceCount(processes: [
            entry(pid: 1, name: "herdr", tty: dev_t(11), group: 700),
            entry(pid: 2, name: "herdr", tty: dev_t(11), group: 800)
        ])
        XCTAssertEqual(count, 2)
    }

    // Another user's herdr is on another user's screen.
    func testClientSurfaceCountIgnoresOtherUsers() {
        let count = HerdrClientTTYProbe.clientSurfaceCount(processes: [
            entry(pid: 1, name: "herdr", tty: dev_t(11)),
            entry(pid: 2, name: "herdr", tty: dev_t(12), uid: geteuid() &+ 1)
        ])
        XCTAssertEqual(count, 1)
    }

    // An unwalkable process table is unknown, and the caller treats unknown as
    // "not exactly one".
    func testClientSurfaceCountIsNilWithoutAProcessTable() {
        XCTAssertNil(HerdrClientTTYProbe.clientSurfaceCount(processes: nil))
    }
}
#endif
