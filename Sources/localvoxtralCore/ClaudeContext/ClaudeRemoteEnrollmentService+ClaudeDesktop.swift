import Foundation

extension ClaudeRemoteEnrollmentService {
    /// Frame carrying the Claude Desktop probe's answer: `yes` or `no`.
    package static let claudeDesktopFramePrefix = "LVX_DESKTOP:"

    /// Whether Claude Desktop runs sessions on the host.
    ///
    /// Desktop's ssh never carries the enrollment block's `RemoteForward`: its
    /// master runs with `ClearAllForwardings=yes` (measured on Desktop
    /// 2.9939.2). A host that only Desktop reaches therefore delivers no hook
    /// unless the app keeps the tunnel open itself (#656). The marker is the
    /// directory Desktop's session daemon runs from,
    /// `~/.claude/remote/srv/<hash>/server`, which exists from Desktop's first
    /// connection to the host on.
    ///
    /// Read-only, carries no token, and `ClearAllForwardings=yes` like every
    /// connection that has no use for the tunnel. Only the first framed line
    /// is read, so a banner cannot answer for the host.
    public func detectClaudeDesktop(
        sshHostAlias: String,
        timeout: TimeInterval = defaultVerificationTimeout
    ) throws -> Bool {
        guard let runner else { throw ServiceError.executionNotConfigured }
        guard Self.isValidHostAlias(sshHostAlias) else { throw ServiceError.invalidHostAlias }
        let result: RunResult
        do {
            result = try runner(
                Invocation(
                    argv: [
                        "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                        sshHostAlias, "/bin/sh", "-s",
                    ],
                    standardInput: Self.claudeDesktopProbeScript,
                    timeout: max(timeout, 0)
                )
            )
        } catch {
            throw sanitizedRunnerError(error, command: "detect Claude Desktop")
        }
        let answer = Self.framedProbeAnswer(in: result.message, prefix: Self.claudeDesktopFramePrefix)
            .map { String($0.dropFirst(Self.claudeDesktopFramePrefix.count)) }
        guard result.succeeded, let answer, answer == "yes" || answer == "no" else {
            throw ServiceError.commandFailed(
                step: 0,
                command: "detect Claude Desktop",
                exitCode: result.exitCode,
                message: "The host did not answer the Claude Desktop check."
            )
        }
        return answer == "yes"
    }

    package static let claudeDesktopProbeScript = Data("""
        if [ -d "$HOME/.claude/remote/srv" ]; then printf '\(claudeDesktopFramePrefix)yes\\n'; else printf '\(claudeDesktopFramePrefix)no\\n'; fi

        """.utf8)
}
