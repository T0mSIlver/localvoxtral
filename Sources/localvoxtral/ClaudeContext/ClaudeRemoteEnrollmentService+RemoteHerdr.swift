import Foundation

extension ClaudeRemoteEnrollmentService {
    /// Configure the remote herdr panel when herdr exists. Absence and a
    /// customized agents table are deliberate skipped outcomes, not failures.
    public func setupRemoteHerdr(
        sshHostAlias: String,
        timeout: TimeInterval = defaultRemoteSetupTimeout
    ) throws -> HerdrSetupOutcome {
        guard Self.isValidHostAlias(sshHostAlias) else { throw ServiceError.invalidHostAlias }
        let script = """
            set -eu
            if ! command -v herdr >/dev/null 2>&1; then
              for lv_dir in "$HOME/.claude/local" "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin "$HOME"/.nvm/versions/node/*/bin; do
                if [ -x "$lv_dir/herdr" ]; then PATH="$lv_dir:$PATH"; break; fi
              done
            fi
            if ! command -v herdr >/dev/null 2>&1; then
              printf '%s\\n' LVX_HERDR_ABSENT
              exit 0
            fi
            lv_config=${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}
            if [ -f "$lv_config" ] && grep -Eq '^[[:space:]]*\\[ui\\.sidebar\\.agents\\][[:space:]]*(#.*)?$|^[[:space:]]*rows[[:space:]]*=' "$lv_config"; then
              printf '%s\\n' LVX_HERDR_CUSTOMIZED
              exit 42
            fi
            mkdir -p "$(dirname "$lv_config")"
            touch "$lv_config"
            cat >> "$lv_config" <<'LOCALVOXTRAL_HERDR_PANEL'
            \(Self.herdrPanelConfigSnippet)
            LOCALVOXTRAL_HERDR_PANEL
            herdr server reload-config
            printf '%s\\n' LVX_HERDR_CONFIGURED
            """
        guard let runner else { throw ServiceError.executionNotConfigured }
        let invocation = Invocation(
            argv: [
                "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                sshHostAlias, "/bin/sh", "-s",
            ],
            standardInput: Data(script.utf8),
            timeout: max(timeout, 0)
        )
        let result: RunResult
        do {
            result = try runner(invocation)
        } catch {
            throw sanitizedRunnerError(error, command: "configure remote herdr")
        }
        if result.exitCode == 42, result.message.contains("LVX_HERDR_CUSTOMIZED") {
            return .customized
        }
        guard result.succeeded else {
            throw ServiceError.commandFailed(
                step: 0,
                command: "configure remote herdr",
                exitCode: result.exitCode,
                message: "The remote herdr setup command failed."
            )
        }
        if result.message.contains("LVX_HERDR_ABSENT") { return .notFound }
        if result.message.contains("LVX_HERDR_CONFIGURED") { return .configured }
        throw ServiceError.runnerFailed(
            step: 0,
            command: "configure remote herdr",
            message: "The host did not report a herdr setup outcome. "
                + "Check its herdr config, then run setup again."
        )
    }

    /// Append localvoxtral's agents-panel row only when the remote config has
    /// no agents table and no rows key. The caller must obtain explicit consent
    /// immediately before invoking this method.
    @discardableResult
    public func configureRemoteHerdrPanel(
        sshHostAlias: String,
        timeout: TimeInterval = defaultRemoteSetupTimeout
    ) throws -> [ExecutionStep] {
        guard let runner else { throw ServiceError.executionNotConfigured }
        guard Self.isValidHostAlias(sshHostAlias) else { throw ServiceError.invalidHostAlias }

        let script = """
            set -eu
            lv_config=${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}
            if [ -f "$lv_config" ] && grep -Eq '^[[:space:]]*\\[ui\\.sidebar\\.agents\\][[:space:]]*(#.*)?$|^[[:space:]]*rows[[:space:]]*=' "$lv_config"; then
              echo '\(Self.herdrPanelExistingConfigMarker)' >&2
              exit 42
            fi
            mkdir -p "$(dirname "$lv_config")"
            touch "$lv_config"
            cat >> "$lv_config" <<'LOCALVOXTRAL_HERDR_PANEL'
            \(Self.herdrPanelConfigSnippet)
            LOCALVOXTRAL_HERDR_PANEL
            herdr server reload-config
            """
        let invocation = Invocation(
            argv: [
                "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                sshHostAlias, "/bin/sh", "-s",
            ],
            standardInput: Data(script.utf8),
            timeout: timeout
        )
        Log.claudeContext.info("Claude remote herdr panel configuration requested")
        let result: RunResult
        do {
            result = try runner(invocation)
        } catch let failure as RunnerFailure {
            let error: ServiceError
            switch failure {
            case .timedOut(let seconds, let message):
                error = .commandTimedOut(
                    step: 0,
                    command: "configure herdr agents panel",
                    seconds: seconds,
                    message: message
                )
            case .outputTooLarge(_, let message):
                error = .runnerFailed(
                    step: 0,
                    command: "configure herdr agents panel",
                    message: message
                )
            }
            Log.claudeContext.error(
                "Claude remote herdr panel configuration failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        } catch {
            let failure = ServiceError.runnerFailed(
                step: 0,
                command: "configure herdr agents panel",
                message: String(describing: error)
            )
            Log.claudeContext.error(
                "Claude remote herdr panel configuration failed: \(String(describing: failure), privacy: .public)"
            )
            throw failure
        }
        if result.exitCode == 42,
           result.message.contains(Self.herdrPanelExistingConfigMarker) {
            Log.claudeContext.info(
                "Claude remote herdr panel configuration refused: existing table or rows key; add manually:\n\(Self.herdrPanelConfigSnippet, privacy: .public)"
            )
            throw ServiceError.herdrPanelConfigAlreadyCustomized
        }
        guard result.succeeded else {
            let failure = ServiceError.commandFailed(
                step: 0,
                command: "configure herdr agents panel",
                exitCode: result.exitCode,
                message: result.message
            )
            Log.claudeContext.error(
                "Claude remote herdr panel configuration failed: \(String(describing: failure), privacy: .public)"
            )
            throw failure
        }
        Log.claudeContext.info("Claude remote herdr panel configuration completed")
        return [ExecutionStep(index: 0, command: "configure herdr agents panel", message: result.message)]
    }
}
