import Foundation
import XCTest
import localvoxtralTestSupport

/// The eval runs `say` through this wrapper, as a launchd job when
/// `LV_EVAL_SAY_VIA_LAUNCHD=1` (#960). The launchd path itself needs a GUI
/// login session, which the Mac build gate's account lacks by design
/// (`launchctl submit` aborts there), so eval-e2e is what runs it.
final class EvalChildProcessTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-child-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// The script a launchd job runs, run here by `/bin/sh`: quoting survives
    /// an apostrophe and a space, stdout lands in the file, the status marker
    /// holds the exit code, and a rerun (launchd restarts `submit` jobs) is a
    /// no-op.
    func testJobScriptWritesOutputThenStatusAndSkipsARerun() throws {
        let directory = try temporaryDirectory()
        let files = EvalChildProcess.JobFiles(directory: directory)
        let output = directory.appendingPathComponent("out put.txt")
        let script = EvalChildProcess.jobScript(
            executable: "/bin/sh",
            arguments: ["-c", #"printf '%s|%s' "$1" "$2"; exit 4"#, "sh", "l'heure", "a  b"],
            standardOutput: output.path, files: files
        )

        XCTAssertEqual(try EvalChildProcess.run("/bin/sh", arguments: ["-c", script], viaLaunchd: false), 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "l'heure|a  b")
        XCTAssertEqual(try String(contentsOf: files.status, encoding: .utf8), "4\n")

        try FileManager.default.removeItem(at: output)
        XCTAssertEqual(try EvalChildProcess.run("/bin/sh", arguments: ["-c", script], viaLaunchd: false), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSubmitArgumentsRunTheScriptUnderShUnderTheLabel() {
        XCTAssertEqual(
            EvalChildProcess.submitArguments(label: "com.example.job", script: "true"),
            ["submit", "-l", "com.example.job", "--", "/bin/sh", "-c", "true"]
        )
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
            standardOutput: output.path, discardStandardError: true, viaLaunchd: false
        )
        XCTAssertEqual(status, 3)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "hello\n")
    }
}
