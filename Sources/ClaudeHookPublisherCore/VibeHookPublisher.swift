import ClaudeContextWire
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The Vibe mode of the hook publisher (`localvoxtral-claude-hook --agent vibe`).
///
/// Same contract as the Claude Code mode: exit 0, print nothing. Vibe treats a
/// hook's non-JSON stdout as a hook failure and shows a warning on the user's
/// turn, so silence is the only output that cannot surface.
extension ClaudeHookPublisher {
    /// What the process table says about one pid. A seam so the ancestor walk
    /// is testable without real processes.
    public struct ProcessFacts: Sendable, Equatable {
        public var parent: Int32
        public var session: Int32
        public var hasTTY: Bool
        /// Microseconds since the epoch, nil when the kernel reports none.
        public var startMicros: Int64?

        public init(parent: Int32, session: Int32, hasTTY: Bool, startMicros: Int64? = nil) {
            self.parent = parent
            self.session = session
            self.hasTTY = hasTTY
            self.startMicros = startMicros
        }
    }

    /// Seams of a Vibe run that the Claude Code mode has no use for.
    public struct VibeEnvironment: Sendable {
        public var ownSession: @Sendable () -> Int32
        public var processFacts: @Sendable (Int32) -> ProcessFacts?
        public var lastUserPrompt: @Sendable (String?, ClaudeHookLimits) -> String?

        public init(
            ownSession: @escaping @Sendable () -> Int32 = { getsid(0) },
            processFacts: @escaping @Sendable (Int32) -> ProcessFacts? = {
                ClaudeHookPublisher.processFacts(forProcess: $0)
            },
            lastUserPrompt: @escaping @Sendable (String?, ClaudeHookLimits) -> String? = {
                VibeTranscriptPrompt.lastUserPrompt(atPath: $0, limits: $1, deadline: 0.25)
            }
        ) {
            self.ownSession = ownSession
            self.processFacts = processFacts
            self.lastUserPrompt = lastUserPrompt
        }
    }

    /// Publish one Vibe hook invocation: the turn's prompt when the session log
    /// yields one, then the event. The first transport failure ends the run —
    /// the app is not listening, and a second dial would double the time a
    /// hook holds up Vibe's turn for nothing.
    @discardableResult
    public func runVibe(stdin: Data, vibe: VibeEnvironment = VibeEnvironment()) -> Outcome {
        guard let input = VibeHookInputParser.parse(data: stdin) else {
            return .droppedUnparseable
        }
        guard let socketPath = ClaudeHookSocketPath.resolve(environment: environment.variables) else {
            return .droppedNoSocketPath
        }

        let vibePID = Self.vibeAncestorPID(
            startingAt: environment.ppid(),
            ownSession: vibe.ownSession(),
            processFacts: vibe.processFacts
        )
        // Vibe never says a session ended, so the app tells a live Vibe from a
        // reused pid by this start time.
        let process = processInfo(
            agentPID: vibePID,
            agentStartMicros: vibe.processFacts(vibePID)?.startMicros
        )
        let prompt = vibe.lastUserPrompt(input.transcriptPath, limits)
        for var record in input.records(prompt: prompt, timestamp: environment.now(), limits: limits) {
            record.process = process
            guard let line = ClaudeHookWireCodec.encodeLine(record, limits: limits) else {
                return .droppedUnparseable
            }
            if case .failure(let failure) = publisher.publishAndReadReply(line: line, to: socketPath) {
                return .droppedTransport(failure)
            }
        }
        return .published
    }

    /// Stdin deadline for a Vibe payload, which embeds whole tool outputs.
    public static let vibeStdinReadTimeout: TimeInterval = 2.0

    /// How far the walk climbs. Vibe spawns `sh -c <command>`, the command is
    /// the shim, and the shim hands us its own `$PPID`: one wrapper shell at
    /// most stands between that pid and Vibe. The bound is slack, not a guess
    /// at depth.
    static let vibeAncestorHops = 4

    /// The long-lived Vibe process this hook descends from — the pid the app
    /// probes for session liveness and whose controlling terminal is the pane.
    ///
    /// Vibe starts every hook in a NEW SESSION (`start_new_session=True`), so
    /// the hook's own processes share a session id and have no controlling
    /// terminal, while Vibe sits outside that session. The shim's `$PPID` is
    /// either Vibe itself or the `sh -c` wrapper Vibe spawned, depending on
    /// whether that shell exec'd the command (dash does not, macOS `sh` does).
    /// A wrapper is recognizable by being in OUR session with no terminal, and
    /// it exits with the hook — publishing it would mark every session dead.
    /// So: climb while the process is one of the hook's own.
    ///
    /// A process with a terminal stops the climb even inside our session. That
    /// case does not exist today; if Vibe ever stops detaching its hooks it is
    /// what keeps the walk from climbing past Vibe to the user's login shell.
    public static func vibeAncestorPID(
        startingAt start: Int32,
        ownSession: Int32,
        processFacts: (Int32) -> ProcessFacts?
    ) -> Int32 {
        var current = start
        for _ in 0..<vibeAncestorHops {
            guard let facts = processFacts(current),
                  ownSession > 0, facts.session == ownSession, !facts.hasTTY,
                  facts.parent > 1
            else { return current }
            current = facts.parent
        }
        return current
    }

    /// Parent, session and terminal of `pid`, or nil when it cannot be read.
    public static func processFacts(forProcess pid: pid_t) -> ProcessFacts? {
        #if canImport(Darwin)
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid
        else { return nil }
        let tdev = info.kp_eproc.e_tdev
        let started = info.kp_proc.p_starttime
        let startMicros = Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec)
        return ProcessFacts(
            parent: info.kp_eproc.e_ppid,
            session: getsid(pid),
            hasTTY: tdev != -1 && tdev != 0,
            startMicros: startMicros > 0 ? startMicros : nil
        )
        #else
        return nil
        #endif
    }
}
