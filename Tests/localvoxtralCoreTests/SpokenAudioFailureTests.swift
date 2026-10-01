import Foundation
import XCTest
import localvoxtralTestSupport

/// A live lane that cannot make its spoken audio must go red, not skip: a
/// filtered `swift test` whose tests all skip exits 0, so the lane would pass
/// with nothing measured (#1196).
final class SpokenAudioFailureTests: XCTestCase {
    func testAFailingTTSFailsInsteadOfSkipping() {
        assertFailsWithoutSkipping(say: URL(fileURLWithPath: "/usr/bin/false"))
    }

    func testAMissingTTSFailsInsteadOfSkipping() {
        assertFailsWithoutSkipping(
            say: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/say"))
    }

    private func assertFailsWithoutSkipping(
        say: URL, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try IntegrationTestSupport.makeSpokenPCM16Data(phrase: "hello", say: say),
            file: file, line: line
        ) { error in
            XCTAssertTrue(error is SpokenAudioFailure, "got \(type(of: error))", file: file, line: line)
        }
    }
}
