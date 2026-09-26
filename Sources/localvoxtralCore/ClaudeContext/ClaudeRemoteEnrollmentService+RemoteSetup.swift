import Foundation

extension ClaudeRemoteEnrollmentService {
    package func sanitizedRunnerError(_ error: Error, command: String) -> ServiceError {
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
    ///
    /// Last resort: the CLI Claude Desktop installs for its ssh sessions,
    /// `~/.claude/remote/ccd-cli/<version>`. A host whose only Claude Code is
    /// Desktop's has no `claude` anywhere else, and skipping the plugin there
    /// left the Desktop sessions with no hooks (#656). The files are versioned
    /// binaries, not directories, so a PATH entry cannot name one: a shell
    /// function called `claude` does, and `command -v` finds it. Only runnable
    /// files named with digits and dots count, so a partial download cannot
    /// win, and the highest version is picked field by field (POSIX `sort -t.
    /// -k…n`; `sort -V` is not POSIX). The names are matched with `case`, not
    /// `grep`: no remote plugin script text-matches anything (see
    /// `testPluginSetupDecodesTheListingAndReportsAnAlreadyCurrentPlugin`).
    package static let claudePathResolverPreamble = """
        if ! command -v claude >/dev/null 2>&1; then
          for lv_dir in "$HOME/.claude/local" "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin "$HOME"/.nvm/versions/node/*/bin; do
            if [ -x "$lv_dir/claude" ]; then PATH="$lv_dir:$PATH"; break; fi
          done
        fi
        if ! command -v claude >/dev/null 2>&1; then
          lv_ccd=
          for lv_v in $(ls "$HOME/.claude/remote/ccd-cli" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n); do
            case $lv_v in
              *[!0-9.]*|.*|*.|*..*) ;;
              *) if [ -x "$HOME/.claude/remote/ccd-cli/$lv_v" ]; then lv_ccd=$lv_v; fi ;;
            esac
          done
          if [ -n "$lv_ccd" ]; then
            lv_claude="$HOME/.claude/remote/ccd-cli/$lv_ccd"
            claude() { "$lv_claude" "$@"; }
          fi
        fi
        if ! command -v claude >/dev/null 2>&1; then
          echo "localvoxtral: 'claude' was not found on this host's non-interactive PATH, nor in ~/.claude/local, ~/.local/bin, ~/bin, /opt/homebrew/bin, /usr/local/bin, ~/.nvm/versions/node/*/bin, or Claude Desktop's ~/.claude/remote/ccd-cli. Run 'command -v claude' in a normal shell on this host. Then rerun setup or add that directory to PATH for non-interactive SSH shells." >&2
          exit 127
        fi

        """

    package static func remoteScript(command: String) -> Data {
        // The resolver only guards commands that actually invoke claude, so a
        // future non-claude step cannot be failed by a missing CLI it never
        // needed.
        let preamble = command.contains("claude") ? claudePathResolverPreamble : ""
        return Data("set -eu\n\(preamble)\(command)\n".utf8)
    }
}
