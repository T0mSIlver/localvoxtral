import Foundation
import XCTest

@testable import SpeechEngineText

final class ParentProcessWatchdogTests: XCTestCase {
    func testFiresImmediatelyWhenTheParentIsAlreadyDead() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        let fired = expectation(description: "watchdog fired for a dead pid")
        let watchdog = ParentProcessWatchdog(parentPID: process.processIdentifier) {
            fired.fulfill()
        }
        withExtendedLifetime(watchdog) {
            wait(for: [fired], timeout: 10)
        }
    }

    func testFiresWhenTheParentExits() throws {
        // /bin/cat with an open stdin pipe blocks until it is terminated, so
        // the test decides when the exit happens.
        let process = Process()
        process.executableURL = URL(filePath: "/bin/cat")
        process.standardInput = Pipe()
        try process.run()

        let fired = expectation(description: "watchdog fired")
        let watchdog = ParentProcessWatchdog(parentPID: process.processIdentifier) {
            fired.fulfill()
        }
        process.terminate()
        withExtendedLifetime(watchdog) {
            wait(for: [fired], timeout: 10)
        }
    }

    /// The parent dies while the guarded operation (speechd's model load) is
    /// still running: the watchdog fires then, not once the operation returns
    /// (#1586).
    func testAGuardedOperationIsWatchedFromItsStart() async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/cat")
        process.standardInput = Pipe()
        try process.run()

        let fired = expectation(description: "watchdog fired during the operation")
        let firedDuringOperation = await ParentProcessWatchdog.guarding(
            parentPID: process.processIdentifier,
            onParentExit: { fired.fulfill() }
        ) {
            process.terminate()
            return await XCTWaiter().fulfillment(of: [fired], timeout: 10) == .completed
        }

        XCTAssertTrue(firedDuringOperation, "the watchdog must watch the parent while the operation runs")
    }

    func testGuardingWithoutAParentRunsTheOperation() async {
        let result = await ParentProcessWatchdog.guarding(parentPID: nil, onParentExit: {}) { 42 }
        XCTAssertEqual(result, 42)
    }
}
