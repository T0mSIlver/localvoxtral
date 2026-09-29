import Foundation
import XCTest
import localvoxtralTestSupport

/// The eval runs `say` through this wrapper and logs its environment (#960).
final class EvalChildProcessTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-child-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testEnvironmentReportListsKeysAndMasksHomeAndUser() {
        let report = EvalChildProcess.environmentReport(
            [
                "HOME": "/Users/alice", "TMPDIR": "/var/folders/x/T/", "PATH": "/usr/bin",
                "SECRET_TOKEN": "hunter2", "XPC_SERVICE_NAME": "0",
                "__CFBundleIdentifier": "com.example", "DYLD_LIBRARY_PATH": "/Users/alice/lib:/opt/alice",
            ],
            home: "/Users/alice", user: "alice"
        )
        XCTAssertEqual(
            report,
            [
                "keys: DYLD_LIBRARY_PATH HOME PATH SECRET_TOKEN TMPDIR XPC_SERVICE_NAME __CFBundleIdentifier",
                "DYLD_LIBRARY_PATH=<home>/lib:/opt/<user>",
                "HOME=<home>",
                "TMPDIR=/var/folders/x/T/",
                "XPC_SERVICE_NAME=0",
                "__CFBundleIdentifier=com.example",
            ]
        )
    }

    func testDirectRunWritesStandardOutputAndReportsStatus() throws {
        let output = try temporaryDirectory().appendingPathComponent("out.txt")
        let status = try EvalChildProcess.run(
            "/bin/sh", arguments: ["-c", "echo hello; exit 3"],
            standardOutput: output.path, discardStandardError: true
        )
        XCTAssertEqual(status, 3)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "hello\n")
    }
}
