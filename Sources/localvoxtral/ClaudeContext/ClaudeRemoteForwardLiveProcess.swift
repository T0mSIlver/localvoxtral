import Foundation
import Synchronization

/// The production `ClaudeRemoteForwardProcess`: a real `ssh -N -R`.
///
/// Everything interesting about this type is in what it guarantees to the
/// supervisor, because the supervisor's logic is only sound if these hold:
///
/// 1. `standardErrorLines` FINISHES when the process exits. The supervisor
///    awaits that finish before it reads the exit status, so a stream that
///    never ends is a supervisor that never restarts.
/// 2. stderr is read with `POSIXPipeRead`, never `FileHandle.availableData` —
///    the latter raises an uncatchable ObjC exception on a descriptor error and
///    aborts the app (field crash, PR #60).
/// 3. `terminate()` is idempotent and safe after exit.
///
/// No token is involved on this path, so there is nothing here to redact.
final class ClaudeRemoteForwardLiveProcess: ClaudeRemoteForwardProcess, @unchecked Sendable {
    private let process: Process
    private let stderrPipe: Pipe
    private let continuation: AsyncStream<String>.Continuation
    let standardErrorLines: AsyncStream<String>

    /// Status and waiters under ONE lock. Two locks would leave a window in
    /// which `waitUntilExit` sees no status, the termination handler drains an
    /// empty waiter list, and the waiter registered a microsecond later is
    /// never resumed — a supervisor hung forever on a process that already
    /// exited.
    private struct ExitState {
        var status: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
    }

    private let exitState = Mutex(ExitState())
    private let partialLine = Mutex<String>("")
    private let descriptor: Int32

    /// The spawned child's pid, for the pid ledger that lets the NEXT launch
    /// find this process should this one die without tearing it down.
    var processIdentifier: pid_t { process.processIdentifier }

    /// - Parameter argv: complete, including `ssh` at index 0 (the shape
    ///   `Configuration.argv` produces and the enrollment service already uses).
    init(argv: [String], sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")) throws {
        precondition(!argv.isEmpty)
        let (stream, continuation) = AsyncStream<String>.makeStream(of: String.self)
        standardErrorLines = stream
        self.continuation = continuation

        process = Process()
        process.executableURL = sshExecutableURL
        process.arguments = Array(argv.dropFirst())
        stderrPipe = Pipe()
        process.standardError = stderrPipe
        // ssh -N produces no stdout; discarding it keeps the app out of the
        // business of draining a pipe nobody reads (a full pipe would block
        // the child forever).
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let stderrDescriptor = stderrPipe.fileHandleForReading.fileDescriptor
        descriptor = stderrDescriptor
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = POSIXPipeRead.nextChunk(fromDescriptor: stderrDescriptor)
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.ingest(data)
        }

        process.terminationHandler = { [weak self] finished in
            self?.finish(status: finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            continuation.finish()
            throw error
        }
        Log.claudeContext.info(
            "Claude remote forward spawned: \(argv.joined(separator: " "), privacy: .public)"
        )
    }

    private func ingest(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines: [String] = partialLine.withLock { partial in
            var buffer = partial + text
            var complete: [String] = []
            while let newline = buffer.firstIndex(of: "\n") {
                complete.append(String(buffer[buffer.startIndex..<newline]))
                buffer = String(buffer[buffer.index(after: newline)...])
            }
            partial = buffer
            return complete
        }
        for line in lines where !line.isEmpty {
            continuation.yield(line)
        }
    }

    /// Called once, from the termination handler. Flushes a trailing partial
    /// line — OpenSSH's forwarding warning is the LAST thing it prints before
    /// exiting under `ExitOnForwardFailure=yes`, so dropping an unterminated
    /// tail would lose exactly the line that matters.
    private func finish(status: Int32) {
        // Drain what the pipe still holds BEFORE closing the stream. The
        // termination handler can fire before the readability handler has been
        // scheduled for the last chunk, and that last chunk is precisely
        // `remote port forwarding failed` — the line ssh prints immediately
        // before exiting. Losing it would turn a diagnosable refusal into an
        // ordinary crash-restart loop. `POSIXPipeRead` returns empty on EOF and
        // on any error, so this terminates either way.
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        while true {
            let remaining = POSIXPipeRead.nextChunk(fromDescriptor: descriptor)
            if remaining.isEmpty { break }
            ingest(remaining)
        }
        let tail = partialLine.withLock { partial -> String in
            defer { partial = "" }
            return partial
        }
        if !tail.isEmpty { continuation.yield(tail) }
        continuation.finish()
        let waiters = exitState.withLock { state -> [CheckedContinuation<Int32, Never>] in
            state.status = status
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    func waitUntilExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            // Check-and-register in ONE critical section, so an exit that lands
            // between the two cannot strand this waiter.
            let alreadyExited = exitState.withLock { state -> Int32? in
                if let status = state.status { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let alreadyExited { continuation.resume(returning: alreadyExited) }
        }
    }

    func terminate() {
        signal(SIGTERM)
    }

    func forceTerminate() {
        signal(SIGKILL)
    }

    /// Signal the child — its whole process GROUP when it has one of its own,
    /// otherwise just the child.
    ///
    /// The conditional is not caution for its own sake, it is the difference
    /// between killing ssh and killing localvoxtral. `Process` gives a child
    /// OUR process group unless something changes it, and `kill(-pgid, …)` on
    /// that shared group signals this app (and every other child it has
    /// spawned: both MLX helpers). Foundation exposes no way to make the child
    /// a group leader, so instead of assuming either way this asks the kernel
    /// at signal time: a group of its own gets the group signal — which is what
    /// reaches any `ProxyCommand`/`askpass` helper ssh started — and a shared
    /// group gets a signal aimed at the one pid we know is ours to end.
    ///
    /// `ForkAfterAuthentication=no` and `ControlPath=none` in the argv are the
    /// other half: they stop ssh from leaving descendants that outlive the pid
    /// we track in the first place.
    private func signal(_ signalNumber: Int32) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let childGroup = getpgid(pid)
        let ownGroup = getpgid(0)
        if childGroup > 0, childGroup != ownGroup {
            _ = Darwin.kill(-childGroup, signalNumber)
        } else {
            _ = Darwin.kill(pid, signalNumber)
        }
    }
}
