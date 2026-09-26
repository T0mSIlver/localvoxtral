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
}
