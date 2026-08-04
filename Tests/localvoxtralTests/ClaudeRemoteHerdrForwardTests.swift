import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

#if canImport(Darwin)
import Darwin

/// `XCTUnwrap` takes an autoclosure, which cannot contain `await`. This
/// evaluates the value first and then unwraps it.
private func unwrapAsync<T>(
    _ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) throws -> T {
    try XCTUnwrap(value, message, file: file, line: line)
}

/// Test clock whose SLEEP is what advances it — the OverlayBufferSessionCoordinator
/// pattern (AGENTS: no wall clock in tests). A readiness poll driven by a real
/// clock would be a test that actually waits two seconds.
private final class ForwardTestClock: @unchecked Sendable {
    private let state = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
    let sleeps = Mutex<[TimeInterval]>([])

    var now: @Sendable () -> Date {
        { [self] in state.withLock { $0 } }
    }

    var sleepFor: @Sendable (TimeInterval) async -> Void {
        { [self] seconds in
            sleeps.withLock { $0.append(seconds) }
            state.withLock { $0 = $0.addingTimeInterval(seconds) }
        }
    }

    var sleepCount: Int { sleeps.withLock { $0.count } }
}

/// Counts injected `waitpid` calls across threads (the reap runs on whichever
/// thread called teardown).
private final class ReapCallCounter: @unchecked Sendable {
    private let count = Mutex(0)

    func next() -> Int {
        count.withLock { current in
            current += 1
            return current
        }
    }

    var value: Int { count.withLock { $0 } }
}

private final class ForwardTestProcess: ClaudeRemoteHerdrForwardProcess, @unchecked Sendable {
    private let running = Mutex(true)
    let terminations = Mutex(0)

    var isRunning: Bool { running.withLock { $0 } }
    func exit() { running.withLock { $0 = false } }

    func terminate() {
        terminations.withLock { $0 += 1 }
        running.withLock { $0 = false }
    }
}

private final class ForwardTestSpawner: ClaudeRemoteHerdrForwardSpawning, @unchecked Sendable {
    struct Failure: Error {}

    let argv = Mutex<[[String]]>([])
    let process = ForwardTestProcess()
    private let fails: Bool

    init(fails: Bool = false) { self.fails = fails }

    func spawn(argv: [String]) throws -> any ClaudeRemoteHerdrForwardProcess {
        self.argv.withLock { $0.append(argv) }
        if fails { throw Failure() }
        return process
    }

    var spawnCount: Int { argv.withLock { $0.count } }
}

private final class ForwardTestWorkspaces: ClaudeRemoteHerdrWorkspaceProviding, @unchecked Sendable {
    struct Failure: Error {}

    let made = Mutex(0)
    let removed = Mutex<[ClaudeRemoteHerdrForwardWorkspace]>([])
    private let socketPath: String
    private let fails: Bool

    init(socketPath: String = "/tmp/lvx-herdr-fwd-abcd1234/h.sock", fails: Bool = false) {
        self.socketPath = socketPath
        self.fails = fails
    }

    func makeWorkspace() throws -> ClaudeRemoteHerdrForwardWorkspace {
        if fails { throw Failure() }
        made.withLock { $0 += 1 }
        return ClaudeRemoteHerdrForwardWorkspace(
            directoryPath: (socketPath as NSString).deletingLastPathComponent,
            socketPath: socketPath
        )
    }

    func remove(_ workspace: ClaudeRemoteHerdrForwardWorkspace) {
        removed.withLock { $0.append(workspace) }
    }

    var removeCount: Int { removed.withLock { $0.count } }
}

/// The app-managed `ssh -L` to a remote herdr socket.
final class ClaudeRemoteHerdrForwardTests: XCTestCase {
    private let remoteSocketPath = "/run/user/1000/herdr/default.sock"
    private let localSocketPath = "/tmp/lvx-herdr-fwd-abcd1234/h.sock"

    private func service(
        spawner: ForwardTestSpawner,
        workspaces: ForwardTestWorkspaces,
        clock: ForwardTestClock,
        dialable: @escaping @Sendable (String) -> Bool
    ) -> ClaudeRemoteHerdrForwardService {
        ClaudeRemoteHerdrForwardService(
            spawner: spawner,
            workspaces: workspaces,
            isSocketDialable: dialable,
            now: clock.now,
            sleepFor: clock.sleepFor,
            readinessTimeout: 2.0,
            pollInterval: 0.025
        )
    }

    // MARK: - argv

    func testArgvIsExactlyWhatWeIntendToRun() {
        XCTAssertEqual(
            ClaudeRemoteHerdrForwardService.argv(
                alias: "builder",
                localSocketPath: localSocketPath,
                remoteSocketPath: remoteSocketPath
            ),
            [
                "ssh", "-N",
                "-o", "BatchMode=yes",
                "-o", "ControlPath=none",
                "-o", "ForkAfterAuthentication=no",
                "-o", "PermitLocalCommand=no",
                "-L", "\(localSocketPath):\(remoteSocketPath)",
                "--", "builder",
            ]
        )
    }

    func testArgvOverridesTheTwoAliasSettingsThatWouldBreakContainment() {
        // The connection inherits the alias's own `Host` block (review finding
        // 5): `ForkAfterAuthentication yes` would detach ssh into a process we
        // no longer track — an orphan per dictation — and `LocalCommand` would
        // run a command on THIS machine every time a tunnel opens.
        let argv = ClaudeRemoteHerdrForwardService.argv(
            alias: "builder", localSocketPath: localSocketPath, remoteSocketPath: remoteSocketPath
        )
        XCTAssertTrue(argv.contains("ForkAfterAuthentication=no"))
        XCTAssertTrue(argv.contains("PermitLocalCommand=no"))
    }

    func testArgvOmitsTheTwoOptionsThatWouldBreakTheForward() {
        // Both were in the original design and both were falsified against
        // OpenSSH 10.0 before this shipped:
        //   * ClearAllForwardings clears command-line forwardings too, so it
        //     would delete this very -L (measured: no socket ever appears);
        //   * ExitOnForwardFailure makes the enrolled host's own RemoteForward
        //     8473 — normally already held by the user's live session — fatal
        //     for this connection (measured: "Error: remote port forwarding
        //     failed", ssh exits).
        // Readiness is proven by dialing the socket instead.
        let argv = ClaudeRemoteHerdrForwardService.argv(
            alias: "builder", localSocketPath: localSocketPath, remoteSocketPath: remoteSocketPath
        )
        XCTAssertFalse(argv.contains { $0.contains("ClearAllForwardings") })
        XCTAssertFalse(argv.contains { $0.contains("ExitOnForwardFailure") })
    }

    // MARK: - Lifecycle

    func testOpenReturnsAHandleOnceTheSocketAnswers() async throws {
        let spawner = ForwardTestSpawner()
        let workspaces = ForwardTestWorkspaces()
        let clock = ForwardTestClock()
        let polls = Mutex(0)
        let service = service(
            spawner: spawner, workspaces: workspaces, clock: clock,
            dialable: { _ in polls.withLock { $0 += 1; return $0 >= 3 } }
        )

        let handle = try unwrapAsync(
            await service.open(alias: "builder", remoteSocketPath: remoteSocketPath)
        )

        XCTAssertEqual(handle.localSocketPath, localSocketPath)
        XCTAssertEqual(
            spawner.argv.withLock { $0 },
            [
                ClaudeRemoteHerdrForwardService.argv(
                    alias: "builder",
                    localSocketPath: localSocketPath,
                    remoteSocketPath: remoteSocketPath
                ),
            ]
        )
        // Still open: the dictation is what closes it.
        XCTAssertEqual(workspaces.removeCount, 0)
        XCTAssertTrue(handle.isRunning)
    }

    func testCloseTerminatesTheChildAndRemovesTheWorkspaceExactlyOnce() async throws {
        let spawner = ForwardTestSpawner()
        let workspaces = ForwardTestWorkspaces()
        let clock = ForwardTestClock()
        let service = service(
            spawner: spawner, workspaces: workspaces, clock: clock, dialable: { _ in true }
        )
        let handle = try unwrapAsync(
            await service.open(alias: "builder", remoteSocketPath: remoteSocketPath)
        )

        handle.close()
        handle.close()

        // `terminate()` is deliberately re-invoked by every close (it is the
        // retry path for a failed collection) and is idempotent in EFFECT, so
        // the contract is about what happened once: the workspace was removed
        // exactly once, and the child was terminated at all.
        XCTAssertGreaterThanOrEqual(spawner.process.terminations.withLock { $0 }, 1)
        XCTAssertEqual(workspaces.removed.withLock { $0.map(\.socketPath) }, [localSocketPath])
    }

    func testReadinessTimeoutTearsEverythingDown() async throws {
        let spawner = ForwardTestSpawner()
        let workspaces = ForwardTestWorkspaces()
        let clock = ForwardTestClock()
        let service = service(
            spawner: spawner, workspaces: workspaces, clock: clock, dialable: { _ in false }
        )

        let handle = await service.open(alias: "builder", remoteSocketPath: remoteSocketPath)

        XCTAssertNil(handle)
        XCTAssertGreaterThanOrEqual(spawner.process.terminations.withLock { $0 }, 1)
        XCTAssertEqual(workspaces.removeCount, 1)
        // Bounded: the poll loop cannot outlive the readiness budget. The count
        // is 2.0/0.025 give or take one — 0.025 is not exactly representable,
        // so eighty accumulated additions land just short of the deadline and
        // buy one more iteration. What matters is that it is bounded at all.
        XCTAssertEqual(clock.sleeps.withLock { $0.reduce(0, +) }, 2.0, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(clock.sleepCount, 80)
        XCTAssertLessThanOrEqual(clock.sleepCount, 82)
    }

    func testAnSSHThatExitsEarlyIsAbandonedWithoutWaitingOutTheTimeout() async throws {
        let spawner = ForwardTestSpawner()
        let workspaces = ForwardTestWorkspaces()
        let clock = ForwardTestClock()
        let polls = Mutex(0)
        let service = service(
            spawner: spawner, workspaces: workspaces, clock: clock,
            dialable: { [spawner] _ in
                let count = polls.withLock { $0 += 1; return $0 }
                if count == 2 { spawner.process.exit() }
                return false
            }
        )

        let handle = await service.open(alias: "builder", remoteSocketPath: remoteSocketPath)

        XCTAssertNil(handle)
        XCTAssertLessThan(clock.sleepCount, 5)
        XCTAssertEqual(workspaces.removeCount, 1)
    }

    func testSpawnFailureRemovesTheWorkspace() async throws {
        let spawner = ForwardTestSpawner(fails: true)
        let workspaces = ForwardTestWorkspaces()
        let clock = ForwardTestClock()
        let service = service(
            spawner: spawner, workspaces: workspaces, clock: clock, dialable: { _ in true }
        )

        let handle = await service.open(alias: "builder", remoteSocketPath: remoteSocketPath)
        XCTAssertNil(handle)
        XCTAssertEqual(workspaces.removeCount, 1)
        XCTAssertEqual(clock.sleepCount, 0)
    }

    func testAWorkspaceThatCannotBeCreatedNeverSpawns() async throws {
        let spawner = ForwardTestSpawner()
        let workspaces = ForwardTestWorkspaces(fails: true)
        let clock = ForwardTestClock()
        let service = service(
            spawner: spawner, workspaces: workspaces, clock: clock, dialable: { _ in true }
        )

        let handle = await service.open(alias: "builder", remoteSocketPath: remoteSocketPath)
        XCTAssertNil(handle)
        XCTAssertEqual(spawner.spawnCount, 0)
    }

    func testAnOverlongLocalSocketPathIsRefusedBeforeSpawning() async throws {
        // sun_path is 104 bytes; a socket nothing can dial is worth naming
        // rather than discovering as a readiness timeout.
        let spawner = ForwardTestSpawner()
        let workspaces = ForwardTestWorkspaces(
            socketPath: "/tmp/\(String(repeating: "d", count: 120))/h.sock"
        )
        let clock = ForwardTestClock()
        let service = service(
            spawner: spawner, workspaces: workspaces, clock: clock, dialable: { _ in true }
        )

        let handle = await service.open(alias: "builder", remoteSocketPath: remoteSocketPath)
        XCTAssertNil(handle)
        XCTAssertEqual(spawner.spawnCount, 0)
        XCTAssertEqual(workspaces.removeCount, 1)
    }

    // MARK: - Validation of the two strings that reach argv

    func testAnInvalidAliasNeverReachesArgv() async throws {
        let spawner = ForwardTestSpawner()
        let workspaces = ForwardTestWorkspaces()
        let clock = ForwardTestClock()
        let service = service(
            spawner: spawner, workspaces: workspaces, clock: clock, dialable: { _ in true }
        )

        for alias in ["-oProxyCommand=touch /tmp/pwned", "build er", "host;rm -rf /", ""] {
            let handle = await service.open(alias: alias, remoteSocketPath: remoteSocketPath)
            XCTAssertNil(handle, "alias \(alias) must be refused")
        }
        XCTAssertEqual(spawner.spawnCount, 0)
        XCTAssertEqual(workspaces.made.withLock { $0 }, 0)
    }

    func testAnUnusableRemoteSocketPathNeverReachesArgv() async throws {
        let spawner = ForwardTestSpawner()
        let workspaces = ForwardTestWorkspaces()
        let clock = ForwardTestClock()
        let service = service(
            spawner: spawner, workspaces: workspaces, clock: clock, dialable: { _ in true }
        )

        for path in [
            "relative/herdr.sock",
            "-oProxyCommand=x",
            "/run/herdr:1234",
            "/run/herdr sock",
            "/run/herdr\nsock",
            "",
        ] {
            let handle = await service.open(alias: "builder", remoteSocketPath: path)
            XCTAssertNil(handle, "remote socket path \(path) must be refused")
        }
        XCTAssertEqual(spawner.spawnCount, 0)
    }

    func testRemoteSocketPathValidationMatrix() {
        let valid = [
            "/run/user/1000/herdr/default.sock",
            "/tmp/herdr-user.sock",
            "/home/dev/.local/state/herdr/s-1.sock",
        ]
        for path in valid {
            XCTAssertTrue(
                ClaudeRemoteHerdrForwardService.isForwardableRemoteSocketPath(path), path
            )
        }
        let invalid = [
            "",                       // nothing
            "herdr.sock",             // relative
            "-L/tmp/x",               // option-shaped
            "/tmp/a:b.sock",          // would re-split the -L spec
            "/tmp/a b.sock",          // outside the header charset
            "/tmp/a\r\nb.sock",       // outside the header charset
            "/tmp/\u{1B}].sock",      // outside the header charset
            "/tmp/" + String(repeating: "x", count: 300), // beyond the value cap
        ]
        for path in invalid {
            XCTAssertFalse(
                ClaudeRemoteHerdrForwardService.isForwardableRemoteSocketPath(path), path
            )
        }
    }

    // MARK: - The live workspace provider

    func testLiveWorkspaceIsAFreshPrivateDirectoryAndIsRemovedOnClose() throws {
        let base = NSTemporaryDirectory().appending("lvx-forward-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        defer { try? FileManager.default.removeItem(atPath: base) }

        let provider = ClaudeRemoteHerdrForwardWorkspaces(base: base)
        let first = try provider.makeWorkspace()
        let second = try provider.makeWorkspace()

        XCTAssertNotEqual(first.socketPath, second.socketPath, "a socket path is never reused")
        XCTAssertTrue(first.socketPath.hasPrefix(first.directoryPath + "/"))
        let metadata = try unwrapAsync(ClaudeSocketGuard.metadata(ofPath: first.directoryPath))
        XCTAssertTrue(metadata.isDirectory)
        XCTAssertEqual(metadata.mode, 0o700)
        XCTAssertEqual(metadata.ownerUID, UInt32(geteuid()))

        provider.remove(first)
        XCTAssertNil(ClaudeSocketGuard.metadata(ofPath: first.directoryPath))
        provider.remove(second)
    }

    func testTheProductionWorkspaceBaseProducesADialableSocketPath() throws {
        // The DEFAULT base (the per-user temporary directory), because that is
        // the one that has to fit in `sun_path`'s 104 bytes. Application
        // Support was rejected for exactly this: a long user name would push a
        // path past the ceiling and produce a socket nothing can dial.
        let provider = ClaudeRemoteHerdrForwardWorkspaces()
        let workspace = try provider.makeWorkspace()
        defer { provider.remove(workspace) }

        XCTAssertTrue(
            ClaudeRemoteHerdrForwardService.isUsableLocalSocketPath(workspace.socketPath),
            "production socket path is \(workspace.socketPath.utf8.count) bytes: \(workspace.socketPath)"
        )
    }

    // MARK: - The live spawner tears down the whole process GROUP

    /// Spawn a leader that forks a descendant which IGNORES SIGTERM, and hand
    /// back the descendant's pid.
    ///
    /// The SIGTERM-ignoring part is the whole test (review round 3, new major):
    /// with a descendant that dies on TERM, the leader's own exit satisfies
    /// `waitForExit` and the bounded teardown returns before SIGKILL — so a
    /// `sleep` descendant would pass even with the kill suppressed.
    private func spawnLeaderWithStubbornDescendant(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (process: LiveHerdrForwardProcess, descendant: pid_t, cleanup: () -> Void) {
        let directory = NSTemporaryDirectory()
            .appending("lvx-forward-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        let pidFile = (directory as NSString).appendingPathComponent("child.pid")
        let cleanup: () -> Void = { _ = try? FileManager.default.removeItem(atPath: directory) }

        let spawner = ClaudeRemoteHerdrForwardSpawner(
            executablePath: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"]
        )
        let spawned = try spawner.spawn(argv: [
            "sh", "-c",
            "sh -c 'trap \"\" TERM; sleep 60' & echo $! > \(pidFile); wait",
        ])
        let process = try XCTUnwrap(
            spawned as? LiveHerdrForwardProcess, "the live spawner returns a LiveHerdrForwardProcess",
            file: file, line: line
        )

        // Bounded wait for the descendant to announce itself. A live-process
        // test cannot inject a clock into the kernel; the bound is what keeps
        // it from being a hang.
        var descendantPID: pid_t?
        for _ in 0..<300 {
            if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                descendantPID = pid
                break
            }
            usleep(10_000)
        }
        let descendant = try XCTUnwrap(
            descendantPID, "the child never spawned a descendant", file: file, line: line
        )
        return (process, descendant, cleanup)
    }

    func testTerminatingTheLiveChildAlsoKillsADescendantThatIgnoresSIGTERM() throws {
        // The orphan half of finding 5, tightened by round 3: ssh can leave
        // descendants, and the leader exiting says NOTHING about them. Teardown
        // therefore SIGKILLs the group unconditionally.
        let (process, descendant, cleanup) = try spawnLeaderWithStubbornDescendant()
        defer { cleanup() }
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(kill(descendant, 0), 0, "the descendant should be alive before teardown")

        process.terminate()

        var descendantIsGone = false
        for _ in 0..<300 {
            if kill(descendant, 0) != 0 {
                descendantIsGone = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(
            descendantIsGone,
            "terminate() must SIGKILL the whole group, even after the leader went quietly"
        )
        XCTAssertFalse(process.isRunning)
    }

    func testTerminatingAfterTheLeaderAlreadyExitedStillKillsTheGroup() throws {
        // The exact shape the round-3 review described: by the time teardown
        // runs, the leader is already gone and only the stubborn descendant is
        // left. A liveness guard on the kill would skip it here.
        let (process, descendant, cleanup) = try spawnLeaderWithStubbornDescendant()
        defer { cleanup() }

        // SIGTERM the leader ONLY (positive pid), and wait for it to go.
        _ = kill(process.leaderPID, SIGTERM)
        for _ in 0..<300 where process.isRunning { usleep(10_000) }
        XCTAssertFalse(process.isRunning, "the leader should have exited on its own")
        XCTAssertEqual(kill(descendant, 0), 0, "the descendant ignores SIGTERM and survives")

        process.terminate()

        var descendantIsGone = false
        for _ in 0..<300 {
            if kill(descendant, 0) != 0 {
                descendantIsGone = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(descendantIsGone, "a dead leader must not suppress the group SIGKILL")
    }

    func testTerminatingTheLiveChildAlsoKillsItsDescendants() throws {
        // The plain case kept alongside the stubborn one: an ordinary
        // descendant that does die on SIGTERM.
        let directory = NSTemporaryDirectory()
            .appending("lvx-forward-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let pidFile = (directory as NSString).appendingPathComponent("child.pid")

        let spawner = ClaudeRemoteHerdrForwardSpawner(
            executablePath: "/bin/sh",
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let process = try spawner.spawn(argv: [
            "sh", "-c", "sleep 60 & echo $! > \(pidFile); wait",
        ])
        XCTAssertTrue(process.isRunning)

        // Bounded wait for the grandchild to announce itself. A live-process
        // test cannot inject a clock into the kernel; the bound is what keeps
        // it from being a hang.
        var grandchildPID: pid_t?
        for _ in 0..<200 {
            if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                grandchildPID = pid
                break
            }
            usleep(10_000)
        }
        let grandchild = try XCTUnwrap(grandchildPID, "the child never spawned a grandchild")
        XCTAssertEqual(kill(grandchild, 0), 0, "the grandchild should be alive before teardown")

        process.terminate()

        // The group signal reaches the grandchild too. Bounded poll again: the
        // kernel delivers asynchronously.
        var grandchildIsGone = false
        for _ in 0..<200 {
            if kill(grandchild, 0) != 0 {
                grandchildIsGone = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(grandchildIsGone, "terminate() must kill the whole process group")
        XCTAssertFalse(process.isRunning)
    }

    // MARK: - Never signal a group after reaping it (review round 4)

    func testAForwardThatExitsOnItsOwnIsNotReapedUntilTeardown() throws {
        // The pid — and with it the process GROUP id — is reserved only while
        // the child is unreaped. Reaping in the exit handler (as the round-3
        // version did) opened a window where a later `close()` could
        // `kill(-pid)` a stranger's group: a tunnel that exits by itself
        // mid-dictation is reaped, and stop time closes it seconds later.
        let spawner = ClaudeRemoteHerdrForwardSpawner(
            executablePath: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"]
        )
        let process = try unwrapAsync(
            try spawner.spawn(argv: ["sh", "-c", "exit 0"]) as? LiveHerdrForwardProcess
        )

        // Wait for the exit event, bounded.
        for _ in 0..<300 where process.isRunning { usleep(10_000) }
        XCTAssertFalse(process.isRunning, "the leader should have exited on its own")

        // Un-reaped: the zombie still holds the pid, which is what keeps
        // `-pid` meaning OUR group.
        XCTAssertFalse(process.hasBeenReaped)
        XCTAssertEqual(
            kill(process.leaderPID, 0), 0,
            "an unreaped child still exists, reserving its pid"
        )

        process.terminate()

        XCTAssertTrue(process.hasBeenReaped)
        var isCollected = false
        for _ in 0..<300 {
            if kill(process.leaderPID, 0) != 0 {
                isCollected = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(isCollected, "teardown must collect the child")
    }

    func testNoGroupSignalIsSentAfterTheChildHasBeenReaped() throws {
        let spawner = ClaudeRemoteHerdrForwardSpawner(
            executablePath: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"]
        )
        let process = try unwrapAsync(
            try spawner.spawn(argv: ["sh", "-c", "exit 0"]) as? LiveHerdrForwardProcess
        )
        for _ in 0..<300 where process.isRunning { usleep(10_000) }

        process.terminate()
        let afterFirstTeardown = process.groupSignalsSent
        XCTAssertTrue(process.hasBeenReaped)

        // Every later close — and `close()` is called from several exit paths
        // plus deinit — must send NOTHING, because the pid may now belong to
        // someone else.
        process.terminate()
        process.terminate()

        XCTAssertEqual(
            process.groupSignalsSent, afterFirstTeardown,
            "a reaped pid must never be signalled again"
        )
    }

    // MARK: - The reap itself can fail (review round 4, medium)

    /// Spawns a real `sh -c 'exit 0'` in its own process group, with an
    /// injected `waitpid`. Real child, real group, scripted collection.
    private func spawnExitingChild(
        waitForChild: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>?, Int32) -> pid_t,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LiveHerdrForwardProcess {
        let spawner = ClaudeRemoteHerdrForwardSpawner(
            executablePath: "/bin/sh",
            environment: ["PATH": "/usr/bin:/bin"],
            waitForChild: waitForChild
        )
        let process = try XCTUnwrap(
            try spawner.spawn(argv: ["sh", "-c", "exit 0"]) as? LiveHerdrForwardProcess,
            "the live spawner returns a LiveHerdrForwardProcess", file: file, line: line
        )
        // Bounded wait for the exit event.
        for _ in 0..<300 where process.isRunning { usleep(10_000) }
        XCTAssertFalse(process.isRunning, "the child should have exited", file: file, line: line)
        return process
    }

    func testAnInterruptedReapIsRetriedRatherThanClaimedAsDone() throws {
        // `waitpid` returning EINTR is not an answer. The first version
        // committed `reaped` BEFORE calling it and ignored the result, so a
        // caught signal left a zombie while the state insisted it was gone —
        // one leaked per dictation, forever.
        let calls = ReapCallCounter()
        let process = try spawnExitingChild(waitForChild: { pid, status, options in
            if calls.next() <= 2 {
                errno = EINTR
                return -1
            }
            return waitpid(pid, status, options)
        })

        process.terminate()

        // The retry happens on the handle's own queue — nothing blocks — so the
        // collection lands asynchronously.
        var collected = false
        for _ in 0..<300 {
            if process.hasBeenReaped {
                collected = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(collected)
        XCTAssertGreaterThanOrEqual(calls.value, 3, "EINTR must be retried, not swallowed")
        var isCollected = false
        for _ in 0..<300 {
            if kill(process.leaderPID, 0) != 0 {
                isCollected = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(isCollected, "the child must actually be collected")
    }

    func testAFailedReapLeavesTheChildForALaterAttempt() throws {
        // A non-recoverable, non-ECHILD failure must NOT claim success: the
        // zombie is still ours, `-pid` still names our group, and the next
        // teardown has to be able to try again.
        let calls = ReapCallCounter()
        // Only the FIRST collection attempt fails, so the retry that every
        // later exit path makes is the one that succeeds.
        let process = try spawnExitingChild(waitForChild: { pid, status, options in
            if calls.next() == 1 {
                errno = EINVAL
                return -1
            }
            return waitpid(pid, status, options)
        })

        process.terminate()

        XCTAssertFalse(process.hasBeenReaped, "a failed collection is not a collection")
        XCTAssertGreaterThan(
            process.groupSignalsSent, 0, "an unreaped group is still ours to signal"
        )
        XCTAssertEqual(
            kill(process.leaderPID, 0), 0, "the unreaped child still exists, holding its pid"
        )

        // The later attempt every exit path makes — and this one succeeds.
        process.terminate()

        XCTAssertTrue(process.hasBeenReaped)
    }

    func testAnAlreadyCollectedChildIsDefinitivelyReaped() throws {
        // ECHILD is the kernel saying there is nothing left to collect. That IS
        // definitive, so the state commits — and nothing may signal the group
        // afterwards.
        let process = try spawnExitingChild(waitForChild: { _, _, _ in
            errno = ECHILD
            return -1
        })

        process.terminate()
        let signalsAtReap = process.groupSignalsSent

        XCTAssertTrue(process.hasBeenReaped)
        process.terminate()
        XCTAssertEqual(
            process.groupSignalsSent, signalsAtReap,
            "a pid the kernel disowned must never be signalled again"
        )

        // The fake never collected it; do so now that the handle has stopped
        // signalling, so the test process leaves no zombie behind.
        collectForTestCleanup(process.leaderPID)
    }

    // MARK: - The non-blocking collect and its hand-off (review round 7)

    /// Collect a child the test's fake never collected, WITHOUT a blocking
    /// wait: the child is already dead, so WNOHANG succeeds at once and the
    /// bound is only there so a surprise cannot hang the suite.
    private func collectForTestCleanup(_ pid: pid_t) {
        var status: Int32 = 0
        for _ in 0..<200 {
            if waitpid(pid, &status, WNOHANG) != 0 { return }
            usleep(10_000)
        }
        XCTFail("test child \(pid) was never collectable")
    }

    func testAGroupSignalCannotRunWhileTheCollectionIsInFlight() throws {
        // The PID-reuse invariant, stated as a race rather than as a comment
        // (review round 8). The collection's `waitpid` releases the pid; if a
        // concurrent `terminate()` can take the lock and read `reaped == false`
        // in that gap, it signals a pid the kernel may already have reissued.
        //
        // So: park a collection INSIDE `waitpid` and prove a concurrent
        // teardown cannot get through. With the reap under the same lock as the
        // `reaped` check, the second teardown blocks on the mutex; with the
        // reap outside it (the earlier shape), it sails past and signals.
        let insideWaitpid = DispatchSemaphore(value: 0)
        let releaseWaitpid = DispatchSemaphore(value: 0)
        let calls = ReapCallCounter()
        let signalAttempts = ReapCallCounter()
        let spawner = ClaudeRemoteHerdrForwardSpawner(
            executablePath: "/bin/sh",
            environment: ["PATH": "/usr/bin:/bin"],
            waitForChild: { pid, status, options in
                if calls.next() == 1 {
                    insideWaitpid.signal()
                    // Held long enough that "B is still blocked" cannot be
                    // confused with "B is merely slow": a teardown that DOES
                    // get through costs at most two 0.25 s grace waits, well
                    // under the window sampled below. Bounded so a failure
                    // cannot hang the suite.
                    _ = releaseWaitpid.wait(timeout: .now() + 3)
                }
                return waitpid(pid, status, options)
            },
            willAttemptTeardownLock: { _ = signalAttempts.next() }
        )
        let process = try XCTUnwrap(
            try spawner.spawn(argv: ["sh", "-c", "exit 0"]) as? LiveHerdrForwardProcess
        )
        for _ in 0..<300 where process.isRunning { usleep(10_000) }

        // A: drives the collection and parks inside `waitpid`.
        let firstTeardownReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.terminate()
            firstTeardownReturned.signal()
        }
        XCTAssertEqual(
            insideWaitpid.wait(timeout: .now() + 5), .success,
            "the collection should have reached waitpid"
        )
        let attemptsBeforeB = signalAttempts.value

        // B: a concurrent teardown, which must not be able to signal the group
        // while A holds the collection open. Deliberately does NOT touch the
        // state mutex from this thread — progress is observed through the
        // signal-ATTEMPT seam (which fires before the lock is taken) and
        // through B's own completion.
        let secondTeardownReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.terminate()
            secondTeardownReturned.signal()
        }

        // BARRIER (review round 8b): prove B has actually reached the lock
        // before timing anything. Without this, a starved global queue could
        // leave B merely unscheduled and the interval below would "pass" even
        // with the reap moved back outside the mutex. The seam fires on
        // `terminate()` entry — the guard immediately after it IS a lock
        // acquisition — so an increment means B is at the door.
        var reachedTheLock = false
        for _ in 0..<500 {
            if signalAttempts.value > attemptsBeforeB {
                reachedTheLock = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(reachedTheLock, "the second teardown never reached the group signal")

        // 1.2 s: longer than a teardown that gets through needs (≤0.5 s of
        // grace waits), shorter than the 3 s the collection is parked for.
        XCTAssertEqual(
            secondTeardownReturned.wait(timeout: .now() + 1.2), .timedOut,
            "a teardown must not proceed while a collection holds the lock"
        )

        releaseWaitpid.signal()
        XCTAssertEqual(firstTeardownReturned.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondTeardownReturned.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(process.hasBeenReaped)
    }

    func testTheCollectionBudgetIsExhaustedAndThenReleased() throws {
        // A genuine observation of the bound (review round 8b). Sampling a
        // counter could not distinguish "the chain finished" from "the queue is
        // busy": one poll running, a delayed utility queue, and the old
        // assertions passed with four polls still scheduled — and a regression
        // that stopped after a single hand-off poll passed too.
        //
        // So the process announces the END of the collection effort, and this
        // waits for that instead of guessing.
        let attempts = 5
        let calls = ReapCallCounter()
        let effortFinished = DispatchSemaphore(value: 0)
        let spawner = ClaudeRemoteHerdrForwardSpawner(
            executablePath: "/bin/sh",
            environment: ["PATH": "/usr/bin:/bin"],
            waitForChild: { _, _, _ in
                _ = calls.next()
                return 0 // WNOHANG: "still running", forever
            },
            reapPollAttempts: attempts,
            reapPollInterval: 0.002,
            reapEffortDidFinish: { effortFinished.signal() }
        )
        let process = try XCTUnwrap(
            try spawner.spawn(argv: ["sh", "-c", "exit 0"]) as? LiveHerdrForwardProcess
        )
        for _ in 0..<300 where process.isRunning { usleep(10_000) }

        process.terminate()

        XCTAssertEqual(
            effortFinished.wait(timeout: .now() + 5), .success,
            "the poll chain must reach a terminal state on its own"
        )

        // EXACTLY one attempt on the caller's thread plus the full queued
        // budget — no fewer (a chain that gave up early) and no more (a chain
        // that outlived its budget).
        XCTAssertEqual(calls.value, attempts + 1)
        XCTAssertFalse(process.hasBeenReaped, "an uncollectable child is never claimed as reaped")

        // And nothing is left scheduled: no further attempts after the end.
        let afterFinish = calls.value
        usleep(50_000)
        XCTAssertEqual(calls.value, afterFinish, "the poll chain must release itself")

        collectForTestCleanup(process.leaderPID)
    }

    func testANeverCollectableChildDoesNotBlockTeardown() throws {
        // The whole point of the simplification: there is no `waitpid(…, 0)`
        // anywhere, so a child that never becomes collectable costs a bounded
        // background poll and nothing else. If this regressed, the test would
        // hang rather than fail.
        let calls = ReapCallCounter()
        let process = try spawnExitingChild(waitForChild: { _, _, _ in
            _ = calls.next()
            return 0 // WNOHANG: "still running", forever
        })

        process.terminate()

        XCTAssertFalse(process.hasBeenReaped, "an uncollectable child is never claimed as reaped")
        XCTAssertGreaterThan(process.groupSignalsSent, 0, "the group is still ours to signal")
        // Collect it for real so the test process leaves nothing behind.
        collectForTestCleanup(process.leaderPID)
    }

    func testAChildThatIsNotReadyImmediatelyIsCollectedByTheHandOff() throws {
        // The first attempt runs on the caller's thread; anything else goes to
        // this handle's OWN queue. Nothing here is allowed to block, so the
        // collection lands asynchronously.
        let calls = ReapCallCounter()
        let process = try spawnExitingChild(waitForChild: { pid, status, options in
            if calls.next() <= 3 { return 0 }
            return waitpid(pid, status, options)
        })

        process.terminate()

        var collected = false
        for _ in 0..<300 {
            if process.hasBeenReaped {
                collected = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(collected, "the background poll must finish the collection")
        XCTAssertGreaterThan(calls.value, 3)
    }

    func testClosingTheHandleAgainRetriesAFailedCollection() throws {
        // Production's retry path. `close()` used to skip `terminate()` once the
        // handle was already closed, so deinit could not retry and only a test
        // calling `terminate()` twice ever recovered a failed reap.
        let calls = ReapCallCounter()
        let process = try spawnExitingChild(waitForChild: { pid, status, options in
            if calls.next() == 1 {
                errno = EINVAL
                return -1
            }
            return waitpid(pid, status, options)
        })
        let workspace = ClaudeRemoteHerdrForwardWorkspace(
            directoryPath: "/tmp/lvx-retry-test", socketPath: "/tmp/lvx-retry-test/h.sock"
        )
        let removals = ReapCallCounter()
        let handle = ClaudeRemoteHerdrForwardHandle(
            workspace: workspace,
            process: process,
            removeWorkspace: { _ in _ = removals.next() }
        )

        handle.close()
        XCTAssertFalse(process.hasBeenReaped, "the first collection failed")

        handle.close()

        XCTAssertTrue(process.hasBeenReaped, "a later close must retry the collection")
        XCTAssertEqual(removals.value, 1, "the workspace is still removed exactly once")
    }

    func testTerminatingTwiceIsHarmless() throws {
        let spawner = ClaudeRemoteHerdrForwardSpawner(
            executablePath: "/bin/sh", environment: ["PATH": "/usr/bin:/bin"]
        )
        let process = try spawner.spawn(argv: ["sh", "-c", "sleep 60"])
        process.terminate()
        process.terminate()
        XCTAssertFalse(process.isRunning)
    }

    func testSpawningAMissingExecutableThrows() {
        let spawner = ClaudeRemoteHerdrForwardSpawner(
            executablePath: "/nonexistent/lvx-ssh", environment: [:]
        )
        XCTAssertThrowsError(try spawner.spawn(argv: ["ssh", "-N", "--", "builder"]))
    }

    func testLiveWorkspaceRefusesToReuseAnExistingDirectory() throws {
        let base = NSTemporaryDirectory().appending("lvx-forward-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: base, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: base) }

        // A provider with a fixed name, so the second call collides with the
        // first — standing in for a directory somebody else planted.
        let provider = ClaudeRemoteHerdrForwardWorkspaces(base: base, makeName: { "fixed" })
        _ = try provider.makeWorkspace()
        XCTAssertThrowsError(try provider.makeWorkspace())
    }
}

// MARK: - Alias → enrolled host

private final class MemoryHostStore: ClaudeRemoteHostStoreIO, @unchecked Sendable {
    private let files = Mutex<[String: Data]>([:])

    func read(from url: URL) throws -> Data? {
        files.withLock { $0[url.path] }
    }

    func write(_ data: Data, to url: URL) throws {
        files.withLock { $0[url.path] = data }
    }
}

final class ClaudeRemoteHostAliasMatchingTests: XCTestCase {
    private func makeRegistry() throws -> ClaudeRemoteHostRegistry {
        let ids = Mutex(["h11111111", "h22222222", "h33333333"])
        return try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/lvx-tests/hosts.json"),
            io: MemoryHostStore(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeToken: { String(repeating: "t", count: 32) },
            makeHostID: { ids.withLock { $0.isEmpty ? "hzzzzzzz" : $0.removeFirst() } }
        )
    }

    func testTheEnrolledAliasMatchesTheSSHDestinationCaseInsensitively() throws {
        let registry = try makeRegistry()
        _ = try registry.enroll(label: "build box", sshHostAlias: "Builder")

        XCTAssertEqual(registry.hosts(matchingSSHDestination: "builder").count, 1)
        XCTAssertEqual(registry.hosts(matchingSSHDestination: "BUILDER").count, 1)
        // And the STORED spelling comes back — that is the vetted string, and
        // the only one allowed to reach an argv.
        XCTAssertEqual(registry.hosts(matchingSSHDestination: "builder").first?.sshHostAlias, "Builder")
    }

    func testAnotherDestinationMatchesNothing() throws {
        let registry = try makeRegistry()
        _ = try registry.enroll(label: "build box", sshHostAlias: "builder")

        XCTAssertTrue(registry.hosts(matchingSSHDestination: "someone-elses-box").isEmpty)
        XCTAssertTrue(registry.hosts(matchingSSHDestination: "").isEmpty)
        // The label is not the alias, and never stands in for it.
        XCTAssertTrue(registry.hosts(matchingSSHDestination: "build box").isEmpty)
    }

    func testARevokedHostStopsMatching() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "build box", sshHostAlias: "builder")
        XCTAssertEqual(registry.hosts(matchingSSHDestination: "builder").count, 1)

        try registry.revoke(hostID: enrollment.host.id)

        XCTAssertTrue(registry.hosts(matchingSSHDestination: "builder").isEmpty)
    }

    func testAHostEnrolledWithoutAnAliasNeverMatches() throws {
        let registry = try makeRegistry()
        _ = try registry.enroll(label: "legacy", sshHostAlias: nil)
        XCTAssertTrue(registry.hosts(matchingSSHDestination: "legacy").isEmpty)
    }
}
#endif
