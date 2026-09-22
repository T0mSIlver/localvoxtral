import Observation
import XCTest
@testable import localvoxtral

/// Runs `trigger`, then returns once `value` has been written: how a test
/// waits for what another main-actor task does in response, with no seam and
/// no clock. Only wait for a write the code under test is certain to make. If
/// it never makes one, the test fails after `failAfter` seconds of wall time
/// instead of hanging the suite: a bound on a failure, never a wait a passing
/// test relies on.
@MainActor
func awaitNextWrite<Value>(
    of value: @escaping @MainActor () -> Value,
    failAfter: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line,
    after trigger: () -> Void
) async {
    let written = XCTestExpectation(description: "the watched value was written")
    withObservationTracking {
        _ = value()
    } onChange: {
        written.fulfill()
    }
    trigger()
    let result = await XCTWaiter().fulfillment(of: [written], timeout: failAfter)
    if result != .completed {
        XCTFail("the watched value was never written", file: file, line: line)
    }
}
