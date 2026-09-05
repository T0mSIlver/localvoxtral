import Darwin
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

@MainActor
final class BackendProcessSupervisorTests: XCTestCase {
    func testHappyPathWaitsForReadinessThenRuns() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = try writeScript(
            in: directory,
            name: "backend.sh",
            body: """
            #!/bin/sh
            trap 'exit 0' TERM
            while true; do sleep 1; done
            """
        )
        let probe = LockedValue(false)
        let sleeps = ControlledSleep { $0 == .milliseconds(500) }
        let supervisor = makeSupervisor(
            executableURL: script,
            probe: { _ in probe.value },
            sleepFor: { duration in try await sleeps.sleep(duration) }
        )
        let watcher = StateWatcher(stream: supervisor.stateUpdates)
        defer { watcher.cancel() }

        await supervisor.start()

        _ = try await watcher.waitForState(.waitingForReady)
        probe.value = true
        sleeps.resumeAll()

        _ = try await watcher.waitForState(.running)
        await supervisor.stop()
    }

    func testPreStartProbeTrueFailsWithoutSpawning() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let marker = directory.appendingPathComponent("spawned")
        let script = try writeScript(
            in: directory,
            name: "backend.sh",
            body: """
            #!/bin/sh
            touch "\(marker.path)"
            sleep 10
            """
        )
        let supervisor = makeSupervisor(
            executableURL: script,
            probe: { _ in true },
            sleepFor: { _ in }
        )
        let watcher = StateWatcher(stream: supervisor.stateUpdates)
        defer { watcher.cancel() }

        await supervisor.start()

        let state = try await watcher.waitForState { state in
            if case .failed = state { return true }
            return false
        }

        guard case let .failed(summary, detail) = state else {
            return XCTFail("expected failed state, got \(state)")
        }
        XCTAssertTrue(summary.contains("port already in use"))
        XCTAssertNil(detail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testReadinessTimeoutFailsAndTerminatesChild() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pidFile = directory.appendingPathComponent("pid")
        let script = try writeScript(
            in: directory,
            name: "backend.sh",
            body: """
            #!/bin/sh
            echo $$ > "\(pidFile.path)"
            trap 'exit 0' TERM
            while true; do sleep 1; done
            """
        )
        let sleeps = RecordingSleep()
        let supervisor = makeSupervisor(
            executableURL: script,
            readinessPollInterval: .milliseconds(1),
            readinessTimeout: .milliseconds(2),
            terminationGracePeriod: .milliseconds(1),
            probe: { _ in false },
            sleepFor: { duration in try await sleeps.sleep(duration) }
        )
        let watcher = StateWatcher(stream: supervisor.stateUpdates)
        defer { watcher.cancel() }

        await supervisor.start()
        let state = try await watcher.waitForState { state in
            if case .failed = state { return true }
            return false
        }

        guard case let .failed(summary, detail) = state else {
            return XCTFail("expected failed state, got \(state)")
        }
        XCTAssertTrue(summary.contains("did not become ready"))
        XCTAssertNil(detail)
        if let pid = try readPID(from: pidFile) {
            XCTAssertFalse(isProcessRunning(pid))
        }
    }

    func testCrashRestartsWithBackoffThenRunsWhenReady() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let countFile = directory.appendingPathComponent("count")
        let marker = directory.appendingPathComponent("crashed-once")
        let script = try writeScript(
            in: directory,
            name: "backend.sh",
            body: """
            #!/bin/sh
            count=0
            if [ -f "\(countFile.path)" ]; then
              count=$(cat "\(countFile.path)")
            fi
            count=$((count + 1))
            echo "$count" > "\(countFile.path)"
            if [ "$count" -eq 1 ]; then
              touch "\(marker.path)"
              echo "first crash" >&2
              exit 2
            fi
            trap 'exit 0' TERM
            while true; do sleep 1; done
            """
        )
        let probe = LockedValue(false)
        let sleeps = ControlledSleep { $0 == .milliseconds(500) }
        let countFilePath = countFile.path
        let supervisor = makeSupervisor(
            executableURL: script,
            readinessPollInterval: .milliseconds(10),
            readinessTimeout: .seconds(600),
            maxConsecutiveRestartFailures: 5,
            probe: { _ in
                guard probe.value else { return false }
                let text = (try? String(contentsOfFile: countFilePath, encoding: .utf8)) ?? ""
                let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                return count >= 2
            },
            sleepFor: { duration in try await sleeps.sleep(duration) }
        )
        let watcher = StateWatcher(stream: supervisor.stateUpdates)
        defer { watcher.cancel() }

        await supervisor.start()

        _ = try await watcher.waitForState(.restarting(attempt: 1))
        // .restarting is emitted BEFORE the supervisor requests the backoff
        // sleep; wait for the recorded sleep itself or this assertion races
        // (seen once on the release-gate runner).
        try await sleeps.waitUntilRecorded { $0 == .milliseconds(500) }
        XCTAssertEqual(
            sleeps.recordedDurations.filter { $0 == .milliseconds(500) },
            [.milliseconds(500)]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        probe.value = true
        sleeps.resumeAll()

        _ = try await watcher.waitForState(.running)
        XCTAssertEqual(try readCount(from: countFile), 2)
        await supervisor.stop()
    }

    func testMaxFailuresFailsWithStderrTail() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let countFile = directory.appendingPathComponent("count")
        let script = try writeScript(
            in: directory,
            name: "backend.sh",
            body: """
            #!/bin/sh
            count=0
            if [ -f "\(countFile.path)" ]; then
              count=$(cat "\(countFile.path)")
            fi
            count=$((count + 1))
            echo "$count" > "\(countFile.path)"
            echo "fatal backend failure $count" >&2
            exit 7
            """
        )
        let sleeps = SpawnAwareRecordingSleep(countFile: countFile)
        let supervisor = makeSupervisor(
            executableURL: script,
            readinessPollInterval: .milliseconds(10),
            maxConsecutiveRestartFailures: 3,
            probe: { _ in false },
            sleepFor: { duration in try await sleeps.sleep(duration) }
        )
        let watcher = StateWatcher(stream: supervisor.stateUpdates)
        defer { watcher.cancel() }

        await supervisor.start()
        let state = try await watcher.waitForState { state in
            if case .failed = state { return true }
            return false
        }

        guard case let .failed(summary, optionalDetail) = state else {
            return XCTFail("expected failed state, got \(state)")
        }
        XCTAssertEqual(summary, "test-backend exited 3 consecutive times.")
        let detail = try XCTUnwrap(optionalDetail)
        XCTAssertTrue(detail.contains("fatal backend failure"), detail)
        XCTAssertEqual(try readCount(from: countFile), 3)
        XCTAssertEqual(
            sleeps.recordedDurations.filter { $0 >= .milliseconds(500) },
            [.milliseconds(500), .seconds(1)]
        )
    }

    func testRestartAfterFailureClearsStaleFailedStateSynchronouslyAndCanRun() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let succeedMarker = directory.appendingPathComponent("succeed")
        let readyMarker = directory.appendingPathComponent("ready")
        let script = try writeScript(
            in: directory,
            name: "backend.sh",
            // Same ordering rule as testStopHonorsTERMWithoutRestarting: arm
            // the trap BEFORE announcing readiness. This script had it the
            // other way round, so the supervisor could observe readiness and
            // send TERM while the shell was still between the two lines, with
            // the default disposition in force. Nothing asserted on the
            // difference here, which is exactly why it went unnoticed.
            body: """
            #!/bin/sh
            if [ -f "\(succeedMarker.path)" ]; then
              trap 'exit 0' TERM
              : > "\(readyMarker.path)"
              while true; do sleep 1; done
            fi
            echo "intentional fast failure" >&2
            exit 7
            """
        )
        let supervisor = makeSupervisor(
            executableURL: script,
            readinessPollInterval: .milliseconds(1),
            readinessTimeout: .seconds(5),
            maxConsecutiveRestartFailures: 1,
            probe: { _ in FileManager.default.fileExists(atPath: readyMarker.path) },
            sleepFor: { _ in await Task.yield() }
        )
        let watcher = StateWatcher(stream: supervisor.stateUpdates)
        defer { watcher.cancel() }

        await supervisor.start()
        let failedState = try await watcher.waitForState { state in
            if case .failed = state { return true }
            return false
        }
        guard case .failed = failedState else {
            return XCTFail("expected failed state, got \(failedState)")
        }

        XCTAssertTrue(FileManager.default.createFile(atPath: succeedMarker.path, contents: Data()))
        await supervisor.start()

        XCTAssertNotEqual(supervisor.state, .failed(summary: "intentional fast failure", detail: nil))
        if case .failed = supervisor.state {
            XCTFail("start() must synchronously leave the stale failed state, got \(supervisor.state)")
        }

        _ = try await watcher.waitForState(.running)
        await supervisor.stop()
    }

    func testStopHonorsTERMWithoutRestarting() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let termMarker = directory.appendingPathComponent("term")
        let readyMarker = directory.appendingPathComponent("ready")
        let script = try writeScript(
            in: directory,
            name: "backend.sh",
            // `: > file`, not `touch file`. `touch` is /usr/bin/touch: a fork
            // AND an exec inside the TERM handler, i.e. in the exact window
            // where the supervisor is deciding whether to escalate to SIGKILL.
            // A redirection creates the file in-process, so the child needs one
            // scheduling slice rather than a whole process spawn.
            //
            // ORDER IS LOAD-BEARING: the trap is armed BEFORE the ready marker
            // exists, so "ready" means "this shell will handle TERM itself".
            // Reversed, the supervisor could see readiness and send TERM while
            // the default disposition is still in force, and the child would
            // die without ever running the handler.
            body: """
            #!/bin/sh
            trap ': > "\(termMarker.path)"; exit 0' TERM
            : > "\(readyMarker.path)"
            while true; do sleep 1 & wait $!; done
            """
        )
        let probe = LockedValue(false)
        let sleeps = TerminationAwareSleep(termMarker: termMarker, readyMarker: readyMarker)
        let supervisor = makeSupervisor(
            executableURL: script,
            readinessPollInterval: .milliseconds(10),
            readinessTimeout: .seconds(600),
            probe: { _ in
                probe.value && FileManager.default.fileExists(atPath: readyMarker.path)
            },
            sleepFor: { duration in try await sleeps.sleep(duration) }
        )
        let watcher = StateWatcher(stream: supervisor.stateUpdates)
        defer { watcher.cancel() }

        await supervisor.start()
        _ = try await watcher.waitForState(.waitingForReady)
        probe.value = true
        sleeps.resumeAll()
        _ = try await watcher.waitForState(.running)

        await supervisor.stop()

        _ = try await watcher.waitForState(.stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: termMarker.path))
        XCTAssertFalse(watcher.containsState(.restarting(attempt: 1)))
    }

    func testStopEscalatesToKILLWhenTERMIsIgnored() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pidFile = directory.appendingPathComponent("pid")
        let script = try writeScript(
            in: directory,
            name: "backend.sh",
            body: """
            #!/bin/sh
            echo $$ > "\(pidFile.path)"
            trap '' TERM
            while true; do sleep 1; done
            """
        )
        let probe = LockedValue(false)
        let sleeps = ControlledSleep()
        let supervisor = makeSupervisor(
            executableURL: script,
            terminationGracePeriod: .milliseconds(2),
            probe: { _ in probe.value },
            sleepFor: { duration in try await sleeps.sleep(duration) }
        )
        let watcher = StateWatcher(stream: supervisor.stateUpdates)
        defer { watcher.cancel() }

        await supervisor.start()
        _ = try await watcher.waitForState(.waitingForReady)
        probe.value = true
        sleeps.resumeAll()
        _ = try await watcher.waitForState(.running)

        await supervisor.stop()

        _ = try await watcher.waitForState(.stopped)
        XCTAssertTrue(sleeps.recordedDurations.contains(.milliseconds(2)))
        if let pid = try readPID(from: pidFile) {
            XCTAssertFalse(isProcessRunning(pid))
        }
    }

    private func makeSupervisor(
        executableURL: URL,
        readinessPollInterval: Duration = .milliseconds(500),
        readinessTimeout: Duration = .seconds(5),
        terminationGracePeriod: Duration = .milliseconds(100),
        maxConsecutiveRestartFailures: Int = 5,
        probe: @escaping @Sendable (URL) async -> Bool,
        sleepFor: @escaping @Sendable (Duration) async throws -> Void
    ) -> BackendProcessSupervisor {
        BackendProcessSupervisor(
            configuration: BackendProcessConfiguration(
                name: "test-backend",
                executableURL: executableURL,
                arguments: [],
                environment: ProcessInfo.processInfo.environment,
                readinessURL: URL(string: "http://127.0.0.1:9/ready")!,
                readinessPollInterval: readinessPollInterval,
                readinessTimeout: readinessTimeout,
                terminationGracePeriod: terminationGracePeriod,
                maxConsecutiveRestartFailures: maxConsecutiveRestartFailures
            ),
            probe: probe,
            sleepFor: sleepFor
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackendProcessSupervisorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeScript(in directory: URL, name: String, body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(url.path, 0o755), 0)
        return url
    }

    private func readPID(from url: URL) throws -> pid_t? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func readCount(from url: URL) throws -> Int {
        let text = try String(contentsOf: url, encoding: .utf8)
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func isProcessRunning(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0
    }
}

private final class StateWatcher: @unchecked Sendable {
    private let storage = Mutex(Storage())
    private var task: Task<Void, Never>?

    init(stream: AsyncStream<BackendProcessSupervisor.State>) {
        task = Task {
            for await state in stream {
                self.record(state)
            }
        }
    }

    func waitForState(
        _ expectedState: BackendProcessSupervisor.State,
        timeout: Duration = .seconds(5)
    ) async throws -> BackendProcessSupervisor.State {
        try await waitForState(timeout: timeout) { $0 == expectedState }
    }

    func waitForState(
        timeout: Duration = .seconds(5),
        matching predicate: @escaping @Sendable (BackendProcessSupervisor.State) -> Bool
    ) async throws -> BackendProcessSupervisor.State {
        try await withThrowingTaskGroup(of: BackendProcessSupervisor.State.self) { group in
            group.addTask {
                try await self.wait(matching: predicate)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WaitTimeout()
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func containsState(_ state: BackendProcessSupervisor.State) -> Bool {
        storage.withLock { $0.states.contains(state) }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func record(_ state: BackendProcessSupervisor.State) {
        let continuationsToResume = storage.withLock { storage in
            storage.states.append(state)

            var remaining: [Waiter] = []
            var continuations: [CheckedContinuation<BackendProcessSupervisor.State, Error>] = []
            for waiter in storage.waiters {
                if waiter.predicate(state) {
                    continuations.append(waiter.continuation)
                } else {
                    remaining.append(waiter)
                }
            }
            storage.waiters = remaining
            return continuations
        }

        for continuation in continuationsToResume {
            continuation.resume(returning: state)
        }
    }

    private func wait(
        matching predicate: @escaping @Sendable (BackendProcessSupervisor.State) -> Bool
    ) async throws -> BackendProcessSupervisor.State {
        if let state = storage.withLock({ $0.states.first(where: predicate) }) {
            return state
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state: BackendProcessSupervisor.State? = storage.withLock { storage in
                    if let state = storage.states.first(where: predicate) {
                        return state
                    }
                    storage.waiters.append(
                        Waiter(id: id, predicate: predicate, continuation: continuation)
                    )
                    return nil
                }
                if let state {
                    continuation.resume(returning: state)
                }
            }
        } onCancel: {
            let continuation = storage.withLock { storage in
                guard let index = storage.waiters.firstIndex(where: { $0.id == id }) else {
                    return nil as CheckedContinuation<BackendProcessSupervisor.State, Error>?
                }
                return storage.waiters.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private struct Waiter: Sendable {
        var id: UUID
        var predicate: @Sendable (BackendProcessSupervisor.State) -> Bool
        var continuation: CheckedContinuation<BackendProcessSupervisor.State, Error>
    }

    private struct Storage: Sendable {
        var states: [BackendProcessSupervisor.State] = []
        var waiters: [Waiter] = []
    }
}

private struct WaitTimeout: Error {}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    /// Read-modify-write under one acquisition, for the check-then-set a
    /// separate `get` and `set` cannot express atomically.
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

private final class RecordingSleep: @unchecked Sendable {
    private let durations = LockedValue<[Duration]>([])

    var recordedDurations: [Duration] {
        durations.value
    }

    func sleep(_ duration: Duration) async throws {
        var recorded = durations.value
        recorded.append(duration)
        durations.value = recorded
        await Task.yield()
    }
}

private final class SpawnAwareRecordingSleep: @unchecked Sendable {
    private let durations = LockedValue<[Duration]>([])
    private let countFile: URL
    private let lastObservedCount = LockedValue(0)
    private let awaitingNextSpawn = LockedValue(true)

    init(countFile: URL) {
        self.countFile = countFile
    }

    var recordedDurations: [Duration] {
        durations.value
    }

    func sleep(_ duration: Duration) async throws {
        var recorded = durations.value
        recorded.append(duration)
        durations.value = recorded

        guard duration == .milliseconds(10) else {
            awaitingNextSpawn.value = true
            await Task.yield()
            return
        }

        guard awaitingNextSpawn.value else {
            await Task.yield()
            return
        }

        while !Task.isCancelled {
            let count = currentCount()
            if count > lastObservedCount.value {
                lastObservedCount.value = count
                awaitingNextSpawn.value = false
                return
            }
            await Task.yield()
        }

        throw CancellationError()
    }

    private func currentCount() -> Int {
        guard let text = try? String(contentsOf: countFile, encoding: .utf8) else { return 0 }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

private final class ControlledSleep: @unchecked Sendable {
    private let lock = NSLock()
    private let shouldPause: @Sendable (Duration) -> Bool
    private var durations: [Duration] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private let recordedStream: AsyncStream<Duration>
    private let recordedContinuation: AsyncStream<Duration>.Continuation

    init(shouldPause: @escaping @Sendable (Duration) -> Bool = { _ in true }) {
        self.shouldPause = shouldPause
        (recordedStream, recordedContinuation) = AsyncStream.makeStream(of: Duration.self)
    }

    /// Waits until a sleep matching `matches` has been REQUESTED. State
    /// transitions (e.g. `.restarting`) are emitted before the supervisor
    /// calls `sleepFor`, so tests must synchronize on the recording itself
    /// before asserting `recordedDurations`. Single consumer; yields are
    /// buffered from init, so calls after the fact still see the sleep.
    func waitUntilRecorded(
        timeout: Duration = .seconds(5),
        where matches: @escaping @Sendable (Duration) -> Bool
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await duration in self.recordedStream where matches(duration) {
                    return
                }
                throw WaitTimeout()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WaitTimeout()
            }
            try await group.next()!
            group.cancelAll()
        }
    }

    var recordedDurations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return durations
    }

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            lock.lock()
            durations.append(duration)
            // Yield after the append (still under the lock) so a waiter woken
            // by this yield always observes the duration in recordedDurations.
            recordedContinuation.yield(duration)
            guard !isReleased && shouldPause(duration) else {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func resumeAll() {
        lock.lock()
        isReleased = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()

        for continuation in pending {
            continuation.resume()
        }
    }
}

private final class TerminationAwareSleep: @unchecked Sendable {
    private let controlledSleep = ControlledSleep()
    private let termMarker: URL
    private let readyMarker: URL

    init(termMarker: URL, readyMarker: URL) {
        self.termMarker = termMarker
        self.readyMarker = readyMarker
    }

    // Both arms stand in for a real sleep the supervisor performs while waiting
    // on a REAL child process, so what they must express is "until the child
    // did the thing", not "for a while".
    //
    // They used to spin `for _ in 0 ..< 1_000 { await Task.yield() }` and then
    // RETURN whether or not the marker had appeared. That budget, not any
    // clock, is what decided the test: the supervisor's grace loop is a single
    // 100 ms slice, so when this returned early the very next statement was
    // `if process.isRunning { SIGKILL }` — killing the child before it could
    // run its TERM handler, and `termMarker` never appeared.
    //
    // And 1000 yields is not "a moment": `Task.yield()` only reschedules on the
    // cooperative pool, so with nothing else runnable the whole budget elapses
    // in about a millisecond of wall-clock while spinning a core the child
    // needs. Measured on the hosted lane (3-core shared VM), that lost the race
    // 14 times in 20.
    //
    // So: wait for the actual filesystem event instead. No polling, no spin, no
    // budget to tune — it returns the moment the marker exists and not before.
    // A child that genuinely never writes it hangs the test, which XCTest's own
    // timeout turns into a failure with `run-supervised-command.sh`'s stack
    // sample attached; that is the correct bound and the correct diagnostic,
    // where the old budget silently converted "not yet" into "SIGKILL it".
    func sleep(_ duration: Duration) async throws {
        if duration == .milliseconds(10) {
            await Self.waitForFile(readyMarker)
            return
        }

        if duration == .milliseconds(100) {
            await Self.waitForFile(termMarker)
            return
        }

        try await controlledSleep.sleep(duration)
    }

    /// Returns once `url` exists, driven by a directory write event rather than
    /// by polling.
    private static func waitForFile(_ url: URL) async {
        if FileManager.default.fileExists(atPath: url.path) { return }

        let directory = url.deletingLastPathComponent()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // No watch possible. Fall back to yielding rather than returning
            // immediately, which would reinstate the early-SIGKILL bug.
            while !FileManager.default.fileExists(atPath: url.path) {
                await Task.yield()
            }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib],
            queue: .global()
        )
        let resumed = LockedValue(false)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // One-shot: the event handler can fire more than once (any write to
            // the directory), and the pre-arm check below can race with it.
            let finish: @Sendable () -> Void = {
                var shouldResume = false
                resumed.withLock { alreadyResumed in
                    if !alreadyResumed {
                        alreadyResumed = true
                        shouldResume = true
                    }
                }
                if shouldResume {
                    source.cancel()
                    continuation.resume()
                }
            }
            source.setEventHandler {
                if FileManager.default.fileExists(atPath: url.path) { finish() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            // The marker may have appeared between the check above and the
            // source being armed; that event is gone, so look once more.
            if FileManager.default.fileExists(atPath: url.path) { finish() }
        }
    }

    func resumeAll() {
        controlledSleep.resumeAll()
    }
}
