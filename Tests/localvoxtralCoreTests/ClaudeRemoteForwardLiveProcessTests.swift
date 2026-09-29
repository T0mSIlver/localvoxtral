import Foundation
import XCTest
@testable import localvoxtralCore

final class ClaudeRemoteForwardLiveProcessTests: XCTestCase {
    /// The supervisor matches ssh's stderr against an English line (#1011),
    /// so the child runs in the C locale whatever the app's locale is. A
    /// shell stands in for ssh and reports the locale it was given.
    func testChildRunsInTheCLocale() async throws {
        let process = try ClaudeRemoteForwardLiveProcess(
            argv: ["ssh", "-c", "echo \"LC_ALL=$LC_ALL\" >&2"],
            sshExecutableURL: URL(fileURLWithPath: "/bin/sh")
        )
        var lines: [String] = []
        for await line in process.standardErrorLines { lines.append(line) }
        _ = await process.waitUntilExit()
        XCTAssertEqual(lines, ["LC_ALL=C"])
    }
}
