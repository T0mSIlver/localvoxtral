import Foundation

extension ClaudeRemoteEnrollmentService {
    /// Prove that this process's LC_LVX_TTY value crosses sshd. The random
    /// value exists only in the child environment and is never logged.
    ///
    /// The echo is FRAMED (`LVX_TTY:<value>`) and only the first framed line
    /// is read, for the same reason every other probe frames: stderr shares
    /// the capture pipe, and a login banner or MOTD glued to the value would
    /// otherwise turn a healthy crossing into a "remote refused it" verdict.
    /// The frame is never interpreted — the payload is compared by exact
    /// equality with the minted value and nothing else.
    public func probeRemoteEnvironment(
        sshHostAlias: String,
        timeout: TimeInterval = defaultVerificationTimeout
    ) throws -> EnvironmentCrossingOutcome {
        guard let runner else { throw ServiceError.executionNotConfigured }
        guard Self.isValidHostAlias(sshHostAlias) else { throw ServiceError.invalidHostAlias }
        let probe = environmentProbeValue()
        let invocation = Invocation(
            argv: [
                "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                sshHostAlias, "/bin/sh", "-s",
            ],
            standardInput: Data("printf 'LVX_TTY:%s\\n' \"${LC_LVX_TTY-}\"\n".utf8),
            timeout: max(timeout, 0),
            environment: ["LC_LVX_TTY": probe]
        )
        let result: RunResult
        do {
            result = try runner(invocation)
        } catch {
            throw sanitizedRunnerError(error, command: "check remote environment")
        }
        guard result.succeeded else {
            throw ServiceError.commandFailed(
                step: 0,
                command: "check remote environment",
                exitCode: result.exitCode,
                message: "SSH did not complete the environment check."
            )
        }
        let echoed = Self.framedProbeAnswer(in: result.message, prefix: Self.envProbeFramePrefix)
            .map { String($0.dropFirst(Self.envProbeFramePrefix.count)) }
        guard echoed == probe else {
            let configResult: RunResult
            do {
                configResult = try runner(
                    Invocation(
                        argv: ["ssh", "-G", "--", sshHostAlias],
                        standardInput: Data(),
                        timeout: max(timeout, 0)
                    )
                )
            } catch {
                throw sanitizedRunnerError(error, command: "inspect SSH SendEnv")
            }
            guard configResult.succeeded else {
                throw ServiceError.commandFailed(
                    step: 0,
                    command: "inspect SSH SendEnv",
                    exitCode: configResult.exitCode,
                    message: "OpenSSH could not expand this host's configuration."
                )
            }
            return Self.sshGOutputSendsLocalTTY(configResult.message)
                ? .remoteAcceptEnvMissing
                : .localSendEnvMissing
        }
        return .crossed
    }

    private static func sshGOutputSendsLocalTTY(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first?.lowercased() == "sendenv" else { return false }
            return fields.dropFirst().contains { wildcard($0, matches: "LC_LVX_TTY") }
        }
    }

    private static func wildcard(_ pattern: Substring, matches value: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
        if parts.count == 1 { return String(pattern) == value }
        var remainder = value[...]
        for (index, part) in parts.enumerated() where !part.isEmpty {
            guard let range = remainder.range(of: part) else { return false }
            if index == 0, range.lowerBound != remainder.startIndex { return false }
            remainder = remainder[range.upperBound...]
        }
        if let last = parts.last, !last.isEmpty { return remainder.isEmpty }
        return true
    }
}
