import ClaudeContextWire
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
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
        public var ttyName: @Sendable () -> String?
        public var variables: [String: String]

        public init(
            now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
            pid: @escaping @Sendable () -> Int32 = { getpid() },
            ppid: @escaping @Sendable () -> Int32 = { ClaudeHookPublisher.claudeAncestorPID() },
            ttyName: @escaping @Sendable () -> String? = { ClaudeHookPublisher.controllingTTY() },
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
        ClaudeHookProcessInfo(
            hookPID: environment.pid(),
            claudePID: environment.ppid(),
            tty: environment.ttyName(),
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
    public static func controllingTTY() -> String? {
        for fd in [Int32(0), 1, 2] where isatty(fd) == 1 {
            if let name = ttyname(fd) {
                return String(cString: name)
            }
        }
        return nil
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

    /// Read stdin to EOF, refusing to grow past `maxLineBytes`.
    ///
    /// Raw `read(2)`, not `FileHandle.availableData` (banned repo-wide: it
    /// aborts the process on descriptor errors — PR #60). Partial reads are the
    /// norm on a pipe, so loop; a full buffer means a hostile/huge payload and
    /// we stop reading rather than allocate for it.
    public static func readBoundedStdin(limits: ClaudeHookLimits = .default) -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while buffer.count <= limits.maxLineBytes {
            let count = retryingOnEINTR { read(0, &chunk, chunk.count) }
            if count <= 0 { break } // EOF, or an error we treat as EOF.
            buffer.append(contentsOf: chunk[0..<count])
        }
        return buffer
    }
}
