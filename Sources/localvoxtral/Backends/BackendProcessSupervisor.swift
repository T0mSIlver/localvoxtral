import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class BackendProcessSupervisor {
    enum State: Equatable, Sendable {
        case idle
        case launching
        case waitingForReady
        case running
        case restarting(attempt: Int)
        case stopped
        case failed(summary: String, detail: String?)
    }

    typealias Probe = @Sendable (URL) async -> Bool
    typealias SleepClosure = @Sendable (Duration) async throws -> Void

    private(set) var state: State
    private(set) var recentOutput: [String]
    @ObservationIgnored var stateUpdates: AsyncStream<State> {
        let id = UUID()
        let stream = AsyncStream<State>.makeStream(of: State.self)
        stateContinuations[id] = stream.continuation
        stream.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stateContinuations[id] = nil
            }
        }
        return stream.stream
    }

    @ObservationIgnored private let configuration: BackendProcessConfiguration
    @ObservationIgnored private let probe: Probe
    @ObservationIgnored private let sleepFor: SleepClosure
    @ObservationIgnored private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]

    @ObservationIgnored private var supervisionTask: Task<Void, Never>?
    @ObservationIgnored private var currentProcess: Process?
    @ObservationIgnored private var currentProcessID: pid_t?
    @ObservationIgnored private var currentProcessExited = false
    @ObservationIgnored private var currentTerminationStatus: Int32?
    @ObservationIgnored private var processExitContinuation: CheckedContinuation<Int32, Never>?
    @ObservationIgnored private var stdoutPipe: Pipe?
    @ObservationIgnored private var stderrPipe: Pipe?
    @ObservationIgnored private var stdoutPartial = ""
    @ObservationIgnored private var stderrPartial = ""
    @ObservationIgnored private var recentErrorOutput: [String] = []
    @ObservationIgnored private var stoppingIntentionally = false

    init(
        configuration: BackendProcessConfiguration,
        probe: @escaping Probe = BackendProcessSupervisor.defaultProbe,
        sleepFor: @escaping SleepClosure = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.configuration = configuration
        self.probe = probe
        self.sleepFor = sleepFor
        self.state = .idle
        self.recentOutput = []
    }

    func start() async {
        guard supervisionTask == nil else { return }
        guard !isActiveState(state) else { return }

        stoppingIntentionally = false
        transition(to: .launching)
        supervisionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.supervise()
        }
    }

    func stop() async {
        stoppingIntentionally = true
        supervisionTask?.cancel()

        if let process = currentProcess {
            await terminate(process: process, gracePeriod: configuration.terminationGracePeriod)
        }

        clearCurrentProcess()
        supervisionTask = nil
        transition(to: .stopped)
    }

    private static func defaultProbe(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func supervise() async {
        defer {
            supervisionTask = nil
        }

        guard !(await probe(configuration.readinessURL)) else {
            transition(
                to: .failed(
                    summary: "\(configuration.name) port already in use; refusing to adopt an existing backend process.",
                    detail: nil
                )
            )
            return
        }

        var consecutiveFailures = 0

        while !stoppingIntentionally && !Task.isCancelled {
            transitionIfNeeded(to: .launching)

            do {
                try spawnProcess()
            } catch {
                transition(
                    to: .failed(
                        summary: "Failed to launch \(configuration.name): \(error.localizedDescription)",
                        detail: nil
                    )
                )
                return
            }

            transition(to: .waitingForReady)
            let readinessOutcome = await waitForReadiness()

            switch readinessOutcome {
            case .ready:
                consecutiveFailures = 0
                transition(to: .running)
                _ = await waitForCurrentProcessExit()
                guard !stoppingIntentionally && !Task.isCancelled else { return }
                consecutiveFailures += 1

            case .exited:
                guard !stoppingIntentionally && !Task.isCancelled else { return }
                consecutiveFailures += 1

            case .timedOut:
                let stderrTail = stderrTailDetail()
                if let process = currentProcess {
                    await terminate(process: process, gracePeriod: configuration.terminationGracePeriod)
                }
                clearCurrentProcess()
                transition(
                    to: .failed(
                        summary: "\(configuration.name) did not become ready before timeout.",
                        detail: stderrTail
                    )
                )
                return

            case .cancelled:
                return
            }

            clearCurrentProcess()

            if consecutiveFailures >= max(1, configuration.maxConsecutiveRestartFailures) {
                transition(
                    to: .failed(
                        summary: "\(configuration.name) exited \(consecutiveFailures) consecutive times.",
                        detail: stderrTailDetail()
                    )
                )
                return
            }

            transition(to: .restarting(attempt: consecutiveFailures))

            do {
                try await sleepFor(backoffDuration(attempt: consecutiveFailures))
            } catch {
                return
            }
        }
    }

    private enum ReadinessOutcome {
        case ready
        case exited
        case timedOut
        case cancelled
    }

    private func waitForReadiness() async -> ReadinessOutcome {
        var elapsed: Duration = .zero

        while !stoppingIntentionally && !Task.isCancelled {
            if currentProcessExited || currentProcess?.isRunning == false {
                return .exited
            }

            if await probe(configuration.readinessURL) {
                return .ready
            }

            do {
                try await sleepFor(configuration.readinessPollInterval)
            } catch {
                return .cancelled
            }
            await Task.yield()

            elapsed += configuration.readinessPollInterval
            if currentProcessExited || currentProcess?.isRunning == false {
                return .exited
            }
            if elapsed >= configuration.readinessTimeout {
                return .timedOut
            }
        }

        return .cancelled
    }

    private func spawnProcess() throws {
        clearCurrentProcess()

        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.environment = configuration.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        attachOutputReader(to: stdoutPipe, source: "stdout")
        attachOutputReader(to: stderrPipe, source: "stderr")

        process.terminationHandler = { terminatedProcess in
            let pid = terminatedProcess.processIdentifier
            let status = terminatedProcess.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleProcessExit(pid: pid, status: status)
            }
        }

        try process.run()

        currentProcess = process
        currentProcessID = process.processIdentifier
        currentProcessExited = false
        currentTerminationStatus = nil
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        Log.backends.info(
            "\(self.configuration.name, privacy: .public) backend launched pid=\(process.processIdentifier, privacy: .public)"
        )
    }

    private func attachOutputReader(to pipe: Pipe, source: String) {
        // Capture the raw descriptor while the handle is known-valid;
        // availableData inside the handler can raise an uncatchable ObjC
        // exception if cleanup() closes the pipe while a callback is in
        // flight (same abort class as the PipeLineReader field crash).
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = POSIXPipeRead.nextChunk(fromDescriptor: descriptor)
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }

            Task { @MainActor [weak self] in
                self?.appendOutput(data: data, source: source)
            }
        }
    }

    private func appendOutput(data: Data, source: String) {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var buffer = (source == "stderr" ? stderrPartial : stdoutPartial) + text
        let endsWithNewline = buffer.hasSuffix("\n")
        var pieces = buffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if endsWithNewline {
            buffer = ""
            _ = pieces.popLast()
        } else {
            buffer = pieces.popLast() ?? ""
        }

        if source == "stderr" {
            stderrPartial = buffer
        } else {
            stdoutPartial = buffer
        }

        for piece in pieces {
            appendOutputLine(piece, source: source)
        }
    }

    private func appendOutputLine(_ rawLine: String, source: String) {
        let line = rawLine.trimmingCharacters(in: .newlines)
        guard !line.isEmpty else { return }

        let formatted = "[\(configuration.name) \(source)] \(line)"
        recentOutput.append(formatted)
        if recentOutput.count > 40 {
            recentOutput.removeFirst(recentOutput.count - 40)
        }

        if source == "stderr" {
            recentErrorOutput.append(line)
            if recentErrorOutput.count > 20 {
                recentErrorOutput.removeFirst(recentErrorOutput.count - 20)
            }
        }

        Log.backends.info("\(formatted, privacy: .public)")
    }

    private func handleProcessExit(pid: pid_t, status: Int32) {
        guard currentProcessID == pid else { return }

        flushOutputPartials()
        currentProcessExited = true
        currentTerminationStatus = status
        let continuation = processExitContinuation
        processExitContinuation = nil
        continuation?.resume(returning: status)

        Log.backends.info(
            "\(self.configuration.name, privacy: .public) backend exited pid=\(pid, privacy: .public) status=\(status, privacy: .public)"
        )
    }

    private func waitForCurrentProcessExit() async -> Int32 {
        if currentProcessExited {
            return currentTerminationStatus ?? 0
        }

        return await withCheckedContinuation { continuation in
            processExitContinuation = continuation
        }
    }

    private func terminate(process: Process, gracePeriod: Duration) async {
        guard process.isRunning else { return }

        process.terminate()

        var elapsed: Duration = .zero
        let sleepSlice = minDuration(.milliseconds(100), gracePeriod)
        while process.isRunning && elapsed < gracePeriod {
            do {
                try await sleepFor(sleepSlice)
            } catch {
                break
            }
            await Task.yield()
            elapsed += sleepSlice
        }

        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }

        var killElapsed: Duration = .zero
        while process.isRunning && killElapsed < .seconds(1) {
            do {
                try await sleepFor(.milliseconds(10))
            } catch {
                break
            }
            await Task.yield()
            killElapsed += .milliseconds(10)
        }
    }

    private func clearCurrentProcess() {
        flushOutputPartials()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        let continuation = processExitContinuation
        processExitContinuation = nil
        continuation?.resume(returning: currentTerminationStatus ?? 0)
        stdoutPipe = nil
        stderrPipe = nil
        currentProcess = nil
        currentProcessID = nil
        currentProcessExited = false
        currentTerminationStatus = nil
        stdoutPartial = ""
        stderrPartial = ""
    }

    private func flushOutputPartials() {
        if !stdoutPartial.isEmpty {
            appendOutputLine(stdoutPartial, source: "stdout")
            stdoutPartial = ""
        }
        if !stderrPartial.isEmpty {
            appendOutputLine(stderrPartial, source: "stderr")
            stderrPartial = ""
        }
    }

    private func transition(to newState: State) {
        state = newState
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
        Log.backends.info(
            "\(self.configuration.name, privacy: .public) backend state \(String(describing: newState), privacy: .public)"
        )
    }

    private func transitionIfNeeded(to newState: State) {
        guard state != newState else { return }
        transition(to: newState)
    }

    private func stderrTailDetail() -> String? {
        guard !recentErrorOutput.isEmpty else { return nil }
        return "stderr: " + recentErrorOutput.suffix(5).joined(separator: "\n")
    }

    private func backoffDuration(attempt: Int) -> Duration {
        let seconds = min(30.0, 0.5 * pow(2.0, Double(max(0, attempt - 1))))
        return .seconds(seconds)
    }

    private func minDuration(_ lhs: Duration, _ rhs: Duration) -> Duration {
        lhs <= rhs ? lhs : rhs
    }

    private func isActiveState(_ state: State) -> Bool {
        switch state {
        case .launching, .waitingForReady, .running, .restarting:
            return true
        case .idle, .stopped, .failed:
            return false
        }
    }
}
