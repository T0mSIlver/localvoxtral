#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// Runs a read-only `git` subcommand off the main actor with hard timeout /
/// output caps. Piping uses `POSIXPipeRead` (never `FileHandle.availableData`,
/// which raises an uncatchable ObjC exception on descriptor errors —
/// AGENTS.md, PR #60).
///
/// `run` is the single process entry point: the environment isolation, the
/// bounded reader thread, the cap/timeout escalation (SIGTERM then SIGKILL),
/// and the bounded final wait are subtle enough that a second copy would be a
/// second set of the bugs this one already fixed. `lsFiles` and the Claude
/// repo collector (`ClaudeRepoCollector`) are both thin argument lists over it.
package enum RepoGitRunner {
    package struct Output: Sendable {
        package let data: Data
        package let exitCode: Int32
        package let timedOut: Bool
        package let capped: Bool
    }

    /// Async wrapper: hops to a background queue so the blocking Process run
    /// never touches the main actor (the caller is the @MainActor polish Task).
    ///
    /// - Parameter arguments: the subcommand and its flags, WITHOUT the
    ///   leading `-C <root>` — this adds it, so no caller can accidentally run
    ///   git against a directory other than the one it named.
    package static func run(
        arguments: [String],
        root: String,
        timeoutSeconds: TimeInterval = 2.0,
        maxBytes: Int = 2_000_000
    ) async -> Output? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Output?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: runBlocking(
                        arguments: arguments,
                        root: root,
                        timeoutSeconds: timeoutSeconds,
                        maxBytes: maxBytes
                    )
                )
            }
        }
    }

    package static func lsFiles(
        root: String,
        timeoutSeconds: TimeInterval = 2.0,
        maxBytes: Int = 2_000_000
    ) async -> Output? {
        await run(
            arguments: ["ls-files", "-z"],
            root: root,
            timeoutSeconds: timeoutSeconds,
            maxBytes: maxBytes
        )
    }

    private static func runBlocking(
        arguments: [String],
        root: String,
        timeoutSeconds: TimeInterval,
        maxBytes: Int
    ) -> Output? {
        let gitURL = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else {
            Log.polishing.info("git runner: /usr/bin/git not executable")
            return nil
        }

        let process = Process()
        process.executableURL = gitURL
        process.arguments = ["-C", root] + arguments
        // Determinism against user git config: no global/system config (which
        // also pins out hooks/aliases/pagers/`diff.external` — a user's
        // configured external differ or textconv filter would otherwise run
        // arbitrary programs inside what is supposed to be a read-only probe)
        // and never a credential prompt.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        // Exit is observed via terminationHandler + semaphore so the final
        // wait can be BOUNDED (see below). Set before run() so the signal can
        // never be missed, even for a process that exits instantly.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            Log.polishing.info("git runner: git failed to launch")
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
            // the process ignored 2 s of expectations; escalate to SIGKILL so
            // the reader's read(2) sees EOF promptly.
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
        // an unbounded wait here would wedge the polish task and lose the
        // commit. On expiry, abandon: Foundation's process monitor (and, on
        // the timeout path, the reader thread) is deliberately leaked until
        // the kernel eventually reaps the child — vocabulary is best-effort,
        // the commit is not.
        guard exited.wait(timeout: .now() + 2.0) != .timedOut else {
            Log.polishing.info(
                "git runner: git did not exit after kill; abandoning"
            )
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
