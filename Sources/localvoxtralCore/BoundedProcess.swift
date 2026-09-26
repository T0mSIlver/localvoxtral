#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// Runs one child process off the main actor with a hard timeout and an output
/// cap, reading stdout with `POSIXPipeRead` (never `FileHandle.availableData`,
/// which raises an uncatchable ObjC exception on descriptor errors —
/// AGENTS.md, PR #60). Stdin is `/dev/null` and stderr is discarded.
///
/// The one process entry point for `RepoGitRunner` and the project-terms run
/// (`ProjectTermProposalProcessRunner`): the bounded reader thread, the
/// cap/timeout escalation (SIGTERM then SIGKILL) and the bounded final wait
/// are subtle enough that a second copy would be a second set of the bugs this
/// one already fixed.
package enum BoundedProcess {
    package struct Output: Sendable {
        package let data: Data
        package let exitCode: Int32
        package let timedOut: Bool
        package let capped: Bool

        package init(data: Data, exitCode: Int32, timedOut: Bool, capped: Bool) {
            self.data = data
            self.exitCode = exitCode
            self.timedOut = timedOut
            self.capped = capped
        }
    }

    /// Hops to a background queue so the blocking run never touches the
    /// calling actor. Nil when the process could not be launched, or did not
    /// exit even after SIGKILL.
    package static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String? = nil,
        timeoutSeconds: TimeInterval,
        maxBytes: Int,
        label: String
    ) async -> Output? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Output?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: runBlocking(
                        executableURL: executableURL,
                        arguments: arguments,
                        environment: environment,
                        currentDirectory: currentDirectory,
                        timeoutSeconds: timeoutSeconds,
                        maxBytes: maxBytes,
                        label: label
                    )
                )
            }
        }
    }

    private static func runBlocking(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String?,
        timeoutSeconds: TimeInterval,
        maxBytes: Int,
        label: String
    ) -> Output? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        // A command that would prompt fails fast instead of waiting on a
        // stdin nobody writes (`claude -p` waits 3 s for one otherwise).
        process.standardInput = FileHandle.nullDevice
        // Exit is observed via terminationHandler + semaphore so the final
        // wait can be BOUNDED (see below). Set before run() so the signal can
        // never be missed, even for a process that exits instantly.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            Log.polishing.info("\(label, privacy: .public): failed to launch")
            return nil
        }

        // The reader thread owns the pipe fd and only mutates the mutex-guarded
        // collector; the process handle is touched only from THIS thread, so no
        // non-Sendable state crosses threads.
        let readFD = outPipe.fileHandleForReading.fileDescriptor
        let collector = Mutex<(data: Data, capped: Bool)>((Data(), false))
        let finished = DispatchSemaphore(value: 0)

        let readerThread = Thread {
            while true {
                let chunk = POSIXPipeRead.nextChunk(fromDescriptor: readFD)
                if chunk.isEmpty { break }
                let reachedCap = collector.withLock { state -> Bool in
                    state.data.append(chunk)
                    if state.data.count >= maxBytes {
                        state.capped = true
                        return true
                    }
                    return false
                }
                if reachedCap { break }
            }
            finished.signal()
        }
        readerThread.stackSize = 1 << 20
        readerThread.start()

        let timedOut = finished.wait(timeout: .now() + timeoutSeconds) == .timedOut
        let capped = collector.withLock { $0.capped }
        if timedOut || capped, process.isRunning {
            // Cap: the reader stopped consuming, so a still-writing process
            // would block forever on a full pipe — a polite SIGTERM suffices
            // (never a raw kill on a possibly-already-exited pid). Timeout:
            // the process ignored its deadline; escalate to SIGKILL so the
            // reader's read(2) sees EOF promptly.
            process.terminate()
            if timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        if timedOut {
            // Only the timeout path still has a live reader thread (blocked in
            // read(2)); the kill closes the pipe's write end so it hits EOF —
            // wait briefly for it to finish before reading the collector. The
            // cap path's reader already exited (its signal was consumed by the
            // first wait above), so waiting again there would burn the whole
            // grace period on a semaphore that can never be signaled.
            _ = finished.wait(timeout: .now() + 0.5)
        }
        // BOUNDED replacement for waitUntilExit(): a child stuck in
        // uninterruptible disk-wait can survive even SIGKILL indefinitely, and
        // an unbounded wait here would wedge the caller. On expiry, abandon:
        // Foundation's process monitor (and, on the timeout path, the reader
        // thread) is deliberately leaked until the kernel eventually reaps the
        // child.
        guard exited.wait(timeout: .now() + 2.0) != .timedOut else {
            Log.polishing.info("\(label, privacy: .public): did not exit after kill; abandoning")
            return nil
        }

        let data = collector.withLock { $0.data }
        return Output(
            data: data,
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            capped: capped
        )
    }
}
