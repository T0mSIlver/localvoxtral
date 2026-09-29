import Foundation
import XCTest
import localvoxtralTestSupport

/// The eval spawns `say` through this wrapper (#960).
final class DisclaimedSpawnTests: XCTestCase {
    func testRunWritesStandardOutputToFileAndReportsStatus() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-disclaimed-spawn-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try DisclaimedSpawn.run(
            "/bin/echo", arguments: ["hello", "world"],
            standardOutput: output.path, discardStandardError: true
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "hello world\n")
        #if os(macOS)
        XCTAssertTrue(result.disclaimed, "libsystem lacks responsibility_spawnattrs_setdisclaim")
        #endif
    }

    func testRunReportsNonZeroExit() throws {
        let result = try DisclaimedSpawn.run("/bin/sh", arguments: ["-c", "exit 3"])
        XCTAssertEqual(result.status, 3)
    }
}
