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

        guard case let .failed(message) = state else {
            return XCTFail("expected failed state, got \(state)")
        }
        XCTAssertTrue(message.contains("port already in use"))
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

        guard case let .failed(message) = state else {
            return XCTFail("expected failed state, got \(state)")
        }
        XCTAssertTrue(message.contains("did not become ready"))
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

        guard case let .failed(message) = state else {
            return XCTFail("expected failed state, got \(state)")
        }
        XCTAssertTrue(message.contains("fatal backend failure"), message)
        XCTAssertEqual(try readCount(from: countFile), 3)
        XCTAssertEqual(
            sleeps.recordedDurations.filter { $0 >= .milliseconds(500) },
            [.milliseconds(500), .seconds(1)]
        )
    }

    func testStopHonorsTERMWithoutRestarting() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let termMarker = directory.appendingPathComponent("term")
        let readyMarker = directory.appendingPathComponent("ready")
        let script = try writeScript(
            in: directory,
            name: "backend.sh",
            body: """
            #!/bin/sh
            trap 'touch "\(termMarker.path)"; exit 0' TERM
            touch "\(readyMarker.path)"
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

    func sleep(_ duration: Duration) async throws {
        if duration == .milliseconds(10) {
            for _ in 0 ..< 1_000 {
                if FileManager.default.fileExists(atPath: readyMarker.path) {
                    return
                }
                await Task.yield()
            }
            return
        }

        if duration == .milliseconds(100) {
            for _ in 0 ..< 1_000 {
                if FileManager.default.fileExists(atPath: termMarker.path) {
                    return
                }
                await Task.yield()
            }
            return
        }

        try await controlledSleep.sleep(duration)
    }

    func resumeAll() {
        controlledSleep.resumeAll()
    }
}
