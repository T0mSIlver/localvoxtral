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
    private let forcedTerminations = Mutex(0)

    /// When true, `terminate()` signals and RETURNS — the process keeps
    /// running until the test ends it. A fake that dies synchronously inside
    /// `terminate()` cannot express the case teardown exists for (an ssh that
    /// is slow to die, or ignores SIGTERM entirely), so with that fake every
    /// escalation test passes vacuously.
    let ignoresTermination: Bool

    var terminateCount: Int { terminations.withLock { $0 } }
    var forceTerminateCount: Int { forcedTerminations.withLock { $0 } }
    var hasExited: Bool { exitState.withLock { $0.status != nil } }

    init(ignoresTermination: Bool = false) {
        self.ignoresTermination = ignoresTermination
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
        guard !ignoresTermination else { return }
        finish(status: 143)
    }

    /// SIGKILL: even the stubborn fake cannot survive it, which is the
    /// property the escalation depends on.
    func forceTerminate() {
        forcedTerminations.withLock { $0 += 1 }
        finish(status: 137)
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

    /// Every fake this harness makes ignores SIGTERM, so teardown has to
    /// escalate.
    let processesIgnoreTermination: Bool

    init(processesIgnoreTermination: Bool = false) {
        self.processesIgnoreTermination = processesIgnoreTermination
    }

    /// The supervisor's injected clock. Uptime is what decides whether a drop
    /// counts as part of a run of failures, so a test has to be able to say how
    /// long a connection lasted — without any of it being real time.
    private(set) var clock = Date(timeIntervalSince1970: 1_000_000)

    func advanceClock(by seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    /// Yield until the main actor has nothing left to run.
    ///
    /// A fixed number of `Task.yield()`s is a guess about the scheduler, and a
    /// wrong guess makes a test pass by not letting the buggy code run — which
    /// is exactly how the settle-window regression hid. This keeps yielding
    /// while anything is still making progress, so "nothing more happens" is
    /// something the test observes rather than assumes. Bounded so a live-lock
    /// fails the test instead of hanging the suite.
    func drainMainActor(iterations: Int = 200) async {
        for _ in 0..<iterations { await Task.yield() }
    }

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
                let process = FakeForwardProcess(
                    ignoresTermination: self?.processesIgnoreTermination ?? false
                )
                self?.record(process)
                return process
            },
            sleepFor: { [weak self] duration in
                guard let self else { return }
                await self.recordSleep(duration)
            },
            now: { [weak self] in self?.clock ?? Date(timeIntervalSince1970: 1_000_000) }
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

    /// Waits for the state LIST to reach a length, rather than for a state to
    /// appear.
    ///
    /// `waitForState` answers "has this ever happened", which is the wrong
    /// question once a value can recur: waiting for `.retrying(attempt: 1)`
    /// after an earlier `.retrying(attempt: 1)` returns instantly and the test
    /// then asserts against a sequence that has not been written yet.
    func waitForStateCount(
        _ count: Int, timeout: Duration = .seconds(20), line: UInt = #line
    ) async throws {
        try await waitForState(timeout: timeout, line: line) { [weak self] _ in
            (self?.states.count ?? 0) >= count
        }
    }

    /// Every `.retrying` attempt number recorded so far, in order.
    var retryAttempts: [Int] {
        states.compactMap { state in
            if case .retrying(let attempt) = state { return attempt } else { return nil }
        }
    }

    /// Waits until this many retries have been published.
    ///
    /// Counting RETRIES specifically, because a bare "the list grew" wait wakes
    /// on whatever lands first — and with an instant settle window that is the
    /// `.forwarding` of the connection that just dropped, not the retry the
    /// test is about.
    func waitForRetryCount(
        _ count: Int, timeout: Duration = .seconds(20), line: UInt = #line
    ) async throws {
        try await waitForState(timeout: timeout, line: line) { [weak self] _ in
            (self?.retryAttempts.count ?? 0) >= count
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

    func testNoOptionCanClearTheForwardTheProcessExistsToCreate() {
        // The regression that made this whole feature a no-op. The argv used to
        // carry `ClearAllForwardings=yes` to stop the alias's own RemoteForward
        // being inherited twice — but ssh_config(5) says that option clears
        // forwardings given "in the configuration files or on the command
        // line", so it cleared our `-R` as well. Measured with
        // `ssh -G -F <config> -o ClearAllForwardings=yes -R 28511:… alias`:
        // the effective config contains `clearallforwardings yes` and NO
        // `remoteforward` line, so the supervised ssh connected, settled, and
        // reported "Tunnel up." while forwarding nothing.
        //
        // Asserted as a property — no forwarding-clearing option, whatever it
        // is called — rather than as the absence of one spelling, so a future
        // equivalent cannot walk back in.
        let argv = configuration().argv
        XCTAssertTrue(argv.contains("-R"), "the forward is the entire point of this process")
        XCTAssertTrue(argv.contains("28511:127.0.0.1:8473"))
        let joined = argv.joined(separator: " ").lowercased()
        XCTAssertFalse(
            joined.contains("clearallforwardings"),
            "clearing forwardings also clears the -R: \(argv)"
        )
        XCTAssertFalse(joined.contains("noremoteforward"), argv.description)
    }

    func testTheConnectionCannotDetachMultiplexOrRunALocalCommand() {
        // Every one of these is settable per-Host in the user's own config, and
        // each breaks the supervisor's grip in a different way:
        // ForkAfterAuthentication backgrounds ssh out of the tracked Process
        // (its parent exits, the child keeps the bind and the stderr pipe, and
        // neither disable nor quit can reach it); ControlPersist lets a
        // multiplexed master outlive the process that started it; an inherited
        // LocalCommand runs on this Mac on every reconnect.
        let argv = configuration().argv
        for option in ["ForkAfterAuthentication=no", "ControlPath=none", "PermitLocalCommand=no"] {
            XCTAssertTrue(argv.contains(option), "missing \(option): \(argv)")
            // Options must be passed as `-o value` pairs, not smuggled into the
            // alias or concatenated — the `--` termination only protects the
            // alias.
            let index = try? XCTUnwrap(argv.firstIndex(of: option))
            if let index { XCTAssertEqual(argv[index - 1], "-o") }
        }
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
        // The copy has to name the thing to close. The overwhelmingly common
        // holder is an ssh session from this very Mac, and "Port already held
        // on the host." left the user with a Retry button and no idea what to
        // do before pressing it.
        XCTAssertEqual(supervisor.state.text, "Port held — close ssh sessions to that host.")
        XCTAssertLessThan(supervisor.state.text.count, 60, "owner rule: one short sentence")
    }

    func testARefusalForAPortWeNeverAskedForBlamesTheConfigNotTheHost() async throws {
        // The #215 migration cohort: the alias's ssh config block still
        // declares `RemoteForward 8473 …` from before per-Mac ports. Dropping
        // ClearAllForwardings (which had to go — it cleared our own `-R`) means
        // that stale forward IS inherited, and under ExitOnForwardFailure=yes
        // its refusal kills the process. Verified with `ssh -G`: a legacy block
        // plus our `-R 28511` yields BOTH `remoteforward 28511` and
        // `remoteforward 8473`.
        //
        // Reporting that as "port held" would send the user hunting for a
        // process on the remote host that does not exist. The fix is in their
        // own ~/.ssh/config.
        let harness = ForwardHarness()
        let supervisor = harness.makeSupervisor(configuration: configuration())
        supervisor.start()

        let process = try await harness.process(0)
        process.emitStandardError(
            "Warning: remote port forwarding failed for listen port 8473"
        )
        process.finish(status: 255)

        try await harness.waitForState {
            if case .staleConfiguredForward = $0 { return true } else { return false }
        }
        XCTAssertEqual(supervisor.state, .staleConfiguredForward(port: 8473))
        XCTAssertTrue(supervisor.state.isFailure, "it cannot fix itself by retrying")
        XCTAssertEqual(harness.processes.count, 1, "and it must not retry")
        XCTAssertEqual(supervisor.state.text, "Old RemoteForward in ~/.ssh/config blocks this.")
        XCTAssertLessThan(supervisor.state.text.count, 60, "owner rule: one short sentence")
    }

    func testTheRefusedPortIsReadFromTheWarningNotGuessed() {
        // `listen port` anchors it: the same line carries host names, and a
        // hostname with digits must never be read as a port.
        XCTAssertEqual(
            ClaudeRemoteForwardSupervisor.refusedPort(
                in: "warning: remote port forwarding failed for listen port 28511"
            ),
            28511
        )
        XCTAssertNil(
            ClaudeRemoteForwardSupervisor.refusedPort(in: "remote port forwarding failed")
        )
        XCTAssertNil(ClaudeRemoteForwardSupervisor.refusedPort(in: "connection to host99 closed"))
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

        // Wake the dead process's settle window while the loop is still parked
        // on its backoff, so nothing has left the loop-body scope and the old
        // `defer { settle.cancel() }` has not run.
        harness.releaseOldestSleep()
        // Drain the main actor until it is quiet. TWO yields used to be enough
        // to make this test pass — and that was the whole reason it passed:
        // the stale settle task simply had not been scheduled yet. Measured
        // with an instrumented copy of this scenario, at 50 yields the old code
        // published `.forwarding` on top of `.retrying(1)` and the final state
        // was `forwarding`. Waiting for quiescence is what turns this from a
        // test of the scheduler into a test of the guard.
        await harness.drainMainActor()

        XCTAssertFalse(
            harness.states.contains(.forwarding),
            "a settle window that outlived its own process must report nothing: \(harness.states)"
        )
        XCTAssertEqual(supervisor.state, .retrying(attempt: 1))
    }

    func testADropAfterALongHealthyRunIsNotPartOfARunOfFailures() async throws {
        // `consecutiveFailures` never reset, so failures accumulated for the
        // life of the supervisor. Five drops spread over five days — a laptop
        // closing its lid five times — hit the cap and stopped the tunnel for
        // good with "keeps dropping", each retry inheriting a backoff computed
        // from failures that had nothing to do with each other.
        let harness = ForwardHarness()
        let supervisor = harness.makeSupervisor(
            configuration: configuration(maxConsecutiveFailures: 3)
        )
        supervisor.start()

        // Two quick drops: no uptime between them, so they DO accumulate.
        for index in 0..<2 {
            let process = try await harness.process(index)
            process.finish(status: 255)
            try await harness.waitForState { $0 == .retrying(attempt: index + 1) }
        }

        // The third connection stays up for an hour before dropping.
        let healthy = try await harness.process(2)
        harness.advanceClock(by: 3600)
        healthy.finish(status: 255)

        // So it is failure number ONE again — not number three, which under a
        // cap of 3 would have been terminal. Waited for by RETRY COUNT: an
        // earlier `.retrying(attempt: 1)` is already in the list, so waiting
        // for that VALUE returns before this drop is processed, and waiting for
        // the list merely to grow wakes on this connection's own `.forwarding`.
        try await harness.waitForRetryCount(3)
        // Asserted on the RECORDED sequence, not on `supervisor.state`: the
        // backoff is instant on the injected clock, so the loop has usually
        // relaunched into `.connecting` by the time the test looks.
        XCTAssertEqual(
            harness.retryAttempts, [1, 2, 1],
            "the drop after an hour of uptime must restart the count: \(harness.states)"
        )
        XCTAssertFalse(
            harness.states.contains { if case .failed = $0 { return true } else { return false } },
            "a tunnel that ran for an hour must not be given up on: \(harness.states)"
        )
    }

    func testConnectionsThatDieQuicklyStillHitTheCap() async throws {
        // The other half of the rule, and the reason "healthy" is not "survived
        // the 2s settle window": a tunnel that connects, holds briefly and dies
        // — over and over — is the reconnect storm the cap exists to stop. If
        // merely settling reset the counter, the cap would be unreachable.
        let harness = ForwardHarness()
        let supervisor = harness.makeSupervisor(
            configuration: configuration(maxConsecutiveFailures: 3)
        )
        supervisor.start()

        for index in 0..<3 {
            let process = try await harness.process(index)
            // Long enough to settle and be called up, nowhere near healthy.
            harness.advanceClock(by: 3)
            process.finish(status: 255)
        }

        try await harness.waitForState { if case .failed = $0 { return true } else { return false } }
        XCTAssertTrue(supervisor.state.isFailure)
        XCTAssertEqual(harness.processes.count, 3, "it must stop launching, not keep going")
    }

    // MARK: Teardown

    func testStoppingEscalatesToSIGKILLWhenTheProcessIgnoresSIGTERM() async throws {
        // The case the escalation exists for: ssh wedged on a dead network,
        // holding the remote bind. Without it the supervisor sends one SIGTERM,
        // forgets the child, and the port stays bound by a process nothing can
        // reach any more.
        let harness = ForwardHarness(processesIgnoreTermination: true)
        let supervisor = harness.makeSupervisor(configuration: configuration())
        supervisor.start()
        let process = try await harness.process(0)

        supervisor.stop()
        XCTAssertEqual(process.terminateCount, 1, "SIGTERM comes first")
        XCTAssertEqual(process.forceTerminateCount, 0, "and it gets its grace window")
        XCTAssertFalse(process.hasExited)

        await supervisor.teardown?.value

        XCTAssertEqual(process.forceTerminateCount, 1, "the grace window expired: SIGKILL")
        XCTAssertTrue(process.hasExited)
        XCTAssertEqual(supervisor.state, .stopped)
    }

    func testAProcessThatHonoursSIGTERMIsNeverKilled() async throws {
        // The grace window is HELD open for the whole test, so "did it escalate"
        // cannot be answered by the grace expiring first. The only thing that
        // can resolve the wait here is the process exiting — which is exactly
        // the property being asserted.
        let harness = ForwardHarness()
        harness.holdSleeps = true
        let supervisor = harness.makeSupervisor(configuration: configuration())
        supervisor.start()
        let process = try await harness.process(0)

        supervisor.stop()
        await supervisor.teardown?.value

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(
            process.forceTerminateCount, 0,
            "SIGKILL on a process that already exited is a bug, not belt-and-braces"
        )
        XCTAssertTrue(process.hasExited)
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
