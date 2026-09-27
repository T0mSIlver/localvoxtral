import ClaudeContextWire
import ClaudeHookPublisherCore
import Foundation
import localvoxtralTestSupport
import XCTest
@testable import localvoxtralCore

/// A second copy of the app lost both hook sockets to the first; the first
/// quits; the second takes them over, and a Claude Desktop session's recorded
/// hooks (`Tests/ClaudeDesktopHookPayloads`) join through it (#655). Field
/// case, 2026-09-27: without the takeover the survivor stayed deaf and every
/// Desktop dictation abstained until a relaunch.
@MainActor
final class ClaudeHookSocketTakeoverTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_790_499_300)
    private let desktopID = "local_6d880b94-4414-4764-a024-c95df1af4456"
    private let recordedSessionID = "fdad6dd0-fdd7-4118-ba62-ef71e8bf90e7"
    private let firstCopy: Int32 = 29_873
    private let smokeCopy: Int32 = 49_032
    private var desktop: TerminalScreenTarget {
        TerminalScreenTarget(pid: 4_100, bundleID: ClaudeDesktopAllowlist.bundleID)
    }

    /// Exit watches the test fires by hand.
    @MainActor
    private final class Exits {
        private final class Token {}
        private var armed: [Int32: @MainActor @Sendable () -> Void] = [:]
        var watched: [Int32] { armed.keys.sorted() }

        var watch: ClaudeHookSocketTakeover.ExitWatch {
            { [unowned self] pid, onExit in
                self.armed[pid] = onExit
                return Token()
            }
        }

        func exit(_ pid: Int32) {
            armed.removeValue(forKey: pid)?()
        }
    }

    private func payload(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("ClaudeDesktopHookPayloads/\(name).json"))
    }

    private func makeSessions() -> ClaudeSessionRegistry {
        let now = epoch
        return ClaudeSessionRegistry(now: { now }, isProcessAlive: { _ in true })
    }

    private func desktopJoin(_ sessions: ClaudeSessionRegistry) async -> ClaudeSessionJoin? {
        let address = "https://claude.ai/epitaxy/\(desktopID)"
        let resolver = ClaudeSessionJoinResolver(
            registry: sessions,
            focusedTerminalTTY: { _ in nil },
            focusedDesktopSessionURL: { _ in address }
        )
        return await resolver.resolve(target: desktop)
    }

    // MARK: - The remote listener, Desktop over ssh

    private struct RemoteSetup {
        let hosts: ClaudeRemoteHostRegistry
        let token: String
        let port: UInt16
        let first: ClaudeRemoteContextListener
        let sessions: ClaudeSessionRegistry
        let second: ClaudeRemoteListenerCoordinator
        let step: ClaudeHookSocketTakeover.Step
    }

    /// The first copy listening on the port, and a second whose launch lost
    /// the bind to it.
    private func remoteSetup() throws -> RemoteSetup {
        let now = epoch
        let hosts = try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-takeover-\(UUID().uuidString.prefix(8)).json"),
            io: MemoryRemoteHostStoreIO(),
            now: { now }
        )
        let token = try hosts.enroll(label: "sandbox").token
        let port = try unusedLoopbackPort()
        let first = ClaudeRemoteContextListener(
            registry: makeSessions(), hosts: hosts, limits: ClaudeRemoteListenerLimits(port: port), now: { now }
        )
        try first.start()
        let sessions = makeSessions()
        let second = ClaudeRemoteListenerCoordinator(hosts: hosts, sessions: sessions) { registry, rejections in
            ClaudeRemoteContextListener(
                registry: sessions,
                hosts: registry,
                limits: ClaudeRemoteListenerLimits(port: port),
                rejections: rejections,
                now: { now }
            )
        }
        let step = ClaudeHookSocketTakeover.Step(name: "remote listener") {
            do {
                try second.reconcile()
                return .bound
            } catch {
                return ClaudeHookSocketTakeover.Outcome(startError: error)
            }
        }
        return RemoteSetup(
            hosts: hosts, token: token, port: port, first: first, sessions: sessions, second: second, step: step
        )
    }

    /// What the remote shim posts for Desktop's recorded UserPromptSubmit:
    /// the recorded body, and the view id Desktop exported to the session.
    private func postDesktopPrompt(_ setup: RemoteSetup) throws -> RemoteListenerResponse {
        try postToRemoteListener(
            port: setup.port,
            path: "/v1/hook/UserPromptSubmit",
            headers: [
                "Authorization": "Bearer \(setup.token)",
                "Content-Type": "application/json",
                ClaudeRemotePluginVersionCodec.headerName: "1.18.0",
                ClaudeRemoteEnvironmentField.desktopSessionID.headerName: desktopID,
            ],
            body: try payload("UserPromptSubmit")
        )
    }

    func testTheSecondCopyTakesTheListenerWhenTheFirstQuitsAndADesktopSessionOverSSHJoins() async throws {
        let setup = try remoteSetup()
        defer {
            setup.second.shutdown()
            setup.first.stop()
        }
        XCTAssertEqual(setup.step.attempt(), .heldByAnotherCopy, "launch loses the bind to the running copy")

        let exits = Exits()
        let takeover = ClaudeHookSocketTakeover(
            steps: [setup.step], otherCopies: { [firstCopy] in [firstCopy] }, watchExit: exits.watch
        )
        takeover.begin()
        XCTAssertEqual(exits.watched, [firstCopy])
        XCTAssertFalse(setup.second.isListening)

        setup.first.stop()
        exits.exit(firstCopy)

        XCTAssertTrue(setup.second.isListening)
        XCTAssertFalse(takeover.isWaiting)
        XCTAssertEqual(exits.watched, [], "nothing left to wait for")

        XCTAssertEqual(try postDesktopPrompt(setup).status, 200)
        let joined = await desktopJoin(setup.sessions)
        let join = try XCTUnwrap(joined)
        XCTAssertEqual(join.mechanism, .desktopSession)
        XCTAssertFalse(join.snapshot.origin.isLocalAuthenticated, "the ssh host's session")
        XCTAssertTrue(join.snapshot.sessionID.hasSuffix(recordedSessionID))
    }

    /// A CI launch smoke exits while the owner's copy still holds the port:
    /// the retry finds it held, takes nothing, and waits for the next exit.
    func testAnExitOfACopyThatHoldsNothingKeepsWaiting() async throws {
        let setup = try remoteSetup()
        defer {
            setup.second.shutdown()
            setup.first.stop()
        }
        _ = setup.step.attempt()
        var running = [firstCopy, smokeCopy]
        let exits = Exits()
        let takeover = ClaudeHookSocketTakeover(
            steps: [setup.step], otherCopies: { running }, watchExit: exits.watch
        )
        takeover.begin()
        XCTAssertEqual(exits.watched, [firstCopy, smokeCopy])

        running = [firstCopy]
        exits.exit(smokeCopy)
        XCTAssertTrue(takeover.isWaiting)
        XCTAssertFalse(setup.second.isListening)
        XCTAssertEqual(exits.watched, [firstCopy], "re-armed on the copies still running")

        setup.first.stop()
        running = []
        exits.exit(firstCopy)
        XCTAssertTrue(setup.second.isListening)
        XCTAssertEqual(try postDesktopPrompt(setup).status, 200)
        let join = await desktopJoin(setup.sessions)
        XCTAssertEqual(join?.mechanism, .desktopSession)
    }

    // MARK: - The local broker, Desktop on this Mac

    func testTheSecondCopyTakesTheBrokerWhenTheFirstQuitsAndALocalDesktopSessionJoins() async throws {
        // /tmp: `sun_path` is 104 bytes on Darwin (see ClaudeContextBrokerTests).
        let directory = URL(fileURLWithPath: "/tmp/lvx-\(UUID().uuidString.prefix(8))")
        let socketPath = directory.appendingPathComponent("s").path
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ClaudeContextBroker(socketPath: socketPath, registry: makeSessions())
        try first.start()
        defer { first.stop() }

        let sessions = makeSessions()
        var second: ClaudeContextBroker?
        defer { second?.stop() }
        let step = ClaudeHookSocketTakeover.Step(name: "broker") {
            let broker = ClaudeContextBroker(socketPath: socketPath, registry: sessions)
            do {
                try broker.start()
                second = broker
                return .bound
            } catch {
                return ClaudeHookSocketTakeover.Outcome(startError: error)
            }
        }
        XCTAssertEqual(step.attempt(), .heldByAnotherCopy)

        let exits = Exits()
        let takeover = ClaudeHookSocketTakeover(
            steps: [step], otherCopies: { [firstCopy] in [firstCopy] }, watchExit: exits.watch
        )
        takeover.begin()
        first.stop()
        exits.exit(firstCopy)
        XCTAssertNotNil(second)
        XCTAssertFalse(takeover.isWaiting)

        let publisher = ClaudeHookPublisher(
            environment: .init(
                now: { 1_790_499_330 },
                pid: { 71_250 },
                ppid: { 71_203 },
                ttyName: { _ in nil },
                variables: [
                    ClaudeHookSocketPath.environmentKey: socketPath,
                    "CLAUDE_CODE_HOST_SESSION_ID": desktopID,
                    "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
                ]
            ),
            publisher: UnixSocketPublisher(timeout: 2.0)
        )
        XCTAssertEqual(publisher.run(stdin: try payload("UserPromptSubmit"), fallbackEvent: nil), .published)
        let joined = await desktopJoin(sessions)
        let join = try XCTUnwrap(joined)
        XCTAssertEqual(join.mechanism, .desktopSession)
        XCTAssertEqual(join.snapshot.sessionID, recordedSessionID)
    }

    // MARK: - Outcomes

    func testOnlyALiveHolderIsWaitedFor() async {
        typealias Outcome = ClaudeHookSocketTakeover.Outcome
        XCTAssertEqual(
            Outcome(startError: ClaudeContextBroker.StartFailure.socketOwnedByLiveInstance("/s")), .heldByAnotherCopy
        )
        XCTAssertEqual(
            Outcome(startError: ClaudeRemoteContextListener.StartFailure.bindFailed(errno: EADDRINUSE)),
            .heldByAnotherCopy
        )
        XCTAssertEqual(Outcome(startError: ClaudeContextBroker.StartFailure.bindFailed(errno: EADDRINUSE)), .failed,
                       "a leftover file the broker could not remove is no copy's")
        XCTAssertEqual(Outcome(startError: ClaudeRemoteContextListener.StartFailure.bindFailed(errno: EACCES)), .failed)
    }

    func testNoOtherCopyMeansNothingToWaitFor() async {
        let exits = Exits()
        let takeover = ClaudeHookSocketTakeover(
            steps: [.init(name: "remote listener") { .heldByAnotherCopy }],
            otherCopies: { [] },
            watchExit: exits.watch
        )
        takeover.begin()
        XCTAssertEqual(exits.watched, [])
        XCTAssertEqual(takeover.waitingSteps, ["remote listener"])
    }

    #if canImport(Darwin)
    func testTheExitWatchFiresWhenTheProcessExits() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let exited = expectation(description: "exit seen")
        let watch = ProcessExitWatch(pid: child.processIdentifier) { exited.fulfill() }
        child.terminate()
        await fulfillment(of: [exited], timeout: 10)
        withExtendedLifetime(watch) {}
    }

    func testTheExitWatchFiresForAProcessAlreadyGone() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let exited = expectation(description: "exit seen")
        let watch = ProcessExitWatch(pid: child.processIdentifier) { exited.fulfill() }
        await fulfillment(of: [exited], timeout: 10)
        withExtendedLifetime(watch) {}
    }
    #endif
}
