import XCTest

@testable import PolishHelperCore

final class ParentProcessWatchdogTests: XCTestCase {
    func testFiresWhenObservedProcessExits() throws {
        // /bin/cat with an open stdin pipe blocks until we terminate it, so
        // the exit event is entirely under the test's control (no sleeps).
        let process = Process()
        process.executableURL = URL(filePath: "/bin/cat")
        process.standardInput = Pipe()
        try process.run()

        let fired = expectation(description: "watchdog fired")
        let watchdog = ParentProcessWatchdog(parentPID: process.processIdentifier) {
            fired.fulfill()
        }
        _ = watchdog

        process.terminate()
        wait(for: [fired], timeout: 10)
    }

    func testFiresImmediatelyWhenProcessIsAlreadyDead() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        let fired = expectation(description: "watchdog fired for dead pid")
        let watchdog = ParentProcessWatchdog(parentPID: process.processIdentifier) {
            fired.fulfill()
        }
        _ = watchdog
        wait(for: [fired], timeout: 10)
    }
}
