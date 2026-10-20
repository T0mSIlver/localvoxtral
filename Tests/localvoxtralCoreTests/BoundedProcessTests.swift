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

    // MARK: The synchronous engine

    /// A child that prints, then hangs silently, is stopped at the deadline,
    /// and the caller still gets what it printed: the ssh runner reports it.
    func testTheDeadlineStopsASilentChildAndKeepsItsPartialOutput() throws {
        let output = try BoundedProcess.runSynchronously(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo partial; exec sleep 30"],
            environment: ["PATH": "/usr/bin:/bin"],
            timeoutSeconds: 0.2,
            maxBytes: 1024,
            label: "test"
        )
        XCTAssertTrue(output.timedOut)
        XCTAssertFalse(output.capped)
        XCTAssertTrue(output.reaped)
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "partial\n")
    }

    /// Output exactly at the cap is complete; one byte past it is an overrun.
    func testTheCapAllowsMaxBytesAndStopsAtOneMore() throws {
        func run(_ bytes: Int) throws -> BoundedProcess.Output {
            try BoundedProcess.runSynchronously(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c \(bytes) /dev/zero"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeoutSeconds: Self.deadline,
                maxBytes: 1024,
                label: "test"
            )
        }
        let atCap = try run(1024)
        XCTAssertFalse(atCap.capped)
        XCTAssertEqual(atCap.exitCode, 0)
        XCTAssertEqual(atCap.data.count, 1024)
        let past = try run(1025)
        XCTAssertTrue(past.capped)
        XCTAssertFalse(past.timedOut)
    }

    /// Stderr is discarded unless the caller merges it into the output.
    func testStandardErrorJoinsTheOutputOnlyWhenMerged() throws {
        func run(merging: Bool) throws -> String {
            let output = try BoundedProcess.runSynchronously(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo out; echo err >&2"],
                environment: ["PATH": "/usr/bin:/bin"],
                mergingStandardError: merging,
                timeoutSeconds: Self.deadline,
                maxBytes: 1024,
                label: "test"
            )
            return String(decoding: output.data, as: UTF8.self)
        }
        XCTAssertEqual(try run(merging: false), "out\n")
        XCTAssertEqual(try run(merging: true), "out\nerr\n")
    }

    /// Stdin within the preload size and stdin past it (the writer thread)
    /// both reach the child whole.
    func testStandardInputReachesTheChildOnBothSidesOfThePreloadSize() throws {
        for size in [100, BoundedProcess.standardInputPreloadBytes, 4 * BoundedProcess.standardInputPreloadBytes] {
            let input = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 % 251) })
            let output = try BoundedProcess.runSynchronously(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"],
                standardInput: .bytes(input),
                timeoutSeconds: Self.deadline,
                maxBytes: 1 << 20,
                label: "test"
            )
            XCTAssertEqual(output.exitCode, 0, "\(size) bytes")
            XCTAssertEqual(output.data, input, "\(size) bytes")
        }
    }

    #if canImport(Darwin)
    /// A child that exits without reading a large stdin turns the writer's
    /// next write into EPIPE, never a SIGPIPE that would kill the app.
    func testAChildThatClosesItsStdinEarlyDoesNotRaiseSIGPIPE() throws {
        let output = try BoundedProcess.runSynchronously(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 0<&-; echo gone"],
            environment: ["PATH": "/usr/bin:/bin"],
            standardInput: .bytes(Data(count: 1 << 20)),
            timeoutSeconds: Self.deadline,
            maxBytes: 1024,
            label: "test"
        )
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "gone\n")
    }
    #endif

    func testALaunchFailureThrows() {
        XCTAssertThrowsError(try BoundedProcess.runSynchronously(
            executableURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"),
            arguments: [],
            environment: [:],
            timeoutSeconds: Self.deadline,
            maxBytes: 1024,
            label: "test"
        ))
    }

    // MARK: Bounded teardown
    //
    // Every seam is injected, so these prove the escalation ordering without a
    // process and without a clock: no signals are sent, no time passes.

    /// Records the teardown steps in the order they were taken.
    private func recordTeardown(
        gracePeriod: TimeInterval = 2,
        exitsAfterWait: Int?
    ) -> (outcome: BoundedProcess.TerminationOutcome, steps: [String], windows: [TimeInterval]) {
        var steps: [String] = []
        var windows: [TimeInterval] = []
        var waits = 0
        let outcome = BoundedProcess.terminateBounded(
            gracePeriod: gracePeriod,
            terminate: { steps.append("terminate") },
            kill: { steps.append("kill") },
            waitForExit: { window in
                waits += 1
                steps.append("wait")
                windows.append(window)
                return waits == exitsAfterWait
            }
        )
        return (outcome, steps, windows)
    }

    func testTeardownStopsAtSIGTERMWhenTheChildHonoursIt() {
        // A well-behaved CLI must never be killed: SIGTERM lets it clean up.
        let run = recordTeardown(exitsAfterWait: 1)
        XCTAssertEqual(run.outcome, .exitedOnTerminate)
        XCTAssertEqual(run.steps, ["terminate", "wait"])
        XCTAssertFalse(run.steps.contains("kill"))
    }

    func testTeardownEscalatesToSIGKILLWhenSIGTERMIsIgnored() {
        // The regression this guards: SIGTERM is advisory, so the wait after it
        // is a grace period. Waiting on a TERM-ignoring child forever is how the
        // runner used to wedge the app.
        let run = recordTeardown(gracePeriod: 0.25, exitsAfterWait: 2)
        XCTAssertEqual(run.outcome, .killed)
        XCTAssertEqual(run.steps, ["terminate", "wait", "kill", "wait"])
        XCTAssertEqual(run.windows, [0.25, 0.25], "both waits are bounded by the grace period")
    }

    func testTeardownGivesUpRatherThanWaitingForeverOnAChildThatSurvivesSIGKILL() {
        // Uninterruptible sleep. Nothing we can send helps, so the one thing
        // that must not happen is blocking the caller indefinitely.
        let run = recordTeardown(exitsAfterWait: nil)
        XCTAssertEqual(run.outcome, .abandonedAfterKill)
        XCTAssertEqual(run.steps, ["terminate", "wait", "kill", "wait"], "exactly two bounded waits, then return")
    }

    /// Far enough off that only the owner can end a run first; near enough
    /// that a broken owner fails the test instead of hanging it.
    private static let deadline: TimeInterval = 10
}
