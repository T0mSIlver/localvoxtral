import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// A fake `ssh -N -R`. Nothing here spawns a process or touches a network:
/// the supervisor's whole job is deciding what to do when ssh says something
/// or dies, and both are things a test must be able to cause on demand.
private final class FakeForwardProcess: ClaudeRemoteForwardProcess, @unchecked Sendable {
    let standardErrorLines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    private struct ExitState {
        var status: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
    }

    private let exitState = Mutex(ExitState())
    private let terminations = Mutex(0)

    var terminateCount: Int { terminations.withLock { $0 } }

    init() {
        let (stream, continuation) = AsyncStream<String>.makeStream(of: String.self)
        standardErrorLines = stream
        self.continuation = continuation
    }

    func emitStandardError(_ line: String) {
        continuation.yield(line)
    }

    /// Ends the process: the stderr stream finishes first, exactly as the live
    /// implementation guarantees, then waiters get the status.
    func finish(status: Int32) {
        continuation.finish()
        let waiters = exitState.withLock { state -> [CheckedContinuation<Int32, Never>] in
            guard state.status == nil else { return [] }
            state.status = status
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    func waitUntilExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let already = exitState.withLock { state -> Int32? in
                if let status = state.status { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let already { continuation.resume(returning: already) }
        }
    }

    func terminate() {
        terminations.withLock { $0 += 1 }
        finish(status: 143)
    }
}

/// Await-driven test harness. No polling and no wall clock: every wait is a
/// continuation the supervisor itself resumes, through the launch seam or the
/// state callback.
@MainActor
private final class ForwardHarness {
    private(set) var processes: [FakeForwardProcess] = []
    private(set) var states: [ClaudeRemoteForwardSupervisor.State] = []
    private(set) var sleeps: [Duration] = []

    struct WaitTimeout: Error {}

    /// A pending wait. Resolved either by the supervisor doing the thing, or by
    /// this waiter's own timeout task — which resumes with `nil`/`false` rather
    /// than leaving the test hung.
    ///
    /// Every wait is bounded on purpose. An unbounded one turns a broken
    /// supervisor into a HUNG SUITE instead of a failing test, which is exactly
    /// what happened the first time these ran against a deliberately broken
    /// build, and a hang tells CI nothing. The timeout is only a backstop: a
    /// passing run is resumed by the supervisor and never sleeps at all, so a
    /// generous 20s costs nothing and leaves room for the self-hosted runner
    /// to be running two other agents' jobs at the same time.
    private struct ProcessWaiter {
        let id: UUID
        let index: Int
        let continuation: CheckedContinuation<FakeForwardProcess?, Never>
    }

    private struct StateWaiter {
        let id: UUID
        let predicate: (ClaudeRemoteForwardSupervisor.State) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var processWaiters: [ProcessWaiter] = []
    private var stateWaiters: [StateWaiter] = []

    /// When true, every injected sleep records its duration and then BLOCKS
    /// until `releaseSleeps()`. That is what makes "the process died while its
    /// settle window was still open" an orderable event rather than a race.
    var holdSleeps = false
    private var heldSleeps: [CheckedContinuation<Void, Never>] = []

    func recordSleep(_ duration: Duration) async {
        sleeps.append(duration)
        guard holdSleeps else { return }
        await withCheckedContinuation { heldSleeps.append($0) }
    }

    func releaseSleeps() {
        let held = heldSleeps
        heldSleeps = []
        for continuation in held { continuation.resume() }
    }

    /// Releases the OLDEST held sleep only. Releasing one at a time is what
    /// makes "the stale settle window woke up while the supervise loop was
    /// still parked on its backoff" a state a test can actually stand in,
    /// rather than a scheduling coin-flip.
    func releaseOldestSleep() {
        guard !heldSleeps.isEmpty else { return }
        heldSleeps.removeFirst().resume()
    }

    func makeSupervisor(
        configuration: ClaudeRemoteForwardSupervisor.Configuration,
        launchFailure: (any Error)? = nil
    ) -> ClaudeRemoteForwardSupervisor {
        let supervisor = ClaudeRemoteForwardSupervisor(
            configuration: configuration,
            launch: { [weak self] _ in
                if let launchFailure { throw launchFailure }
                let process = FakeForwardProcess()
                self?.record(process)
                return process
            },
            sleepFor: { [weak self] duration in
                guard let self else { return }
                await self.recordSleep(duration)
            }
        )
        supervisor.onStateChange = { [weak self] state in self?.record(state) }
        return supervisor
    }

    private func record(_ process: FakeForwardProcess) {
        processes.append(process)
        let index = processes.count - 1
        let satisfied = processWaiters.filter { $0.index == index }
        processWaiters.removeAll { $0.index == index }
        for waiter in satisfied { waiter.continuation.resume(returning: process) }
    }

    private func record(_ state: ClaudeRemoteForwardSupervisor.State) {
        states.append(state)
        let satisfied = stateWaiters.filter { $0.predicate(state) }
        stateWaiters.removeAll { waiter in satisfied.contains { $0.id == waiter.id } }
        for waiter in satisfied { waiter.continuation.resume(returning: true) }
    }

    func process(
        _ index: Int, timeout: Duration = .seconds(20), line: UInt = #line
    ) async throws -> FakeForwardProcess {
        if processes.count > index { return processes[index] }
        let id = UUID()
        let result: FakeForwardProcess? = await withCheckedContinuation { continuation in
            processWaiters.append(ProcessWaiter(id: id, index: index, continuation: continuation))
            armTimeout(timeout) { [weak self] in self?.expireProcessWaiter(id) }
        }
        guard let result else {
            XCTFail("timed out waiting for process \(index)", line: line)
            throw WaitTimeout()
        }
        return result
    }

    func waitForState(
        timeout: Duration = .seconds(20),
        line: UInt = #line,
        _ predicate: @escaping (ClaudeRemoteForwardSupervisor.State) -> Bool
    ) async throws {
        if states.contains(where: predicate) { return }
        let id = UUID()
        let satisfied: Bool = await withCheckedContinuation { continuation in
            stateWaiters.append(
                StateWaiter(id: id, predicate: predicate, continuation: continuation)
            )
            armTimeout(timeout) { [weak self] in self?.expireStateWaiter(id) }
        }
        guard satisfied else {
            XCTFail("timed out waiting for a state; saw \(states)", line: line)
            throw WaitTimeout()
        }
    }

    private func armTimeout(_ timeout: Duration, _ expire: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            expire()
        }
    }

    private func expireProcessWaiter(_ id: UUID) {
        guard let index = processWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = processWaiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }

    private func expireStateWaiter(_ id: UUID) {
        guard let index = stateWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = stateWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

@MainActor
final class ClaudeRemoteForwardSupervisorTests: XCTestCase {
    private func configuration(
        maxConsecutiveFailures: Int = 5
    ) -> ClaudeRemoteForwardSupervisor.Configuration {
        ClaudeRemoteForwardSupervisor.Configuration(
            hostID: "habc1234",
            sshHostAlias: "builder",
            remoteForwardPort: 28511,
            listenerPort: 8473,
            maxConsecutiveFailures: maxConsecutiveFailures,
            settleDelay: .seconds(2)
        )
    }

    // MARK: Command shape

    func testTheForwardExitsRatherThanRunWithoutItsBind() {
        // The enrollment ssh block sets `ExitOnForwardFailure no` on purpose —
        // a dictation nicety must never cost the user a shell. This process IS
        // the nicety, so the opposite is right: a forward that cannot bind has
        // no reason to stay connected, and its exit is the detection signal.
        let argv = configuration().argv
        XCTAssertTrue(argv.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(argv.contains("BatchMode=yes"))
        XCTAssertTrue(argv.contains("-N"), "a forward holder must not run a remote command")
        XCTAssertTrue(argv.contains("-R"))
        XCTAssertTrue(argv.contains("28511:127.0.0.1:8473"))
        XCTAssertTrue(argv.contains("ServerAliveInterval=30"))
        XCTAssertTrue(argv.contains("ServerAliveCountMax=3"))
    }

    func testInheritedForwardingsAreClearedSoTheProcessCannotFightItself() {
        // The user's ssh config block for this alias already declares the same
        // RemoteForward. Inheriting it would make this process request the port
        // twice — and the second request failing kills it, under the
        // ExitOnForwardFailure=yes above.
        XCTAssertTrue(configuration().argv.contains("ClearAllForwardings=yes"))
    }

    func testTheAliasIsTheLastArgumentAndOptionParsingIsTerminated() {
        let argv = configuration().argv
        XCTAssertEqual(argv.last, "builder")
        XCTAssertEqual(argv[argv.count - 2], "--", "an alias must never be readable as an option")
        XCTAssertFalse(
            argv.joined(separator: " ").lowercased().contains("token"),
            "no credential exists on this path"
        )
    }

    // MARK: Lifecycle

    func testAStableTunnelReportsUpAfterTheSettleWindow() async throws {
        let harness = ForwardHarness()
        let supervisor = harness.makeSupervisor(configuration: configuration())
        supervisor.start()

        _ = try await harness.process(0)
        try await harness.waitForState { $0 == .forwarding }
        XCTAssertEqual(supervisor.state, .forwarding)
        XCTAssertEqual(harness.sleeps, [.seconds(2)], "the settle window uses the injected clock")
    }

    func testARefusedBindIsTerminalAndNeverRestarts() async throws {
        // The whole point: something else holds that port (issue #215) and will
        // keep holding it. Retrying on a timer would be a connection storm the
        // user never sees the cause of.
        let harness = ForwardHarness()
        let supervisor = harness.makeSupervisor(configuration: configuration())
        supervisor.start()

        let process = try await harness.process(0)
        process.emitStandardError(
            "Warning: remote port forwarding failed for listen port 28511"
        )
        process.finish(status: 255)

        try await harness.waitForState { $0 == .portUnavailable }
        XCTAssertEqual(supervisor.state, .portUnavailable)
        XCTAssertEqual(harness.processes.count, 1, "a refused bind must not be retried")
        XCTAssertFalse(
            harness.states.contains { if case .retrying = $0 { return true } else { return false } },
            "a refusal is not a crash: \(harness.states)"
        )
        XCTAssertTrue(supervisor.state.isFailure)
        XCTAssertEqual(supervisor.state.text, "Port already held on the host.")
        XCTAssertLessThan(supervisor.state.text.count, 60, "owner rule: one short sentence")
    }

    func testAnOrdinaryExitRestartsWithExponentialBackoff() async throws {
        let harness = ForwardHarness()
        let supervisor = harness.makeSupervisor(configuration: configuration())
        supervisor.start()

        // A dropped connection: ssh dies with no forwarding complaint.
        let first = try await harness.process(0)
        first.emitStandardError("Connection to builder closed by remote host.")
        first.finish(status: 255)

        try await harness.waitForState { $0 == .retrying(attempt: 1) }
        let second = try await harness.process(1)
        second.finish(status: 255)
        try await harness.waitForState { $0 == .retrying(attempt: 2) }
        _ = try await harness.process(2)

        // 2s settle, 0.5s backoff, 2s settle, 1s backoff — the backoff doubles,
        // exactly like the backend supervisor's. The prefix, not the whole
        // array: the third launch's settle sleep is recorded by the supervise
        // loop after this point, and asserting it here would be asserting on a
        // race rather than on the backoff.
        XCTAssertEqual(
            Array(harness.sleeps.prefix(4)),
            [.seconds(2), .milliseconds(500), .seconds(2), .seconds(1)],
            "\(harness.sleeps)"
        )
    }

    func testAProcessThatDiesInsideItsSettleWindowIsNeverReportedAsUp() async throws {
        // The settle task sleeps on the injected clock and only then calls the
        // tunnel up. Hold that sleep open, kill the process underneath it, and
        // wake the sleep while the supervise loop is still parked on its
        // backoff — so the loop has NOT yet cancelled the stale settle task.
        // Cancellation alone would only usually win that race; the per-launch
        // generation is what makes it impossible. Without it, the pane gets
        // "Tunnel up." painted over the `.retrying` of a dead tunnel.
        let harness = ForwardHarness()
        harness.holdSleeps = true
        let supervisor = harness.makeSupervisor(configuration: configuration())
        supervisor.start()

        let first = try await harness.process(0)   // its settle sleep is now held
        first.finish(status: 255)
        try await harness.waitForState { $0 == .retrying(attempt: 1) }

        // Two sleeps are held now: the dead process's settle, then the backoff.
        // Wake ONLY the settle; the loop stays parked, so nothing has cancelled
        // it and nothing else can have moved the state.
        harness.releaseOldestSleep()
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(
            harness.states.contains(.forwarding),
            "a settle window that outlived its own process must report nothing: \(harness.states)"
        )
        XCTAssertEqual(supervisor.state, .retrying(attempt: 1))
    }

    func testItGivesUpAfterTheConfiguredNumberOfConsecutiveFailures() async throws {
        // An unbounded reconnect loop against someone's SSH server is not a
        // thing to ship, and a tunnel that failed five times running is not one
        // more attempt away from working.
        let harness = ForwardHarness()
        let supervisor = harness.makeSupervisor(configuration: configuration(maxConsecutiveFailures: 3))
        supervisor.start()

        for index in 0..<3 {
            let process = try await harness.process(index)
            process.finish(status: 255)
        }

        try await harness.waitForState { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(harness.processes.count, 3, "it must stop launching, not keep going")
        XCTAssertTrue(supervisor.state.isFailure)
        XCTAssertEqual(supervisor.state.text, "Tunnel stopped.")
    }

    func testStoppingTerminatesTheProcessAndLaunchesNothingMore() async throws {
        let harness = ForwardHarness()
        let supervisor = harness.makeSupervisor(configuration: configuration())
        supervisor.start()
        let process = try await harness.process(0)

        supervisor.stop()

        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertEqual(process.terminateCount, 1)
        // The supervise loop sees the intentional stop and does not treat the
        // terminated process as a crash to restart.
        try await harness.waitForState { $0 == .stopped }
        XCTAssertEqual(harness.processes.count, 1)
        XCTAssertFalse(
            harness.states.contains { if case .retrying = $0 { return true } else { return false } }
        )
    }

    func testStartingTwiceRunsOneProcess() async throws {
        let harness = ForwardHarness()
        let supervisor = harness.makeSupervisor(configuration: configuration())
        supervisor.start()
        _ = try await harness.process(0)
        supervisor.start()
        XCTAssertEqual(harness.processes.count, 1, "start must be idempotent")
    }

    func testALaunchFailureIsReportedAndNotSpunOn() async throws {
        struct Boom: Error {}
        let harness = ForwardHarness()
        let supervisor = harness.makeSupervisor(
            configuration: configuration(), launchFailure: Boom()
        )
        supervisor.start()

        try await harness.waitForState { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(harness.processes.count, 0)
        XCTAssertTrue(supervisor.state.isFailure)
    }

    func testOnlyAFailedForwardCanBeRetried() async throws {
        let harness = ForwardHarness()
        let supervisor = harness.makeSupervisor(configuration: configuration())
        supervisor.start()
        _ = try await harness.process(0)
        try await harness.waitForState { $0 == .forwarding }

        supervisor.retry()
        XCTAssertEqual(
            harness.processes.count, 1,
            "retrying a healthy tunnel would drop the working one for no reason"
        )
    }

    func testBackoffIsExponentialAndCapped() {
        XCTAssertEqual(ClaudeRemoteForwardSupervisor.backoff(attempt: 1), .milliseconds(500))
        XCTAssertEqual(ClaudeRemoteForwardSupervisor.backoff(attempt: 2), .seconds(1))
        XCTAssertEqual(ClaudeRemoteForwardSupervisor.backoff(attempt: 3), .seconds(2))
        XCTAssertEqual(ClaudeRemoteForwardSupervisor.backoff(attempt: 20), .seconds(30))
    }
}
