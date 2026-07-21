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
}
#endif
