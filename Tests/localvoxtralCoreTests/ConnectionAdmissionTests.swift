import XCTest
@testable import localvoxtralCore

final class ConnectionAdmissionTests: XCTestCase {
    /// A full listener logs the first refusal of a spell, stays quiet through
    /// the flood, and reports the count on the next admission.
    func testAFullSpellLogsItsFirstRefusalAndItsCount() {
        var admission = ConnectionAdmission()
        XCTAssertEqual(admission.admit(limit: 1), .admitted(refusedWhileFull: 0))
        XCTAssertEqual(admission.admit(limit: 1), .refused(first: true))
        XCTAssertEqual(admission.admit(limit: 1), .refused(first: false))
        XCTAssertEqual(admission.admit(limit: 1), .refused(first: false))

        admission.release()
        XCTAssertEqual(admission.admit(limit: 1), .admitted(refusedWhileFull: 3))

        admission.release()
        XCTAssertEqual(admission.admit(limit: 1), .admitted(refusedWhileFull: 0))
        XCTAssertEqual(admission.admit(limit: 1), .refused(first: true))
    }
}
