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
            # Single-quoted: the snippet holds no single quote.
            lv_snippet='\(Self.herdrPanelConfigSnippet)'
            # The block an earlier run appended, line ends aside: already set
            # up, and the pattern below would call it customized (#2067).
            if [ -f "$lv_config" ] \\
              && LV_SNIPPET="$lv_snippet" awk '{ sub(/\\r$/, ""); text = text $0 "\\n" } END { exit !index(text, ENVIRON["LV_SNIPPET"]) }' "$lv_config"; then
              :
            elif [ -f "$lv_config" ] \\
              && sed -e 's/#.*//' "$lv_config" | tr -d " \\t\\r\\"'" | grep -Eq '\(Self.herdrAgentsConfigPattern)'; then
              printf '%s\\n' LVX_HERDR_CUSTOMIZED
              exit 42
            else
              mkdir -p "$(dirname "$lv_config")"
              touch "$lv_config"
              # A last line with no newline would take the table header onto it.
              # $(...) drops a trailing newline, so it is empty only when the
              # file is, or already ends with one.
              if [ -n "$(tail -c 1 "$lv_config")" ]; then printf '\\n' >> "$lv_config"; fi
              if [ -s "$lv_config" ]; then printf '\\n' >> "$lv_config"; fi
              printf '%s\\n' "$lv_snippet" >> "$lv_config"
            fi
            # No herdr server running fails the reload; the server reads the
            # file when it next starts.
            if ! herdr server reload-config >/dev/null 2>&1; then
              printf '%s\\n' LVX_HERDR_RELOAD_FAILED
            fi
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
        if result.message.contains("LVX_HERDR_CONFIGURED") {
            if result.message.contains("LVX_HERDR_RELOAD_FAILED") {
                Log.claudeContext.notice(
                    "Remote herdr panel configured; reload-config failed, so it applies when herdr next starts"
                )
            }
            return .configured
        }
        throw ServiceError.runnerFailed(
            step: 0,
            command: "configure remote herdr",
            message: "The host did not report a herdr setup outcome. "
                + "Check its herdr config, then run setup again."
        )
    }
}
