import ClaudeContextWire
import Foundation
import XCTest

/// The built `localvoxtral` command with its stdout or stderr closed or
/// broken (#1165). `FileHandle.write` raises an uncatchable exception on such
/// a descriptor and the command aborted instead of returning its status.
final class AgentCLIClosedOutputTests: XCTestCase {
    /// The command's binary, built next to this test bundle: `swift test`
    /// builds every product, and `scripts/core-tests-linux.sh` builds it by
    /// name.
    private func commandBinary() throws -> String {
        #if canImport(Darwin)
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        #else
        let products = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        #endif
        let binary = products.appendingPathComponent("localvoxtral-cli").path
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw NSError(domain: "AgentCLIClosedOutputTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no localvoxtral-cli next to the tests at \(binary); build the product first",
            ])
        }
        return binary
    }

    /// Runs `script` under /bin/sh with the binary as `$0`, and returns how
    /// it ended. A signal ends it with `.uncaughtSignal`, which every
    /// assertion below refuses.
    private func runCommand(
        _ script: String,
        environment: [String: String] = [:],
        standardOutput: Any? = nil
    ) throws -> (reason: Process.TerminationReason, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, try commandBinary()]
        // A socket no app listens on, so a request finds localvoxtral not
        // running wherever the test runs.
        process.environment = environment.merging([
            "HOME": NSTemporaryDirectory(),
            ClaudeHookSocketPath.environmentKey: NSTemporaryDirectory() + "lv-closed-output-\(UUID().uuidString).sock",
        ]) { mine, _ in mine }
        process.standardInput = FileHandle.nullDevice
        if let standardOutput { process.standardOutput = standardOutput }
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return (process.terminationReason, process.terminationStatus)
    }

    func testHelpWithStdoutClosedExitsZero() async throws {
        let ended = try runCommand(#"exec "$0" --help 1>&-"#)
        XCTAssertEqual(ended.reason, .exit, "ended by signal \(ended.status)")
        XCTAssertEqual(ended.status, 0)
    }

    func testUsageErrorWithStderrClosedExitsWithTheUsageStatus() async throws {
        let ended = try runCommand(#"exec "$0" --no-such-flag 2>&-"#)
        XCTAssertEqual(ended.reason, .exit, "ended by signal \(ended.status)")
        XCTAssertEqual(ended.status, 2)
    }

    /// The documented status for a request with no app to answer it, with
    /// both outputs closed.
    func testStatusWithBothOutputsClosedExitsNotRunning() async throws {
        let ended = try runCommand(#"exec "$0" status 1>&- 2>&-"#)
        XCTAssertEqual(ended.reason, .exit, "ended by signal \(ended.status)")
        XCTAssertEqual(ended.status, 3)
    }

    /// A reader that has gone, with SIGPIPE ignored as a caller may leave it:
    /// the write fails with EPIPE and the command still exits with its status.
    func testHelpIntoAPipeWithNoReaderExitsZero() async throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        let ended = try runCommand(#"trap '' PIPE; exec "$0" --help"#, standardOutput: pipe)
        XCTAssertEqual(ended.reason, .exit, "ended by signal \(ended.status)")
        XCTAssertEqual(ended.status, 0)
    }
}
