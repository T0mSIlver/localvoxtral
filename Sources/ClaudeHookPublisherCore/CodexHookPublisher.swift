import ClaudeContextWire
import Foundation

/// The Codex mode of the hook publisher (`localvoxtral-claude-hook --agent codex`).
///
/// Same contract as the other modes: exit 0, print nothing. Codex reads a
/// hook's stdout as a decision, so an empty stdout is the only output that
/// can never change what the user's turn does.
extension ClaudeHookPublisher {
    /// Stdin deadline for a Codex payload, which can carry a whole patch.
    public static let codexStdinReadTimeout: TimeInterval = 2.0

    /// Publish one Codex hook invocation.
    ///
    /// Codex spawns every hook as `$SHELL -lc <command>` in a NEW SESSION with
    /// no controlling terminal (measured on 0.156.0: the hook's `/dev/tty`
    /// does not open and its process-table tty is `?`), exactly the shape
    /// Vibe's hooks have. So the agent pid comes from the same walk out of
    /// the hook's session, and the pane's tty is read off that process.
    ///
    /// The Codex process's start time rides along: Codex does send
    /// `SessionEnd`, but only under a 3 s ceiling it may miss, and a reused
    /// pid must not keep a dead session joinable.
    @discardableResult
    public func runCodex(stdin: Data, vibe: VibeEnvironment = VibeEnvironment()) -> Outcome {
        guard var record = CodexHookInputParser.parse(
            data: stdin, timestamp: environment.now(), limits: limits
        ) else {
            return .droppedUnparseable
        }
        guard let socketPath = ClaudeHookSocketPath.resolve(environment: environment.variables) else {
            return .droppedNoSocketPath
        }

        let codexPID = Self.vibeAncestorPID(
            startingAt: environment.ppid(),
            ownSession: vibe.ownSession(),
            processFacts: vibe.processFacts
        )
        record.process = processInfo(
            agentPID: codexPID,
            agentStartMicros: vibe.processFacts(codexPID)?.startMicros
        )
        guard let line = ClaudeHookWireCodec.encodeLine(record, limits: limits) else {
            return .droppedUnparseable
        }
        if case .failure(let failure) = publisher.publishAndReadReply(line: line, to: socketPath) {
            return .droppedTransport(failure)
        }
        return .published
    }
}
