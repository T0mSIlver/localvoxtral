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

    /// Quit kills an agent run in flight, even one that ignores SIGTERM, and
    /// the run returns. Its own deadline is far off: only the owner ends it.
    func testQuitTerminatesARunningChildThatIgnoresSIGTERM() async throws {
        let (registered, continuation) = AsyncStream.makeStream(of: pid_t.self)
        let children = BoundedProcessChildren(onRegister: { continuation.yield($0) })
        async let output = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; exec sleep 600"],
            environment: ["PATH": "/usr/bin:/bin"],
            timeoutSeconds: Self.deadline,
            maxBytes: 1024,
            label: "test",
            children: children
        )
        var iterator = registered.makeAsyncIterator()
        let next = await iterator.next()
        let pid = try XCTUnwrap(next)

        children.terminateAll(grace: 0.2, within: 2)

        let finished = await output
        let result = try XCTUnwrap(finished, "the run abandoned the child")
        XCTAssertFalse(result.timedOut, "the deadline ended the run, not quit")
        XCTAssertNotEqual(kill(pid, 0), 0, "the child outlived quit")
    }

    /// A run that starts while the app quits does not outlive it.
    func testAChildLaunchedAfterQuitIsKilledAtOnce() async throws {
        let children = BoundedProcessChildren()
        children.terminateAll(grace: 0.2, within: 2)

        let result = await BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec sleep 600"],
            environment: ["PATH": "/usr/bin:/bin"],
            timeoutSeconds: Self.deadline,
            maxBytes: 1024,
            label: "test",
            children: children
        )

        XCTAssertFalse(try XCTUnwrap(result).timedOut, "the deadline ended the run, not quit")
    }

    /// Far enough off that only the owner can end a run first; near enough
    /// that a broken owner fails the test instead of hanging it.
    private static let deadline: TimeInterval = 10
}
