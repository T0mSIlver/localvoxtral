import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore

/// The `gh` and `git` runs that gather a draft's context (#1692): a failed
/// one leaves its part out and says so in the log, without its search words
/// or output.
final class QuickCaptureContextRunTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("qc-context-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func tool(_ name: String, exitCode: Int32) throws {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\necho 'secret output'\nexit \(exitCode)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func testAFailedCommandIsLoggedWithoutItsWordsAndGitGrepFindingNothingIsNot() async throws {
        try tool("gh", exitCode: 4)
        try tool("git", exitCode: 1)
        let logged = Mutex<[String]>([])
        let directory = directory.path
        let run = QuickCaptureContextGatherer.processRun(
            environment: ["PATH": directory],
            isExecutable: { $0.hasPrefix(directory) && FileManager.default.isExecutableFile(atPath: $0) },
            logFailure: { line in logged.withLock { $0.append(line) } }
        )

        let issues = await run(.gh, ["issue", "list", "--search", "secretword"], directory)
        let hits = await run(.git, ["grep", "-n", "secretword"], directory)

        XCTAssertNil(issues)
        XCTAssertNotNil(hits, "git grep exits 1 when nothing matched")
        XCTAssertEqual(logged.withLock { $0 }, ["Quick capture context: `gh issue` exited 4; that context is left out"])
    }

    func testAMissingToolIsLogged() async throws {
        let logged = Mutex<[String]>([])
        let run = QuickCaptureContextGatherer.processRun(
            environment: ["PATH": directory.path],
            isExecutable: { _ in false },
            logFailure: { line in logged.withLock { $0.append(line) } }
        )

        let merged = await run(.gh, ["pr", "list", "--search", "secretword"], directory.path)

        XCTAssertNil(merged)
        XCTAssertEqual(logged.withLock { $0 }, ["Quick capture context: `gh pr` not run, gh not found; that context is left out"])
    }
}
