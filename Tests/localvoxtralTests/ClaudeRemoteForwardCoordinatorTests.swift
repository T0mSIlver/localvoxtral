import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

private final class MemoryHostStore: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<[String: Data]>([:])
    func read(from url: URL) throws -> Data? { contents.withLock { $0[url.path] } }
    func write(_ data: Data, to url: URL) throws { contents.withLock { $0[url.path] = data } }
}

/// A supervisor stand-in that records rather than spawns. The coordinator's job
/// is deciding WHICH hosts should have a forward and when — never how ssh
/// behaves, which is the supervisor's own suite. Nothing here can reach a
/// process: that is the point of the seam.
@MainActor
private final class FakeForwarding: ClaudeRemoteForwarding {
    let hostID: String
    private let spy: ForwardSpy
    var state: ClaudeRemoteForwardSupervisor.State = .stopped
    var onStateChange: (@MainActor (ClaudeRemoteForwardSupervisor.State) -> Void)?
    /// Settable so a test can hand the coordinator a teardown that is
    /// still draining and prove the replacement waits for it.
    var teardown: Task<Void, Never>?

    init(hostID: String, spy: ForwardSpy) {
        self.hostID = hostID
        self.spy = spy
    }

    func start() {
        spy.noteStart(hostID)
        transition(to: .connecting)
    }

    func stop() {
        spy.noteStop(hostID)
        transition(to: .stopped)
    }

    func retry() { spy.noteRetry(hostID) }

    /// Lets a test drive the pane's view of a forward without a supervisor.
    func transition(to newState: ClaudeRemoteForwardSupervisor.State) {
        state = newState
        onStateChange?(newState)
    }
}

@MainActor
private final class ForwardSpy {
    private(set) var started: [String] = []
    private(set) var stopped: [String] = []
    private(set) var retried: [String] = []
    private(set) var configurations: [ClaudeRemoteForwardSupervisor.Configuration] = []
    private(set) var forwards: [String: FakeForwarding] = [:]

    func makeSupervisor(
        _ configuration: ClaudeRemoteForwardSupervisor.Configuration
    ) -> any ClaudeRemoteForwarding {
        configurations.append(configuration)
        let forwarding = FakeForwarding(hostID: configuration.hostID, spy: self)
        forwards[configuration.hostID] = forwarding
        return forwarding
    }

    func noteStart(_ hostID: String) { started.append(hostID) }
    func noteStop(_ hostID: String) { stopped.append(hostID) }
    func noteRetry(_ hostID: String) { retried.append(hostID) }
}

@MainActor
final class ClaudeRemoteForwardCoordinatorTests: XCTestCase {
    private func makeRegistry() throws -> ClaudeRemoteHostRegistry {
        try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-forward-test/\(UUID().uuidString).json"),
            io: MemoryHostStore(),
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }

    private func makeCoordinator(
        registry: ClaudeRemoteHostRegistry,
        spy: ForwardSpy,
        isListenerBound: @escaping @MainActor () -> Bool = { true },
        reapOrphans: (@Sendable () async -> Void)? = nil
    ) -> ClaudeRemoteForwardCoordinator {
        ClaudeRemoteForwardCoordinator(
            hosts: registry,
            remoteForwardPort: 28511,
            listenerPort: 8473,
            isListenerBound: isListenerBound,
            makeSupervisor: { spy.makeSupervisor($0) },
            reapOrphans: reapOrphans
        )
    }

    func testOnlyHostsThatOptedInGetAForward() throws {
        let registry = try makeRegistry()
        let opted = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        _ = try registry.enroll(label: "other", sshHostAlias: "other")
        try registry.setPersistentForwardEnabled(true, hostID: opted.id)

        let spy = ForwardSpy()
        makeCoordinator(registry: registry, spy: spy).reconcile()

        XCTAssertEqual(spy.started, [opted.id], "an app that ssh'd anywhere unasked would be a bug")
        XCTAssertEqual(spy.configurations.first?.sshHostAlias, "builder")
        XCTAssertEqual(spy.configurations.first?.remoteForwardPort, 28511)
        XCTAssertEqual(spy.configurations.first?.listenerPort, 8473)
    }

    func testAHostWithNoAliasOnFileIsNeverForwarded() throws {
        // The label is not a substitute for an alias: a host NAMED prod can be
        // reached as builder, so guessing would ssh somewhere the user never
        // chose (PR #197).
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "buildhost").host
        try registry.setPersistentForwardEnabled(true, hostID: host.id)

        let spy = ForwardSpy()
        makeCoordinator(registry: registry, spy: spy).reconcile()

        XCTAssertTrue(spy.started.isEmpty)
    }

    func testRevokingAHostStopsItsForward() throws {
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        try registry.setPersistentForwardEnabled(true, hostID: host.id)

        let spy = ForwardSpy()
        let coordinator = makeCoordinator(registry: registry, spy: spy)
        coordinator.reconcile()
        try registry.revoke(hostID: host.id)
        coordinator.reconcile()

        XCTAssertEqual(spy.started, [host.id])
        XCTAssertEqual(spy.stopped, [host.id])
        XCTAssertNil(coordinator.states[host.id])
    }

    func testTurningTheToggleOffStopsTheForward() throws {
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        try registry.setPersistentForwardEnabled(true, hostID: host.id)

        let spy = ForwardSpy()
        let coordinator = makeCoordinator(registry: registry, spy: spy)
        coordinator.reconcile()
        try registry.setPersistentForwardEnabled(false, hostID: host.id)
        coordinator.reconcile()

        XCTAssertEqual(spy.stopped, [host.id], "disable must take effect without a relaunch")
    }

    func testReconcilingTwiceStartsNothingTwice() throws {
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        try registry.setPersistentForwardEnabled(true, hostID: host.id)

        let spy = ForwardSpy()
        let coordinator = makeCoordinator(registry: registry, spy: spy)
        coordinator.reconcile()
        coordinator.reconcile()

        XCTAssertEqual(spy.started, [host.id])
    }

    func testNoForwardRunsWhileTheListenerIsUnbound() throws {
        // A forward opened before the bind terminates at a closed port: the
        // hooks get connection-refused and fail open silently, while ssh on
        // THIS Mac prints `connect_to … failed.` into the user's remote
        // terminal on every dial. Listener first, always.
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        try registry.setPersistentForwardEnabled(true, hostID: host.id)

        let spy = ForwardSpy()
        let bound = Mutex(false)
        let coordinator = makeCoordinator(
            registry: registry, spy: spy, isListenerBound: { bound.withLock { $0 } }
        )
        coordinator.reconcile()
        XCTAssertTrue(spy.started.isEmpty, "no listener, no forward")

        bound.withLock { $0 = true }
        coordinator.reconcile()
        XCTAssertEqual(spy.started, [host.id])

        // …and a listener that goes away takes the forwards with it.
        bound.withLock { $0 = false }
        coordinator.reconcile()
        XCTAssertEqual(spy.stopped, [host.id])
    }

    func testStopAllTearsDownEveryForward() throws {
        let registry = try makeRegistry()
        let first = try registry.enroll(label: "one", sshHostAlias: "one").host
        let second = try registry.enroll(label: "two", sshHostAlias: "two").host
        try registry.setPersistentForwardEnabled(true, hostID: first.id)
        try registry.setPersistentForwardEnabled(true, hostID: second.id)

        let spy = ForwardSpy()
        let coordinator = makeCoordinator(registry: registry, spy: spy)
        coordinator.reconcile()
        coordinator.stopAll()

        XCTAssertEqual(Set(spy.stopped), [first.id, second.id])
        XCTAssertTrue(coordinator.states.isEmpty)
    }

    func testRetryIsForwardedToTheRightHostOnly() throws {
        let registry = try makeRegistry()
        let first = try registry.enroll(label: "one", sshHostAlias: "one").host
        let second = try registry.enroll(label: "two", sshHostAlias: "two").host
        try registry.setPersistentForwardEnabled(true, hostID: first.id)
        try registry.setPersistentForwardEnabled(true, hostID: second.id)

        let spy = ForwardSpy()
        let coordinator = makeCoordinator(registry: registry, spy: spy)
        coordinator.reconcile()
        coordinator.retry(hostID: second.id)

        XCTAssertEqual(spy.retried, [second.id])
    }

    func testAReplacementForwardWaitsForTheOldOneToFinishDying() async throws {
        // Toggle off, toggle straight back on — the ordinary way a user retries
        // something. The remote port is not free until the first ssh has
        // actually exited, so starting the replacement immediately dials a port
        // this Mac is still holding and the pane reports `portUnavailable` at
        // itself, terminally, for a host that is perfectly fine.
        let registry = try makeRegistry()
        let spy = ForwardSpy()
        let coordinator = makeCoordinator(registry: registry, spy: spy)
        let host = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        try registry.setPersistentForwardEnabled(true, hostID: host.id)
        coordinator.reconcile()
        XCTAssertEqual(spy.started, [host.id])

        // Stop it, leaving a teardown that has NOT finished.
        let release = TeardownGate()
        try XCTUnwrap(spy.forwards[host.id]).teardown = Task { await release.wait() }
        try registry.setPersistentForwardEnabled(false, hostID: host.id)
        coordinator.reconcile()
        XCTAssertEqual(spy.stopped, [host.id])

        // Back on while the old process is still dying.
        try registry.setPersistentForwardEnabled(true, hostID: host.id)
        coordinator.reconcile()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(
            spy.started, [host.id],
            "the replacement must not dial a port the old ssh still holds"
        )

        // Once it is gone, the replacement runs.
        release.open()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(spy.started, [host.id, host.id])
    }

    func testForwardsWaitForTheOrphanReapBeforeStarting() async throws {
        // The regression behind this gate (field report, 2026-08-05): an app
        // run that ended without a clean quit left its `ssh -N -R` alive and
        // holding the remote port, so the NEXT launch's forward was refused
        // its own port and the pane showed "Port held" terminally. The reap
        // kills that orphan first; a forward started before it finishes would
        // dial a port the orphan still holds and reproduce exactly that state.
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        try registry.setPersistentForwardEnabled(true, hostID: host.id)

        let spy = ForwardSpy()
        let reapGate = TeardownGate()
        let coordinator = makeCoordinator(
            registry: registry, spy: spy, reapOrphans: { await reapGate.wait() }
        )
        coordinator.reconcile()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(
            spy.started.isEmpty, "an orphan may still hold the port until the reap finishes"
        )

        reapGate.open()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(spy.started, [host.id])
    }

    func testTheOrphanReapRunsExactlyOnce() async throws {
        // The gate protects the FIRST start only. Records written after launch
        // belong to this instance's own live supervisors, and reaping again
        // would kill them.
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        try registry.setPersistentForwardEnabled(true, hostID: host.id)

        let spy = ForwardSpy()
        let reapCount = Mutex(0)
        let coordinator = makeCoordinator(
            registry: registry, spy: spy, reapOrphans: { reapCount.withLock { $0 += 1 } }
        )
        coordinator.reconcile()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(spy.started, [host.id])

        try registry.setPersistentForwardEnabled(false, hostID: host.id)
        coordinator.reconcile()
        try registry.setPersistentForwardEnabled(true, hostID: host.id)
        coordinator.reconcile()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(reapCount.withLock { $0 }, 1)
    }

    func testNoReapWhileTheListenerIsUnbound() async throws {
        // Multi-instance safety. A second app instance cannot bind the
        // listener while the first lives — and it must not reap either, or it
        // would kill the first instance's perfectly healthy tunnels.
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        try registry.setPersistentForwardEnabled(true, hostID: host.id)

        let spy = ForwardSpy()
        let reapCount = Mutex(0)
        let coordinator = makeCoordinator(
            registry: registry,
            spy: spy,
            isListenerBound: { false },
            reapOrphans: { reapCount.withLock { $0 += 1 } }
        )
        coordinator.reconcile()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(reapCount.withLock { $0 }, 0, "no listener, no reap")
        XCTAssertTrue(spy.started.isEmpty)
    }
}

/// A teardown a test can hold open and then release.
private final class TeardownGate: @unchecked Sendable {
    private let state = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let opened = Mutex(false)

    func wait() async {
        if opened.withLock({ $0 }) { return }
        await withCheckedContinuation { continuation in
            state.withLock { $0.append(continuation) }
        }
    }

    func open() {
        opened.withLock { $0 = true }
        let waiters = state.withLock { waiters -> [CheckedContinuation<Void, Never>] in
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
