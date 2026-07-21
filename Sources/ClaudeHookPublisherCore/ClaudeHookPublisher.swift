import ClaudeContextWire
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(os)
import os
#endif

/// Reads bounded stdin once, enriches with safe process/TTY metadata, and
/// publishes one NDJSON line. Pure logic lives here so the executable's `main`
/// stays a three-liner and every branch below is unit-testable.
///
/// The contract with Claude Code is absolute: **always exit 0, always silent.**
/// A hook that fails loudly, blocks, or writes to stdout can break the user's
/// turn. Dictation context is a nice-to-have; the user's Claude session is not.
public struct ClaudeHookPublisher: Sendable {
    /// Injected seams. Defaults are the real syscalls; tests substitute.
    public struct Environment: Sendable {
        public var now: @Sendable () -> Double
        public var pid: @Sendable () -> Int32
        public var ppid: @Sendable () -> Int32
        /// The controlling-tty resolution for a GIVEN Claude pid. The pid is
        /// an argument — supplied from `ppid()` at `processInfo()` time —
        /// rather than re-resolved inside the default closure, so an injected
        /// `ppid` seam and the published tty always describe the same process.
        /// (The default used to call `claudeAncestorPID()` itself, which let a
        /// test's injected ppid and the tty's process-table fallback silently
        /// diverge.)
        public var ttyName: @Sendable (Int32) -> String?
        public var variables: [String: String]

        public init(
            now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
            pid: @escaping @Sendable () -> Int32 = { getpid() },
            ppid: @escaping @Sendable () -> Int32 = { ClaudeHookPublisher.claudeAncestorPID() },
            ttyName: @escaping @Sendable (Int32) -> String? = {
                ClaudeHookPublisher.controllingTTY(claudePID: $0)
            },
            variables: [String: String] = ProcessInfo.processInfo.environment
        ) {
            self.now = now
            self.pid = pid
            self.ppid = ppid
            self.ttyName = ttyName
            self.variables = variables
        }
    }

    /// What a run did, and what (if anything) to print.
    ///
    /// `stdout` is nil on every path except a successful marker roundtrip. That
    /// is the fail-open contract in one field: silence is always a valid hook
    /// result.
    public enum Outcome: Equatable, Sendable {
        /// Published, and the broker returned a marker to emit.
        case publishedWithMarker(String)
        /// Published, but no usable marker came back — nothing to print.
        case published
        case droppedUnparseable
        case droppedNoSocketPath
        case droppedTransport(ClaudeHookPublishFailure)

        /// The exact bytes for stdout, or nil to print nothing at all.
        public var stdout: Data? {
            guard case .publishedWithMarker(let marker) = self else { return nil }
            return ClaudeHookOutput.markerOutputLine(marker: marker)
        }
    }

    public var environment: Environment
    public var limits: ClaudeHookLimits
    public var publisher: UnixSocketPublisher

    public init(
        environment: Environment = Environment(),
        limits: ClaudeHookLimits = .default,
        publisher: UnixSocketPublisher = UnixSocketPublisher()
    ) {
        self.environment = environment
        self.limits = limits
        self.publisher = publisher
    }

    @discardableResult
    public func run(stdin: Data, fallbackEvent: String?) -> Outcome {
        guard let parsed = ClaudeHookInputParser.parse(
            data: stdin,
            fallbackEvent: fallbackEvent,
            timestamp: environment.now(),
            limits: limits
        ) else {
            return .droppedUnparseable
        }

        var record = parsed
        record.process = processInfo()

        guard let line = ClaudeHookWireCodec.encodeLine(record, limits: limits) else {
            return .droppedUnparseable
        }
        guard let socketPath = ClaudeHookSocketPath.resolve(environment: environment.variables) else {
            return .droppedNoSocketPath
        }

        switch publisher.publishAndReadReply(line: line, to: socketPath) {
        case .failure(let failure):
            return .droppedTransport(failure)
        case .success(let reply):
            // Every step from here is "or emit nothing": a missing reply,
            // an undecodable one, an absent marker, or a marker we would not
            // put in a terminal all land on `.published`.
            guard let reply,
                  let response = ClaudeBrokerResponse.decodeLine(reply, limits: limits),
                  let marker = response.marker,
                  ClaudeMarkerSequence.isValidMarker(marker)
            else {
                return .published
            }
            return .publishedWithMarker(marker)
        }
    }

    /// Safe metadata only: identity and location of the terminal, never its
    /// contents and never argv/env beyond `$TERM_PROGRAM`.
    func processInfo() -> ClaudeHookProcessInfo {
        // ONE ppid resolution feeds both fields: the published claudePID and
        // the tty's process-table fallback must describe the same process.
        let claudePID = environment.ppid()
        return ClaudeHookProcessInfo(
            hookPID: environment.pid(),
            claudePID: claudePID,
            tty: environment.ttyName(claudePID),
            termProgram: environment.variables["TERM_PROGRAM"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Environment variable the shim uses to hand us the real Claude Code pid.
    public static let ancestorPIDEnvironmentKey = "LOCALVOXTRAL_CLAUDE_PPID"

    /// The long-lived process Claude Code spawned the hook from.
    ///
    /// NOT plain `getppid()`. The shim runs us as a child rather than `exec`ing
    /// us — it must stay alive to swallow a failed exec — so our parent is that
    /// shell, which exits a millisecond later. The app probes this pid for
    /// session liveness, so returning the shell would mark every session stale
    /// and silently discard all context. The shim therefore passes its own
    /// `$PPID`, which is the real Claude Code process.
    ///
    /// Falls back to `getppid()` for a publisher invoked directly (tests,
    /// manual runs), where the parent is the best answer available.
    public static func claudeAncestorPID(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        if let raw = environment[ancestorPIDEnvironmentKey], let pid = Int32(raw), pid > 0 {
            return pid
        }
        return getppid()
    }

    /// The controlling TTY of this hook process, if any. Claude Code runs hooks
    /// as children of the session, so this is the session's terminal device —
    /// the eventual join point for a focus probe.
    ///
    /// Three sources, cheapest first, because the first one is a lie in the
    /// field: Claude Code wires ALL THREE hook fds to pipes (stdin carries the
    /// hook JSON, stdout carries the response), so `isatty` never fires and
    /// every session published `tty: nil` — the focus join could not match
    /// anything (field finding, 2026-07-20). The controlling terminal still
    /// exists; `/dev/tty` names it without needing any fd to be it. The
    /// process-table read is the true last resort: it reports CLAUDE's terminal
    /// rather than ours, so it answers even for a hook fully detached from the
    /// controlling terminal (setsid), and claude always sits on the pane's tty.
    public static func controllingTTY(claudePID: Int32? = nil) -> String? {
        for fd in [Int32(0), 1, 2] where isatty(fd) == 1 {
            if let name = ttyname(fd) {
                return String(cString: name)
            }
        }
        let fd = open("/dev/tty", O_RDONLY | O_NONBLOCK | O_NOCTTY)
        if fd >= 0 {
            defer { close(fd) }
            if let name = ttyname(fd) {
                return String(cString: name)
            }
        }
        if let claudePID, let device = ttyDevicePath(forProcess: claudePID) {
            return device
        }
        // Outcome-only, never a path or pid: a silent nil here made a broken
        // hook-side capture indistinguishable from a failed pane read in the
        // field (2026-07-20) — the join's tty half simply never matched and
        // nothing said why. Unified log only; stdout/stderr stay silent per
        // the hook contract.
        #if canImport(os)
        Logger(subsystem: "com.localvoxtral", category: "ClaudeHook").info(
            "controlling tty unresolved: fds piped, /dev/tty unanswering, process table has no device"
        )
        #endif
        return nil
    }

    /// The `/dev/…` path of `pid`'s controlling terminal from the process
    /// table (`kinfo_proc.kp_eproc.e_tdev`), or nil when the process does not
    /// exist or has no terminal. Reads metadata about a pid we already hold —
    /// no fds, no signals, no assumptions about our own session.
    static func ttyDevicePath(forProcess pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid
        else { return nil }
        let tdev = info.kp_eproc.e_tdev
        guard tdev != -1, tdev != 0, let name = devname(tdev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// Write to stdout with raw `write(2)`, looping over partial writes.
    ///
    /// Never `FileHandle.standardOutput` — `FileHandle`'s write path raises an
    /// uncatchable ObjC exception on descriptor errors and aborts the process
    /// (the PR #60 class of field crash). A hook that crashes is a hook that
    /// breaks the user's turn, which is precisely what all of this exists to
    /// avoid. A closed or broken stdout here is simply "no marker today".
    public static func writeStdout(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = retryingOnEINTR { write(1, base.advanced(by: offset), raw.count - offset) }
                if written <= 0 { return } // EPIPE/EBADF: give up silently.
                offset += written
            }
        }
    }

    /// Read stdin until EOF or a short absolute deadline, refusing to grow past
    /// `maxLineBytes`.
    ///
    /// Raw `read(2)`, not `FileHandle.availableData` (banned repo-wide: it
    /// aborts the process on descriptor errors — PR #60). Partial reads are the
    /// norm on a pipe, so loop; `poll` is recomputed from a monotonic deadline
    /// so a producer that leaves the pipe open cannot park the hook forever. A
    /// full buffer means a hostile/huge payload and we stop reading rather than
    /// allocate for it.
    ///
    /// Kept equal to the socket publisher's default per-phase budget: stdin is
    /// another inline hook phase, and being late is worse than being absent.
    public static let stdinReadTimeout: TimeInterval = 0.25

    public static func readBoundedStdin(
        limits: ClaudeHookLimits = .default,
        descriptor: Int32 = 0,
        timeout: TimeInterval = stdinReadTimeout,
        uptimeNanos: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> Data {
        let deadline = uptimeNanos() &+ UInt64(max(0, timeout) * 1_000_000_000)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while buffer.count <= limits.maxLineBytes {
            let current = uptimeNanos()
            guard current < deadline else { break }
            let remainingMillis = (deadline - current) / 1_000_000
            var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let pollTimeout = Int32(min(remainingMillis, UInt64(Int32.max)))
            let ready = poll(&descriptorPoll, 1, pollTimeout)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }

            let count = read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break } // EOF, or an error we treat as EOF.
            buffer.append(contentsOf: chunk[0..<count])
        }
        return buffer
    }
}
