#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest

@testable import localvoxtralCore

final class BoundedProcessTests: XCTestCase {
    /// A headless agent that overflows the output cap and ignores SIGTERM is
    /// killed, and the caller gets the capped output instead of a launch
    /// failure with the child still running.
    func testOutputCapKillsAChildThatIgnoresSIGTERM() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        // An ignored signal stays ignored across exec, so the sleep keeps the
        // shell's pid and its deafness to SIGTERM. The overflow fits in the
        // pipe buffer, so nothing is left blocked writing.
        let script = """
            trap '' TERM
            echo $$ > '\(pidFile.path)'
            head -c 2048 /dev/zero
            exec sleep 600
            """

        let output = await BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"],
            timeoutSeconds: 600,
            maxBytes: 1024,
            label: "test"
        )

        let pid = try XCTUnwrap(
            Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let alive = kill(pid, 0) == 0
        if alive { kill(pid, SIGKILL) }
        XCTAssertFalse(alive, "the child outlived the run")
        let capped = try XCTUnwrap(output, "the run abandoned the child")
        XCTAssertTrue(capped.capped)
        XCTAssertFalse(capped.timedOut)
    }
}
