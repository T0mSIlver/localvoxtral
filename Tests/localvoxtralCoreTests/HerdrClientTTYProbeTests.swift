#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Synchronization
import XCTest
@testable import localvoxtralCore

#if canImport(Darwin) || canImport(Glibc)
final class HerdrClientTTYProbeTests: XCTestCase {
    func testStatFailureRefusesWithoutReadingProcessTable() {
        let processTableReads = Mutex(0)
        let result = HerdrClientTTYProbe.isHerdrClient(
            onTTYDevicePath: "/dev/not-present",
            deviceID: { _ in nil },
            processes: { _ in
                processTableReads.withLock { $0 += 1 }
                return [Self.foreground(pid: 1, name: "herdr")]
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
                processes: { _ in nil }
            )
        )
    }

    func testHerdrDecisionRequiresExactProcessCommandMatch() {
        XCTAssertTrue(
            HerdrClientTTYProbe.isHerdrClient(
                onTTYDevicePath: "/dev/ttys001",
                deviceID: { _ in dev_t(123) },
                processes: { _ in [Self.entry(pid: 1, name: "zsh", tty: 123, group: 600), Self.foreground(pid: 2, name: "herdr")] }
            )
        )
        XCTAssertFalse(
            HerdrClientTTYProbe.isHerdrClient(
                onTTYDevicePath: "/dev/ttys001",
                deviceID: { _ in dev_t(123) },
                processes: { _ in [Self.entry(pid: 1, name: "zsh", tty: 123, group: 600), Self.foreground(pid: 2, name: "herdr-helper")] }
            )
        )
    }

    // Ctrl-Z on the outer client hands the terminal back to the shell. The
    // stopped client still has the tty, but what the surface shows is the
    // shell, so the herdr arm must not write into the hidden agent (#1602).
    func testSuspendedHerdrClientDoesNotAuthorizeTheSurface() {
        let shellGroup: Int32 = 900
        XCTAssertFalse(
            HerdrClientTTYProbe.isHerdrClient(
                onTTYDevicePath: "/dev/ttys001",
                deviceID: { _ in dev_t(123) },
                processes: { _ in
                    [
                        Self.entry(pid: 1, name: "herdr", tty: 123, group: 700, foregroundGroup: shellGroup),
                        Self.entry(pid: 2, name: "zsh", tty: 123, group: shellGroup, foregroundGroup: shellGroup)
                    ]
                }
            )
        )
    }

    // MARK: - Counting client surfaces (issue #286)

    private static func entry(
        pid: Int32, name: String, tty: dev_t?, uid: uid_t = 0, group: Int32 = 700, foregroundGroup: Int32 = 0
    ) -> TTYProcessTable.Entry {
        TTYProcessTable.Entry(
            pid: pid,
            effectiveUserID: uid == 0 ? geteuid() : uid,
            name: name,
            ttyDevice: tty,
            processGroupID: group,
            terminalForegroundGroupID: foregroundGroup
        )
    }

    /// A process in its terminal's foreground job on device 123.
    private static func foreground(pid: Int32, name: String) -> TTYProcessTable.Entry {
        Self.entry(pid: pid, name: name, tty: 123, group: 800, foregroundGroup: 800)
    }

    // Two panes of one client are one surface, and the detached server has no
    // controlling terminal to be counted on.
    func testClientSurfaceCountCountsJobsNotProcesses() {
        let count = HerdrClientTTYProbe.clientSurfaceCount(processes: [
            Self.entry(pid: 1, name: "herdr", tty: dev_t(11), group: 700),
            Self.entry(pid: 2, name: "herdr", tty: dev_t(11), group: 700),
            Self.entry(pid: 3, name: "herdr", tty: dev_t(12), group: 900),
            Self.entry(pid: 4, name: "herdr", tty: nil, group: 1),
            Self.entry(pid: 5, name: "zsh", tty: dev_t(13), group: 950)
        ])
        XCTAssertEqual(count, 2)
    }

    // Suspend one client, start another in the same terminal: one device, two
    // jobs, and two surfaces the single machine selection cannot speak for.
    func testClientSurfaceCountSeesTwoJobsOnOneDevice() {
        let count = HerdrClientTTYProbe.clientSurfaceCount(processes: [
            Self.entry(pid: 1, name: "herdr", tty: dev_t(11), group: 700),
            Self.entry(pid: 2, name: "herdr", tty: dev_t(11), group: 800)
        ])
        XCTAssertEqual(count, 2)
    }

    // Another user's herdr is on another user's screen.
    func testClientSurfaceCountIgnoresOtherUsers() {
        let count = HerdrClientTTYProbe.clientSurfaceCount(processes: [
            Self.entry(pid: 1, name: "herdr", tty: dev_t(11)),
            Self.entry(pid: 2, name: "herdr", tty: dev_t(12), uid: geteuid() &+ 1)
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
