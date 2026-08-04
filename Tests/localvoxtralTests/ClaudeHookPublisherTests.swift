import ClaudeContextWire
import Darwin
import Foundation
import Synchronization
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
            ttyName: { _ in tty },
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

    func testHerdrEnvironmentValuesArePublished() {
        let info = publisher(variables: [
            "HOME": "/h",
            "HERDR_PANE_ID": "pane-7",
            "HERDR_SOCKET_PATH": "/tmp/herdr.sock",
        ]).processInfo()
        XCTAssertEqual(info.herdrPaneID, "pane-7")
        XCTAssertEqual(info.herdrSocketPath, "/tmp/herdr.sock")
    }

    func testHerdrEnvironmentValuesArePublishedIndependently() {
        let paneOnly = publisher(variables: ["HERDR_PANE_ID": "pane-7"]).processInfo()
        XCTAssertEqual(paneOnly.herdrPaneID, "pane-7")
        XCTAssertNil(paneOnly.herdrSocketPath)

        let socketOnly = publisher(
            variables: ["HERDR_SOCKET_PATH": "/tmp/herdr.sock"]
        ).processInfo()
        XCTAssertNil(socketOnly.herdrPaneID)
        XCTAssertEqual(socketOnly.herdrSocketPath, "/tmp/herdr.sock")
    }

    func testEmptyHerdrEnvironmentValuesAreTreatedAsAbsent() {
        let info = publisher(variables: [
            "HERDR_PANE_ID": "",
            "HERDR_SOCKET_PATH": "",
        ]).processInfo()
        XCTAssertNil(info.herdrPaneID)
        XCTAssertNil(info.herdrSocketPath)
    }

    func testAbsentHerdrEnvironmentValuesAreNil() {
        let info = publisher(variables: ["HOME": "/h"]).processInfo()
        XCTAssertNil(info.herdrPaneID)
        XCTAssertNil(info.herdrSocketPath)
    }

    func testCmuxAndBridgeEnvironmentValuesArePublished() {
        // Same class as the herdr pair and the same reason: they name WHERE a
        // LOCAL session runs, which is the only question a join arm asks. Their
        // trust is the AF_UNIX peer-UID check, so they may sit in `process`
        // beside the rest — the remote equivalents deliberately may not.
        let info = publisher(variables: [
            "HOME": "/h",
            "CMUX_SURFACE_ID": "surface-3",
            "CMUX_SOCKET_PATH": "/tmp/cmux.sock",
            "CLAUDE_CODE_BRIDGE_SESSION_ID": "bridge-abc",
        ]).processInfo()
        XCTAssertEqual(info.cmuxSurfaceID, "surface-3")
        XCTAssertEqual(info.cmuxSocketPath, "/tmp/cmux.sock")
        XCTAssertEqual(info.bridgeSessionID, "bridge-abc")
    }

    func testCmuxAndBridgeEnvironmentValuesArePublishedIndependently() {
        let surfaceOnly = publisher(variables: ["CMUX_SURFACE_ID": "surface-3"]).processInfo()
        XCTAssertEqual(surfaceOnly.cmuxSurfaceID, "surface-3")
        XCTAssertNil(surfaceOnly.cmuxSocketPath)
        XCTAssertNil(surfaceOnly.bridgeSessionID)

        let bridgeOnly = publisher(
            variables: ["CLAUDE_CODE_BRIDGE_SESSION_ID": "bridge-abc"]
        ).processInfo()
        XCTAssertEqual(bridgeOnly.bridgeSessionID, "bridge-abc")
        XCTAssertNil(bridgeOnly.cmuxSurfaceID)
    }

    func testEmptyOrAbsentCmuxAndBridgeValuesAreTreatedAsAbsent() {
        // An exported-but-empty variable is how a shell says "not in one of
        // these". Publishing `""` would let a later join arm match two empty
        // strings and call it the same surface.
        let empty = publisher(variables: [
            "CMUX_SURFACE_ID": "",
            "CMUX_SOCKET_PATH": "",
            "CLAUDE_CODE_BRIDGE_SESSION_ID": "",
        ]).processInfo()
        XCTAssertNil(empty.cmuxSurfaceID)
        XCTAssertNil(empty.cmuxSocketPath)
        XCTAssertNil(empty.bridgeSessionID)

        let absent = publisher(variables: ["HOME": "/h"]).processInfo()
        XCTAssertNil(absent.cmuxSurfaceID)
        XCTAssertNil(absent.cmuxSocketPath)
        XCTAssertNil(absent.bridgeSessionID)
    }

    func testNoEnvironmentVariableOutsideTheAllowlistIsEverPublished() throws {
        // The publisher reads the environment, so "it only takes the allowlist"
        // is a property worth asserting against the ENCODED line rather than
        // field by field: a secret picked up by a future edit would show up
        // here as a value on the wire.
        let info = publisher(variables: [
            "HOME": "/h",
            "AWS_SECRET_ACCESS_KEY": "super-secret",
            "GITHUB_TOKEN": "ghp_secret",
            "PATH": "/usr/bin",
            "TERM_PROGRAM": "ghostty",
        ]).processInfo()
        let encoded = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        for secret in ["super-secret", "ghp_secret", "/usr/bin"] {
            XCTAssertFalse(encoded.contains(secret), "\(secret) must never be published")
        }
        XCTAssertTrue(encoded.contains("ghostty"))
    }

    // The published claudePID and the tty resolution consume the SAME pid,
    // from one `ppid()` call: the tty seam receives the pid the ppid seam
    // yielded, so the two fields can never describe different processes (the
    // old default re-resolved `claudeAncestorPID()` inside the tty closure,
    // which let an injected ppid and the published tty silently diverge).
    func testTTYResolutionConsumesTheSamePIDTheEnvironmentPublishes() {
        let receivedPIDs = Mutex<[Int32]>([])
        let environment = ClaudeHookPublisher.Environment(
            now: { 1_700_000_000 },
            pid: { 4242 },
            ppid: { 31_337 },
            ttyName: { pid in
                receivedPIDs.withLock { $0.append(pid) }
                return "/dev/ttys009"
            },
            variables: ["HOME": "/h"]
        )
        let info = ClaudeHookPublisher(environment: environment).processInfo()
        XCTAssertEqual(info.claudePID, 31_337)
        XCTAssertEqual(
            receivedPIDs.withLock { $0 }, [31_337], "one ppid resolution feeds both fields"
        )
        XCTAssertEqual(info.tty, "/dev/ttys009")
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
    // process-table read's refusal cases deterministically, and the pty test
    // below covers the positive path (as an invariant that tolerates a
    // sandbox refusing the acquisition; the live end-to-end proof remains the
    // hand-tested Ghostty join).
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

    // The positive half: a child spawned into its own session with a pty we
    // allocated as fd 0 acquires that pty as its controlling terminal, and the
    // process-table read must name exactly that device. Structured as a
    // refusal-vs-agreement invariant rather than a hard positive: a sandbox
    // that denies pty allocation or controlling-terminal acquisition yields
    // nil (a refusal, same as launchd's), and that is tolerated — but a
    // NON-nil answer naming any device other than our pty is a lie and fails.
    func testPTYAttachedChildProcessTableReadNamesThatPTYOrRefuses() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var nameBuffer = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &nameBuffer, nil, nil) == 0 else {
            // No pty allocatable in this sandbox: there is no positive
            // evidence to check and no device to be wrong about. The refusal
            // cases stay covered by the sibling tests above.
            return
        }
        let slavePath = String(cString: nameBuffer)
        defer {
            close(master)
            close(slave)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Opened IN THE CHILD, after it became a session leader: the first
        // tty a session leader opens without O_NOCTTY becomes its controlling
        // terminal — the exact chain a real terminal emulator sets up.
        slavePath.withCString {
            _ = posix_spawn_file_actions_addopen(&actions, 0, $0, O_RDWR, 0)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // POSIX_SPAWN_SETSID (spawn.h): the child starts its own session, so
        // it CAN acquire a controlling terminal of its own.
        posix_spawnattr_setflags(&attributes, Int16(0x0400))

        var childPID: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        guard posix_spawn(&childPID, "/bin/sleep", &actions, &attributes, argv, nil) == 0 else {
            return // Same tolerance as openpty: nothing spawned, nothing to lie.
        }
        defer {
            kill(childPID, SIGKILL)
            var status: Int32 = 0
            waitpid(childPID, &status, 0)
        }

        // posix_spawn is one syscall on Darwin: the file actions (and with
        // them the controlling-terminal acquisition) completed before it
        // returned, so no polling is needed.
        if let reported = ClaudeHookPublisher.ttyDevicePath(forProcess: childPID) {
            XCTAssertEqual(
                reported, slavePath,
                "a positive process-table answer must name the pty we allocated, never another device"
            )
        }
        // nil is the tolerated refusal (sandbox denied the acquisition) —
        // deliberate: absence must stay deterministic here, and the live
        // positive proof remains the hand-tested Ghostty join.
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

    func testStdinReadConsultsAbsoluteDeadlineWhilePipeStaysOpenWithoutData() {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let flags = fcntl(descriptors[0], F_GETFL, 0)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK), 0)

        let calls = Mutex(0)
        let base: UInt64 = 1_000_000_000
        let data = ClaudeHookPublisher.readBoundedStdin(
            descriptor: descriptors[0],
            timeout: 0.25,
            uptimeNanos: {
                calls.withLock { count in
                    count += 1
                    return count == 1 ? base : base + 1_000_000_000
                }
            }
        )

        XCTAssertTrue(data.isEmpty)
        XCTAssertGreaterThanOrEqual(
            calls.withLock { $0 },
            2,
            "the reader must re-check its monotonic deadline instead of entering an unbounded read"
        )
    }
}
