import Foundation

extension ClaudeRemoteEnrollmentService {
    // MARK: - Execution (opt-in only)

    /// Run the plan's remote commands through the injected runner.
    ///
    /// Throws `.executionNotConfigured` when no runner was supplied. Each plan
    /// command is sent to `/bin/sh -s` over SSH stdin. The only spawned argv is
    /// `ssh -o BatchMode=yes -o ClearAllForwardings=yes <alias> /bin/sh -s`,
    /// which contains no token.
    ///
    /// - Parameter token: the plaintext, used ONLY to redact it back out of any
    ///   failure. Nothing here logs or stores it.
    @discardableResult
    public func executeRemoteSetup(
        _ plan: SetupPlan,
        sshHostAlias: String,
        token: String,
        timeout: TimeInterval = defaultRemoteSetupTimeout
    ) throws -> [ExecutionStep] {
        try execute(
            commands: plan.remoteCommands,
            sshHostAlias: sshHostAlias,
            token: token,
            timeout: timeout,
            label: "setup"
        )
    }

    /// Update the remote plugin on an already-enrolled host.
    ///
    /// Token-free by construction: `claude plugin update` preserves the config
    /// the install stored, so this path never has the credential to leak. It is
    /// a separate entry point rather than a plan step because the user runs it
    /// long after enrollment — when the app ships a new plugin version — and by
    /// then the one-time token is gone.
    @discardableResult
    public func executeRemotePluginUpdate(
        sshHostAlias: String,
        remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort,
        timeout: TimeInterval = defaultRemoteSetupTimeout
    ) throws -> [ExecutionStep] {
        try execute(
            commands: Self.remotePluginUpdateCommands(remoteForwardPort: remoteForwardPort),
            sshHostAlias: sshHostAlias,
            token: "",
            timeout: timeout,
            label: "plugin update"
        )
    }

    func sanitizedRunnerError(_ error: Error, command: String) -> ServiceError {
        if let failure = error as? RunnerFailure {
            switch failure {
            case .timedOut(let seconds, _):
                return .commandTimedOut(
                    step: 0, command: command, seconds: seconds, message: "The host timed out."
                )
            case .outputTooLarge(let capBytes, _):
                return .runnerFailed(
                    step: 0,
                    command: command,
                    message: "The host exceeded the \(capBytes)-byte output limit."
                )
            }
        }
        return .runnerFailed(
            step: 0, command: command, message: "The remote command could not be started."
        )
    }

    private func execute(
        commands: [String],
        sshHostAlias: String,
        token: String,
        timeout: TimeInterval,
        label: String
    ) throws -> [ExecutionStep] {
        Log.claudeContext.info("Claude remote \(label, privacy: .public) execution requested")
        guard let runner else {
            Log.claudeContext.error(
                "Claude remote \(label, privacy: .public) execution failed: runner not configured"
            )
            throw ServiceError.executionNotConfigured
        }
        guard Self.isValidHostAlias(sshHostAlias) else {
            Log.claudeContext.error(
                "Claude remote \(label, privacy: .public) execution failed: invalid host alias"
            )
            throw ServiceError.invalidHostAlias
        }
        let deadline = now().addingTimeInterval(max(timeout, 0))
        var completed: [ExecutionStep] = []
        for (index, command) in commands.enumerated() {
            let displayCommand = ClaudeRemoteTokenRedaction.redact(
                command.trimmingCharacters(in: .whitespaces),
                token: token
            )
            let remaining = max(deadline.timeIntervalSince(now()), 0)
            guard remaining > 0 else {
                let failure = ServiceError.commandTimedOut(
                    step: index, command: displayCommand, seconds: timeout, message: ""
                )
                Log.claudeContext.error(
                    "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                throw failure
            }
            let invocation = Invocation(
                // ClearAllForwardings: this connection has no use for the
                // 8473 tunnel, and with the user's own session usually holding
                // it, attempting the forward here only produced a scary
                // "remote port forwarding failed" warning inside setup errors
                // (field report 2026-07-26).
                // `--` ends OpenSSH's option parsing: the alias is validated
                // above and cannot start with `-`, and this makes an alias that
                // somehow did reach here a failed connection rather than a
                // silently successful option.
                argv: [
                    "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                    sshHostAlias, "/bin/sh", "-s",
                ],
                standardInput: Self.remoteScript(command: command),
                timeout: remaining
            )
            Log.claudeContext.info(
                "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) requested"
            )
            let result: RunResult
            do {
                result = try runner(invocation)
            } catch let failure as RunnerFailure {
                let error: ServiceError
                switch failure {
                case .timedOut(let seconds, let message):
                    error = .commandTimedOut(
                        step: index,
                        command: displayCommand,
                        seconds: seconds,
                        message: ClaudeRemoteTokenRedaction.redact(message, token: token)
                    )
                case .outputTooLarge(_, let message):
                    error = .runnerFailed(
                        step: index,
                        command: displayCommand,
                        message: ClaudeRemoteTokenRedaction.redact(message, token: token)
                    )
                }
                Log.claudeContext.error(
                    "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                throw error
            } catch {
                let redacted = ClaudeRemoteTokenRedaction.redact(String(describing: error), token: token)
                let failure = ServiceError.runnerFailed(
                    step: index, command: displayCommand, message: redacted
                )
                Log.claudeContext.error(
                    "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                throw failure
            }
            guard result.succeeded else {
                let failure = ServiceError.commandFailed(
                    step: index,
                    command: displayCommand,
                    exitCode: result.exitCode,
                    message: ClaudeRemoteTokenRedaction.redact(result.message, token: token)
                )
                Log.claudeContext.error(
                    "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                throw failure
            }
            completed.append(
                ExecutionStep(
                    index: index,
                    command: displayCommand,
                    message: ClaudeRemoteTokenRedaction.redact(result.message, token: token)
                )
            )
            Log.claudeContext.info(
                "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) completed"
            )
        }
        Log.claudeContext.info("Claude remote \(label, privacy: .public) execution completed")
        return completed
    }

    /// PATH resolution for `claude` under `ssh <host> /bin/sh -s`.
    ///
    /// Non-interactive SSH shells run with sshd's minimal PATH (no login rc),
    /// which usually lacks the user-local directories claude installs into —
    /// the field failure was dash's bare `claude: not found` on a host where
    /// claude worked fine interactively. Probe the same locations the local
    /// installer does (`ClaudePluginInstallService.claudeCLICandidates`), plus
    /// nvm-style node bins, and fail with an actionable message instead of
    /// dash's. POSIX sh only — the remote /bin/sh is dash on Debian-family
    /// hosts. Token-free by construction, like the `set -eu` line.
    static let claudePathResolverPreamble = """
        if ! command -v claude >/dev/null 2>&1; then
          for lv_dir in "$HOME/.claude/local" "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin "$HOME"/.nvm/versions/node/*/bin; do
            if [ -x "$lv_dir/claude" ]; then PATH="$lv_dir:$PATH"; break; fi
          done
        fi
        if ! command -v claude >/dev/null 2>&1; then
          echo "localvoxtral: 'claude' was not found on this host's non-interactive PATH, nor in ~/.claude/local, ~/.local/bin, ~/bin, /opt/homebrew/bin, /usr/local/bin, or ~/.nvm/versions/node/*/bin. Run 'command -v claude' in a normal shell on this host. Then rerun setup or add that directory to PATH for non-interactive SSH shells." >&2
          exit 127
        fi

        """

    static func remoteScript(command: String) -> Data {
        // The resolver only guards commands that actually invoke claude, so a
        // future non-claude step cannot be failed by a missing CLI it never
        // needed.
        let preamble = command.contains("claude") ? claudePathResolverPreamble : ""
        return Data("set -eu\n\(preamble)\(command)\n".utf8)
    }
}
