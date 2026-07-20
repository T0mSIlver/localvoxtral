import ClaudeContextWire
import Foundation
import XCTest
@testable import ClaudeHookPublisherCore

// MARK: - Publisher: enrichment and fail-open

final class ClaudeHookPublisherTests: XCTestCase {
    private func makeEnvironment(
        variables: [String: String] = ["HOME": "/Users/tester"],
        tty: String? = "/dev/ttys007"
    ) -> ClaudeHookPublisher.Environment {
        ClaudeHookPublisher.Environment(
            now: { 1_700_000_000 },
            pid: { 4242 },
            ppid: { 99 },
            ttyName: { tty },
            variables: variables
        )
    }

    private func publisher(
        variables: [String: String] = ["HOME": "/Users/tester"],
        tty: String? = "/dev/ttys007"
    ) -> ClaudeHookPublisher {
        ClaudeHookPublisher(environment: makeEnvironment(variables: variables, tty: tty))
    }

    // MARK: Enrichment — safe metadata only

    func testEnrichesWithProcessAndTTYMetadata() {
        let info = publisher(
            variables: ["HOME": "/Users/tester", "TERM_PROGRAM": "ghostty"]
        ).processInfo()
        XCTAssertEqual(info.hookPID, 4242)
        XCTAssertEqual(info.claudePID, 99, "the parent is Claude Code — the shim execs us")
        XCTAssertEqual(info.tty, "/dev/ttys007")
        XCTAssertEqual(info.termProgram, "ghostty")
    }

    func testAbsentTTYAndTermProgramAreNil() {
        let info = publisher(variables: ["HOME": "/h"], tty: nil).processInfo()
        XCTAssertNil(info.tty)
        XCTAssertNil(info.termProgram)
    }

    func testEmptyTermProgramIsTreatedAsAbsent() {
        let info = publisher(variables: ["HOME": "/h", "TERM_PROGRAM": ""]).processInfo()
        XCTAssertNil(info.termProgram)
    }

    // MARK: Fail-open

    func testUnparseableStdinIsDroppedNotPublished() {
        XCTAssertEqual(
            publisher().run(stdin: Data("garbage".utf8), fallbackEvent: "Stop"),
            .droppedUnparseable
        )
    }

    func testEmptyStdinIsDropped() {
        XCTAssertEqual(publisher().run(stdin: Data(), fallbackEvent: "Stop"), .droppedUnparseable)
    }

    func testUnknownEventIsDropped() {
        let json = #"{"hook_event_name":"PreCompact","session_id":"s1"}"#
        XCTAssertEqual(publisher().run(stdin: Data(json.utf8), fallbackEvent: nil), .droppedUnparseable)
    }

    func testMissingHomeAndOverrideYieldsNoSocketPath() {
        let json = #"{"hook_event_name":"Stop","session_id":"s1"}"#
        XCTAssertEqual(
            publisher(variables: [:]).run(stdin: Data(json.utf8), fallbackEvent: nil),
            .droppedNoSocketPath
        )
    }

    func testAbsentBrokerReportsTransportFailureRatherThanThrowing() {
        // The app-not-running case. `main` maps every outcome to exit 0.
        let json = #"{"hook_event_name":"Stop","session_id":"s1"}"#
        let outcome = ClaudeHookPublisher(
            environment: makeEnvironment(
                variables: [ClaudeHookSocketPath.environmentKey: "/tmp/definitely-not-a-socket-\(UUID().uuidString)"]
            )
        ).run(stdin: Data(json.utf8), fallbackEvent: nil)
        XCTAssertEqual(outcome, .droppedTransport(.notListening))
    }

    // MARK: stdout — every non-marker path must print nothing

    func testNoOutcomeOtherThanAMarkerEverPrintsAnything() {
        // The fail-open contract in one assertion. Claude Code appends a
        // UserPromptSubmit hook's non-JSON stdout to the user's prompt, so a
        // stray byte from any of these paths would land in their context.
        let outcomes: [ClaudeHookPublisher.Outcome] = [
            .published,
            .droppedUnparseable,
            .droppedNoSocketPath,
            .droppedTransport(.notListening),
            .droppedTransport(.timedOut),
            .droppedTransport(.writeFailed),
            .droppedTransport(.socketPathTooLong),
        ]
        for outcome in outcomes {
            XCTAssertNil(outcome.stdout, "\(outcome) must print nothing")
        }
    }

    func testMarkerOutcomePrintsValidHookJSON() throws {
        let data = try XCTUnwrap(ClaudeHookPublisher.Outcome.publishedWithMarker("lvx-abcd1234").stdout)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["suppressOutput"] as? Bool, true)
        XCTAssertEqual(object["terminalSequence"] as? String, "\u{1B}]2;lvx-abcd1234\u{07}")
    }

    func testMarkerOutcomeWithAnUnsafeMarkerPrintsNothing() {
        // Defence in depth: the broker mints markers, but if a malformed one
        // ever reached here it must not become terminal bytes.
        XCTAssertNil(ClaudeHookPublisher.Outcome.publishedWithMarker("lvx-\u{1B}]0;x\u{07}").stdout)
    }

    func testUnreachableBrokerPrintsNothing() {
        // Fail-open end to end: no broker, no marker, no output, no error.
        let json = #"{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/repo"}"#
        let outcome = ClaudeHookPublisher(
            environment: makeEnvironment(
                variables: [ClaudeHookSocketPath.environmentKey: "/tmp/absent-\(UUID().uuidString).sock"]
            )
        ).run(stdin: Data(json.utf8), fallbackEvent: nil)
        XCTAssertNil(outcome.stdout)
    }

    func testOverlongSocketPathFailsClosedNotCrashed() {
        let json = #"{"hook_event_name":"Stop","session_id":"s1"}"#
        let outcome = ClaudeHookPublisher(
            environment: makeEnvironment(
                variables: [ClaudeHookSocketPath.environmentKey: "/tmp/" + String(repeating: "x", count: 300)]
            )
        ).run(stdin: Data(json.utf8), fallbackEvent: nil)
        XCTAssertEqual(outcome, .droppedTransport(.socketPathTooLong))
    }
}

// MARK: - Socket path resolution

final class ClaudeHookSocketPathTests: XCTestCase {
    func testEnvironmentOverrideWins() {
        let path = ClaudeHookSocketPath.resolve(environment: [
            "HOME": "/Users/tester",
            ClaudeHookSocketPath.environmentKey: "/tmp/custom.sock",
        ])
        XCTAssertEqual(path, "/tmp/custom.sock")
    }

    func testEmptyOverrideFallsBackToDefault() {
        let path = ClaudeHookSocketPath.resolve(environment: [
            "HOME": "/Users/tester",
            ClaudeHookSocketPath.environmentKey: "",
        ])
        XCTAssertNotEqual(path, "")
        XCTAssertEqual(path?.hasSuffix("claude-context.sock"), true)
    }

    func testNoHomeYieldsNoPath() {
        XCTAssertNil(ClaudeHookSocketPath.resolve(environment: [:]))
    }

    #if canImport(Darwin)
    func testDefaultPathIsUnderApplicationSupport() {
        let path = ClaudeHookSocketPath.resolve(environment: ["HOME": "/Users/tester"])
        XCTAssertEqual(
            path,
            "/Users/tester/Library/Application Support/localvoxtral/run/claude-context.sock"
        )
    }

    func testDefaultPathFitsInSockaddrUn() throws {
        // sun_path is 104 bytes on Darwin. A realistic long username must not
        // silently push the default path past it.
        let home = "/Users/" + String(repeating: "u", count: 20)
        let path = try XCTUnwrap(ClaudeHookSocketPath.resolve(environment: ["HOME": home]))
        XCTAssertLessThan(path.utf8.count, 104)
    }
    #endif
}

// MARK: - Controlling TTY capture

final class ClaudeHookControllingTTYTests: XCTestCase {
    // Claude Code wires all three hook fds to pipes, so the field capture
    // depends on the /dev/tty and process-table fallbacks — these pin the
    // process-table read's refusal cases deterministically (a positive read
    // needs a controlling terminal, which CI runners don't have; the live
    // proof is the hand-tested join).
    func testProcessTableLookupRefusesInvalidPIDs() {
        XCTAssertNil(ClaudeHookPublisher.ttyDevicePath(forProcess: 0))
        XCTAssertNil(ClaudeHookPublisher.ttyDevicePath(forProcess: -1))
    }

    func testProcessTableLookupAnswersNilForATerminallessProcess() {
        // launchd (pid 1) exists on every macOS system and never has a
        // controlling terminal — a real process-table read that must answer
        // "no device", not garbage.
        XCTAssertNil(ClaudeHookPublisher.ttyDevicePath(forProcess: 1))
    }

    func testProcessTableLookupAnswersNilForADeadPID() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? process.run()
        process.waitUntilExit()
        XCTAssertNil(ClaudeHookPublisher.ttyDevicePath(forProcess: process.processIdentifier))
    }

    func testControllingTTYAgreesWithItsOwnProcessTableEntry() {
        // Environment-independent invariant: whether this suite runs on a
        // pty-attached dev shell (fds are the terminal), piped output (only
        // /dev/tty answers), or a terminal-less CI runner (nothing answers),
        // the capture chain and the process-table read of OUR OWN pid describe
        // the same session — same device, or nil on both sides.
        XCTAssertEqual(
            ClaudeHookPublisher.controllingTTY(claudePID: getpid()),
            ClaudeHookPublisher.ttyDevicePath(forProcess: getpid())
        )
    }
}

// MARK: - Timeout plumbing

final class UnixSocketPublisherTimeoutTests: XCTestCase {
    func testFractionalTimeoutBecomesMicroseconds() {
        XCTAssertEqual(UnixSocketPublisher.microsecondsRemainder(0.25), 250_000)
        XCTAssertEqual(UnixSocketPublisher.microsecondsRemainder(1.5), 500_000)
        XCTAssertEqual(UnixSocketPublisher.microsecondsRemainder(2.0), 0)
    }

    func testDefaultTimeoutIsShortEnoughForAnInlineHook() {
        // This runs inline in a Claude Code hook: being late is worse than
        // being absent.
        XCTAssertLessThanOrEqual(UnixSocketPublisher().timeout, 0.5)
    }
}
