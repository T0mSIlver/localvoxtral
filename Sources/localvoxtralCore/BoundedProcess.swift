#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Runs one child process with a hard deadline and an output cap: the one
/// process engine for git, quick capture, project terms, the `claude` CLI and
/// every remote setup ssh. Launch, the cap, the deadline, exit observation and
/// the SIGTERM-then-SIGKILL teardown live here once, because each copy of them
/// was a copy of the same bugs (#1881 patched quit into three).
///
/// Load-bearing:
///
/// * **`POSIXPipeRead`, never `FileHandle.availableData` or
///   `readDataToEndOfFile`.** Every `FileHandle` read raises an uncatchable
///   ObjC exception on a descriptor error and takes the app down (#60).
/// * **Each read is gated on `poll()`.** `POSIXPipeRead.nextChunk` blocks until
///   bytes arrive, so a deadline checked only between chunks would never fire
///   for the case that matters most: a child that hangs without printing.
/// * **Every wait is bounded, the teardown's included.** Exit is observed
///   through `terminationHandler` and a semaphore, never `waitUntilExit()`,
///   which also spins the run loop (the login-shell probe runs on the main
///   thread inside a SwiftUI update, and re-entering it crashed on macOS 26).
/// * **`children` owns the child while it runs** (#1225, #1875): the deadline
///   lives in this loop, which ends with the app, so quit stops the child
///   through `terminateAll`.
package enum BoundedProcess {
    package struct Output: Sendable {
        /// Everything read, including a partial read on a timeout or overrun.
        package let data: Data
        /// Meaningful only when `reaped`.
        package let exitCode: Int32
        package let timedOut: Bool
        package let capped: Bool
        /// False when the child outlived SIGKILL and the run gave up on it.
        package let reaped: Bool

        package init(data: Data, exitCode: Int32, timedOut: Bool, capped: Bool, reaped: Bool = true) {
            self.data = data
            self.exitCode = exitCode
            self.timedOut = timedOut
            self.capped = capped
            self.reaped = reaped
        }
    }

    package enum StandardInput: Sendable {
        /// `/dev/null`: a command that would prompt fails fast instead of
        /// waiting on a stdin nobody writes (`claude -p` waits 3 s otherwise).
        case null
        /// Written into a pipe, then closed.
        case bytes(Data)
    }

    /// The most stdin written into the pipe before launch. Past the kernel
    /// pipe buffer that write would block with no child to drain it, so a
    /// larger input is fed from a writer thread after launch.
    package static let standardInputPreloadBytes = 8 * 1024

    /// How long a child that hit the deadline or the cap gets to exit on
    /// SIGTERM before SIGKILL, unless the caller says otherwise.
    static let defaultGracePeriod: TimeInterval = 1.0

    /// Hops to a background queue so the blocking run never touches the
    /// calling actor. Nil when the process could not be launched, or did not
    /// exit even after SIGKILL.
    package static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String? = nil,
        timeoutSeconds: TimeInterval,
        maxBytes: Int,
        label: String,
        children: BoundedProcessChildren = .shared
    ) async -> Output? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Output?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let output: Output
                do {
                    output = try runSynchronously(
                        executableURL: executableURL,
                        arguments: arguments,
                        environment: environment,
                        currentDirectory: currentDirectory,
                        timeoutSeconds: timeoutSeconds,
                        maxBytes: maxBytes,
                        label: label,
                        children: children
                    )
                } catch {
                    Log.polishing.info("\(label, privacy: .public): failed to launch")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: output.reaped ? output : nil)
            }
        }
    }

    /// Blocks the calling thread until the child exits, the deadline passes
    /// or the output passes `maxBytes`; throws only when the child could not
    /// be launched. A `nil` environment inherits this process's.
    package static func runSynchronously(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String? = nil,
        standardInput: StandardInput = .null,
        mergingStandardError: Bool = false,
        timeoutSeconds: TimeInterval,
        maxBytes: Int,
        gracePeriod: TimeInterval = defaultGracePeriod,
        label: String,
        children: BoundedProcessChildren = .shared
    ) throws -> Output {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = mergingStandardError ? output : FileHandle.nullDevice

        var deferredInput: (pipe: Pipe, data: Data)?
        switch standardInput {
        case .null:
            process.standardInput = FileHandle.nullDevice
        case .bytes(let data):
            let input = Pipe()
            process.standardInput = input
            if data.count <= standardInputPreloadBytes {
                // Written before launch, so input that may carry a token is
                // never written after a child could close its pipe.
                try input.fileHandleForWriting.write(contentsOf: data)
                try input.fileHandleForWriting.close()
            } else {
                deferredInput = (input, data)
            }
        }

        // Armed before run() so the exit can never be missed, and read
        // through a semaphore so every wait below can carry a deadline.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { finished in
            children.unregister(finished.processIdentifier)
            exited.signal()
        }
        try process.run()
        let pid = children.adopt(process, label: label)
        defer { children.unregister(pid) }
        if let deferredInput { startWriter(deferredInput.data, into: deferredInput.pipe) }

        /// True when the child exited inside `window`.
        func waitForExit(_ window: TimeInterval) -> Bool {
            exited.wait(timeout: .now() + max(window, 0)) == .success
        }

        let descriptor = output.fileHandleForReading.fileDescriptor
        let deadline = DispatchTime.now() + max(timeoutSeconds, 0)
        var collected = Data()
        var timedOut = false
        var capped = false

        // Drain until EOF. The child holds the only other write end, so EOF
        // arrives when it exits.
        while true {
            let remaining = seconds(until: deadline)
            if remaining <= 0 {
                timedOut = true
                break
            }
            var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptorPoll, 1, Int32(min((remaining * 1_000).rounded(.up), Double(Int32.max))))
            if ready < 0 {
                if errno == EINTR { continue }
                break // An unusable pipe reads as EOF, as in POSIXPipeRead.
            }
            if ready == 0 {
                timedOut = true
                break
            }
            let chunk = POSIXPipeRead.nextChunk(fromDescriptor: descriptor)
            if chunk.isEmpty { break } // EOF or read error: both mean stop.
            collected.append(chunk)
            if collected.count > maxBytes {
                // Nothing drains the pipe after this, so a child that keeps
                // writing blocks on a full buffer, and one that also ignores
                // SIGTERM stays there: hence the SIGKILL below.
                capped = true
                break
            }
        }

        // EOF is not proof of exit (a child can close its pipes and live on,
        // or leave a grandchild holding them), so this wait carries the same
        // deadline as the drain.
        if !timedOut, !capped, !waitForExit(seconds(until: deadline)) { timedOut = true }

        var reaped = true
        if timedOut || capped {
            let outcome = terminateBounded(
                gracePeriod: gracePeriod,
                terminate: { if process.isRunning { process.terminate() } },
                kill: {
                    // Only signal a child Foundation has not reaped yet: once
                    // reaped, the pid can be recycled onto an innocent process.
                    let pid = process.processIdentifier
                    if pid > 0, process.isRunning { _ = kill(pid, SIGKILL) }
                },
                waitForExit: waitForExit
            )
            if outcome == .abandonedAfterKill {
                // A child in uninterruptible disk-wait can survive SIGKILL;
                // waiting longer would wedge the caller, and the kernel reaps
                // it without us.
                Log.polishing.info("\(label, privacy: .public): did not exit after kill; abandoning")
                reaped = false
            }
        }

        return Output(
            data: collected,
            exitCode: reaped ? process.terminationStatus : -1,
            timedOut: timedOut,
            capped: capped,
            reaped: reaped
        )
    }

    /// Feeds stdin too large to preload. Raw `write(2)` on a descriptor with
    /// `F_SETNOSIGPIPE`, so a child that closes its end early costs an `EPIPE`
    /// the thread swallows, never a signal or the `FileHandle` exception this
    /// repo bans. Killing the child ends the writer.
    private static func startWriter(_ data: Data, into pipe: Pipe) {
        // Our copy of the read end: left open, a child that exits early would
        // never turn the writer's next write into EPIPE.
        try? pipe.fileHandleForReading.close()
        let writer = pipe.fileHandleForWriting
        Thread {
            let descriptor = writer.fileDescriptor
            POSIXSocket.suppressSIGPIPE(onPipe: descriptor)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = LibC.write(descriptor, base.advanced(by: offset), raw.count - offset)
                    if written < 0, errno == EINTR { continue }
                    if written <= 0 { return } // EPIPE: the child is gone.
                    offset += written
                }
            }
            try? writer.close()
        }.start()
    }

    private static func seconds(until deadline: DispatchTime) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        let end = deadline.uptimeNanoseconds
        return end > now ? TimeInterval(end - now) / 1_000_000_000 : 0
    }

    /// What it took to stop a child.
    package enum TerminationOutcome: Sendable, Equatable {
        /// Exited inside the grace period after SIGTERM. Nothing was killed.
        case exitedOnTerminate
        /// Outlived SIGTERM; SIGKILL ended it and it was reaped.
        case killed
        /// Still not gone after SIGKILL and a second grace period (a child stuck
        /// in an uninterruptible wait). We stop waiting — blocking past this
        /// point is the wedge, and the OS finishes the kill without us.
        case abandonedAfterKill
    }

    /// SIGTERM, bounded wait, SIGKILL, bounded wait. No unbounded wait anywhere.
    ///
    /// Every seam is injected so the TERM-ignoring path is provable without a
    /// real process or a real clock: `waitForExit` returns true when the child
    /// exited inside the window it was given.
    package static func terminateBounded(
        gracePeriod: TimeInterval,
        terminate: () -> Void,
        kill: () -> Void,
        waitForExit: (TimeInterval) -> Bool
    ) -> TerminationOutcome {
        terminate()
        if waitForExit(gracePeriod) { return .exitedOnTerminate }
        kill()
        if waitForExit(gracePeriod) { return .killed }
        return .abandonedAfterKill
    }
}
