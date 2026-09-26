import Foundation

extension ClaudeRemoteEnrollmentService {
    // MARK: - Verification (read-only, opt-in only)

    /// Per PROBE, not for the run as a whole.
    ///
    /// A shared deadline starved the second probe: a host that stalls the
    /// tunnel check to its limit left the plugin check with zero budget, so one
    /// slow answer silently became two failures and the user learned nothing
    /// about the plugin (review finding, round 1).
    public static let defaultVerificationTimeout: TimeInterval = 20

    /// Check an enrolled host's setup and return interpreted verdicts.
    ///
    /// Read-only by construction: it writes nothing locally (no filesystem seam
    /// is touched) and runs nothing on the host that changes state — one or two
    /// curls against the forwarded port (`tunnelVerdict`) and one `claude
    /// plugin list`.
    ///
    /// **No probe output ever leaves this method.** Not in `summary`, not in
    /// `hint`, not in `detail` — every string returned is composed here from
    /// exit codes, the HTTP status code, and constants we own. The reason is
    /// specific and was a review finding: `claude plugin list` prints the
    /// plugin's stored userConfig, which after a rotation is the host's OLD
    /// token — a value this process no longer knows and therefore cannot
    /// redact. A redactor cannot save a secret it has never seen, so the output
    /// simply does not travel. Matching against it is free (that is input, not
    /// output); emitting any part of it is not, which is why even the matched
    /// plugin line is reported as the constant name we searched for.
    ///
    /// - Parameters:
    ///   - remoteForwardPort: the port the hooks post to ON THE HOST — this
    ///     Mac's allocation, the same number the snippet's `RemoteForward`
    ///     binds and the plugin's `port` option stores. Probing 8473 here would
    ///     check a tunnel that no longer exists on a per-Mac install.
    ///   - listenerIsBound: whether localvoxtral itself is listening on this
    ///     Mac right now. A 401 proves only that SOMETHING on this Mac answered
    ///     through the tunnel: when our own bind failed, a squatter on the
    ///     listener port receives the forwarded request and its 401 would
    ///     otherwise read as a pass (review finding, round 1).
    ///
    /// Throws only `.executionNotConfigured` (no runner injected — the default)
    /// and `.invalidHostAlias`. Everything else becomes a failed check, so one
    /// broken probe cannot hide the other's answer.
    /// - Parameter staleAllocatedPort: pass this Mac's allocation when
    ///   `remoteForwardPort` came from `~/.ssh/config` and the two disagree.
    ///   The probe follows the CONFIG — that is the tunnel that exists — and
    ///   every tunnel verdict names the mismatch instead of reporting a healthy
    ///   old tunnel as a dead new one.
    public func executeVerification(
        sshHostAlias: String,
        remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort,
        listenerIsBound: Bool,
        staleAllocatedPort: UInt16? = nil,
        includesPluginCheck: Bool = true,
        timeout: TimeInterval = defaultVerificationTimeout
    ) throws -> [VerificationCheck] {
        Log.claudeContext.info("Claude remote verification requested")
        guard let runner else {
            Log.claudeContext.error("Claude remote verification failed: runner not configured")
            throw ServiceError.executionNotConfigured
        }
        guard Self.isValidHostAlias(sshHostAlias) else {
            Log.claudeContext.error("Claude remote verification failed: invalid host alias")
            throw ServiceError.invalidHostAlias
        }

        let tunnel = tunnelVerdict(
            sshHostAlias: sshHostAlias,
            remoteForwardPort: remoteForwardPort,
            listenerIsBound: listenerIsBound,
            staleAllocatedPort: staleAllocatedPort,
            runner: runner,
            timeout: timeout
        )

        // A host set up for another agent only has no plugin to look for.
        guard includesPluginCheck else {
            Log.claudeContext.info(
                "Claude remote verification completed: tunnel=\(tunnel.passed, privacy: .public) plugin=not checked"
            )
            return [tunnel]
        }

        let plugin = runCheck(
            kind: .plugin,
            runner: runner,
            timeout: timeout,
            // ClearAllForwardings here for the same reason `execute` uses it:
            // this connection has no use for the tunnel, and competing for a
            // port the user's own session already holds only produces a scary
            // warning (field report 2026-07-26).
            argv: [
                "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                sshHostAlias, "/bin/sh", "-s",
            ],
            standardInput: Self.remoteScript(command: "claude plugin list")
        ) { Self.pluginCheck(result: $0, sshHostAlias: sshHostAlias) }

        Log.claudeContext.info(
            "Claude remote verification completed: tunnel=\(tunnel.passed, privacy: .public) plugin=\(plugin.passed, privacy: .public)"
        )
        return [tunnel, plugin]
    }

    /// The tunnel verdict, from up to two probes (#656).
    ///
    /// The FIRST probe clears forwardings, so it can only reach a forward
    /// something else already holds: the app's own supervised ssh, the user's
    /// terminal session, an editor's. That is the tunnel the hooks use between
    /// checks. The old single probe carried the alias's `RemoteForward` itself,
    /// bound the port, curled through its own forward and reported "Tunnel is
    /// up" about a tunnel that closed when the probe exited — which is exactly
    /// what a host reached only by Claude Desktop (whose ssh clears
    /// forwardings) looked like.
    ///
    /// Only when nothing answered does the SECOND probe run without
    /// `ClearAllForwardings`, to tell "the config block works but nothing
    /// holds it open" from "the config block does not open a tunnel at all".
    /// Every other first answer (401, a stranger's code, no curl, ssh failing)
    /// is already the verdict.
    private func tunnelVerdict(
        sshHostAlias: String,
        remoteForwardPort: UInt16,
        listenerIsBound: Bool,
        staleAllocatedPort: UInt16?,
        runner: Runner,
        timeout: TimeInterval
    ) -> VerificationCheck {
        let script = Self.tunnelProbeScript(remoteForwardPort: remoteForwardPort)
        var standingResult: RunResult?
        let standing = runCheck(
            kind: .tunnel,
            runner: runner,
            timeout: timeout,
            argv: Self.standingTunnelProbeArgv(sshHostAlias: sshHostAlias),
            standardInput: script
        ) { result in
            standingResult = result
            return Self.tunnelCheck(
                result: result,
                sshHostAlias: sshHostAlias,
                remoteForwardPort: remoteForwardPort,
                listenerIsBound: listenerIsBound,
                staleAllocatedPort: staleAllocatedPort
            )
        }
        guard let standingResult, Self.nothingAnswered(standingResult) else { return standing }

        return runCheck(
            kind: .tunnel,
            runner: runner,
            timeout: timeout,
            argv: Self.configTunnelProbeArgv(sshHostAlias: sshHostAlias),
            standardInput: script
        ) { result in
            Self.configTunnelCheck(
                result: result,
                sshHostAlias: sshHostAlias,
                remoteForwardPort: remoteForwardPort,
                listenerIsBound: listenerIsBound,
                staleAllocatedPort: staleAllocatedPort
            )
        }
    }

    /// Reaches only a forward another connection holds.
    package static func standingTunnelProbeArgv(sshHostAlias: String) -> [String] {
        ["ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--", sshHostAlias, "/bin/sh", "-s"]
    }

    /// Carries the alias's own `RemoteForward`, like an interactive `ssh` would.
    package static func configTunnelProbeArgv(sshHostAlias: String) -> [String] {
        ["ssh", "-o", "BatchMode=yes", "--", sshHostAlias, "/bin/sh", "-s"]
    }

    /// ssh worked, curl ran, and no HTTP status came back.
    package static func nothingAnswered(_ result: RunResult) -> Bool {
        guard result.succeeded else { return false }
        return switch httpCode(in: result) {
        case "000", nil: framedProbeAnswer(in: result.message) != missingCurlSentinel
        default: false
        }
    }

    /// Three digits from our own frame, or nil.
    package static func httpCode(in result: RunResult) -> String? {
        framedProbeAnswer(in: result.message)
            .flatMap { $0.hasPrefix(httpFramePrefix) ? String($0.dropFirst(httpFramePrefix.count)) : nil }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.count == 3 && $0.allSatisfy(\.isNumber) ? $0 : nil }
    }

    /// The verdict once the standing probe found nothing: this probe opened
    /// the alias's own forward for as long as it ran.
    package static func configTunnelCheck(
        result: RunResult,
        sshHostAlias: String,
        remoteForwardPort: UInt16,
        listenerIsBound: Bool,
        staleAllocatedPort: UInt16? = nil
    ) -> VerificationCheck {
        var check = tunnelCheck(
            result: result,
            sshHostAlias: sshHostAlias,
            remoteForwardPort: remoteForwardPort,
            listenerIsBound: listenerIsBound,
            staleAllocatedPort: staleAllocatedPort
        )
        // Our listener answered through our own forward: the block is right,
        // and the only thing missing is a connection that stays.
        if check.passed { return noStandingTunnelCheck(remoteForwardPort: remoteForwardPort) }
        if check.summary == noLiveTunnelSummary {
            return nothingAnsweredThroughConfig(remoteForwardPort: remoteForwardPort)
        }
        // A squatter verdict from this probe must not be reconciled into a
        // pass later: whatever answered did so through a forward that closed
        // with the probe, so no listener read can make the tunnel standing.
        check.decidedBy = .remote
        return check
    }

    /// The config block opens the tunnel; nothing keeps it open.
    package static func noStandingTunnelCheck(remoteForwardPort: UInt16) -> VerificationCheck {
        VerificationCheck(
            kind: .tunnel,
            passed: false,
            summary: "Your SSH config opens the tunnel, but nothing keeps it open.",
            hint: "Turn on Keep the tunnel open for this host. Claude Desktop and other "
                + "headless sessions never open it themselves.",
            detail: "Nothing answered on the host's 127.0.0.1:\(remoteForwardPort) until this "
                + "check opened its own forward, which closed when the check did."
        )
    }

    /// Even the config block's own forward brought nothing back, so the old
    /// advice, "open an SSH session", is what this probe just did.
    private static func nothingAnsweredThroughConfig(remoteForwardPort: UInt16) -> VerificationCheck {
        VerificationCheck(
            kind: .tunnel,
            passed: false,
            summary: "The SSH config did not open a tunnel.",
            hint: "Re-run setup so ~/.ssh/config forwards port \(remoteForwardPort), and check "
                + "that the host's sshd allows remote forwarding.",
            detail: "Nothing answered on the host's 127.0.0.1:\(remoteForwardPort), with or "
                + "without the config block's RemoteForward."
        )
    }

    package static let noLiveTunnelSummary = "No tunnel is live right now."

    private func runCheck(
        kind: VerificationCheck.Kind,
        runner: Runner,
        timeout: TimeInterval,
        argv: [String],
        standardInput: Data,
        interpret: (RunResult) -> VerificationCheck
    ) -> VerificationCheck {
        do {
            return interpret(
                try runner(
                    Invocation(argv: argv, standardInput: standardInput, timeout: max(timeout, 0))
                )
            )
        } catch let failure as RunnerFailure {
            switch failure {
            case .timedOut(let seconds, _):
                return VerificationCheck(
                    kind: kind,
                    passed: false,
                    summary: "The check timed out after \(Int(seconds))s.",
                    hint: "The host did not answer in time.",
                    detail: "Probe timed out after \(Int(seconds))s."
                )
            case .outputTooLarge(let capBytes, _):
                return VerificationCheck(
                    kind: kind,
                    passed: false,
                    summary: "The host produced too much output to read.",
                    detail: "Probe output exceeded \(capBytes / 1024) KB and was stopped."
                )
            }
        } catch {
            // Deliberately not `String(describing: error)`: a runner's error is
            // not this method's output to vouch for, and the invariant above is
            // absolute.
            return VerificationCheck(
                kind: kind,
                passed: false,
                summary: "The check could not run.",
                detail: "The probe could not be started."
            )
        }
    }

    /// Unauthenticated probe of the forwarded listener.
    ///
    /// The script always exits 0 and prints one token, so a non-zero exit can
    /// only mean SSH itself failed. Without that, curl's connect failure (exit
    /// 7) and ssh's own failure (255) would be the same observation, and "no
    /// tunnel" would be reported as "cannot reach the host".
    /// Prefix that FRAMES the probe's own output.
    ///
    /// The probe's answer is one line this script printed, and nothing else on
    /// the connection may be mistaken for it: a login banner, an rc-file echo,
    /// or a MOTD ending in `401` would otherwise decide a verdict. Parsing takes
    /// the FIRST `LVX_`-framed line and ignores every other byte.
    ///
    /// The residual, stated plainly: a HOSTILE host can print the frame itself
    /// and say whatever it likes about its own reachability. That is accepted —
    /// it is a machine the user enrolled, lying about whether it can reach them,
    /// with no mutation and no credential consequence on either side (the probe
    /// sends none and writes nothing). Framing exists to stop ACCIDENTS, not to
    /// authenticate the host.
    package static let probeFramePrefix = "LVX_"
    /// Framed answer carrying the HTTP status code the host observed.
    package static let httpFramePrefix = "LVX_HTTP:"
    /// Printed when the host has no `curl`. A missing curl and a refused
    /// connection both produce "nothing came back" otherwise, and they have
    /// completely different fixes — the plugin's shim IS curl, so a host
    /// without it can never deliver context no matter how healthy the tunnel.
    package static let missingCurlSentinel = "LVX_NO_CURL"
    /// Frame carrying the env probe's echo. Payload compared by equality only.
    package static let envProbeFramePrefix = "LVX_TTY:"

    package static func tunnelProbeScript(remoteForwardPort: UInt16) -> Data {
        Data("""
        set -u
        command -v curl >/dev/null 2>&1 || { printf '%s\\n' '\(missingCurlSentinel)'; exit 0; }
        code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:\(remoteForwardPort)/v1/hook/SessionStart 2>/dev/null) || code=000
        [ -n "$code" ] || code=000
        printf '\(httpFramePrefix)%s\\n' "$code"

        """.utf8)
    }

    /// The first framed line, or nil when the probe never spoke.
    package static func framedProbeAnswer(in output: String, prefix: String = probeFramePrefix) -> String? {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
    }

    /// The local half of the tunnel verdict, as its own value.
    ///
    /// Shared by the capture-time check and the interpretation-time
    /// reconciliation so the two can never drift into different copy for the
    /// same situation.
    package static func squatterTunnelCheck(remoteForwardPort: UInt16) -> VerificationCheck {
        VerificationCheck(
            kind: .tunnel,
            passed: false,
            summary: "Something else answered on port \(remoteForwardPort).",
            hint: "localvoxtral is not listening on this Mac, so the reply came from "
                + "whatever holds the port. Fix that first, then check again.",
            detail: "HTTP 401 arrived while this Mac's listener was not bound.",
            // The ONLY verdict this Mac decides by itself, and therefore the
            // only one a later listener read may revisit.
            decidedBy: .localListener
        )
    }

    /// The 401 pass, as its own value — the counterpart `reconciled` restores
    /// when the listener turns out to have been ours after all.
    package static func passingTunnelCheck() -> VerificationCheck {
        VerificationCheck(
            kind: .tunnel,
            passed: true,
            summary: "Tunnel is up and localvoxtral answered.",
            detail: "HTTP 401 (the expected refusal of an unauthenticated probe).",
            decidedBy: .localListener
        )
    }

    /// Re-apply the local half of the tunnel verdict after the probes returned.
    ///
    /// `listenerIsBound` is read TWICE on purpose — once before the probes are
    /// launched and once here, after up to a full timeout of detached ssh work
    /// (review finding, round 2). The window cuts BOTH ways, which is why this
    /// is not a one-way downgrade (review finding, round 3):
    ///
    /// - bound at launch, gone by the time it answers → the 401 came from
    ///   whoever took the port, so a pass becomes the squatter verdict;
    /// - unbound at launch, bound by the time it answers (a Retry that
    ///   succeeded, the squatter quitting) → the 401 was genuinely ours, and
    ///   pinning the squatter call would tell a user to fix something they
    ///   already fixed.
    ///
    /// Only `decidedBy == .localListener` verdicts move. Everything else
    /// described what the HOST said, and this Mac's listener cannot make "curl
    /// is missing over there" or "the host said nothing" any less true.
    public static func reconciled(
        _ checks: [VerificationCheck],
        remoteForwardPort: UInt16,
        listenerIsBound: Bool
    ) -> [VerificationCheck] {
        checks.map { check in
            guard check.kind == .tunnel, check.decidedBy == .localListener else { return check }
            return listenerIsBound
                ? passingTunnelCheck()
                : squatterTunnelCheck(remoteForwardPort: remoteForwardPort)
        }
    }

    /// The tunnel exists on a port this Mac no longer allocates.
    ///
    /// Not a pass: the enrollment in front of the user names `allocatedPort`,
    /// and half of the setup is on the other one. Not a failure of the tunnel
    /// either — it says what is actually true over there, then names the one
    /// step that fixes it (review finding, round 3).
    package static func staleConfigTunnelCheck(
        probedPort: UInt16,
        allocatedPort: UInt16,
        tunnelIsUp: Bool
    ) -> VerificationCheck {
        VerificationCheck(
            kind: .tunnel,
            passed: false,
            summary: tunnelIsUp
                ? "Tunnel is up on port \(probedPort), which is no longer this Mac's port."
                : "No tunnel is live on port \(probedPort), and that is not this Mac's port either.",
            hint: "Your ~/.ssh/config still forwards \(probedPort). Re-run step 1 to move it to "
                + "\(allocatedPort), then step 2 so the host posts there too.",
            detail: "The check followed ~/.ssh/config (port \(probedPort)) rather than this "
                + "install's allocation (port \(allocatedPort))."
        )
    }

    /// - Parameter staleAllocatedPort: non-nil when the probe followed
    ///   `~/.ssh/config` to a port that is NOT this Mac's allocation. Every
    ///   verdict then says so, because "the tunnel on 8473 is fine" is the
    ///   right answer to the wrong question until step 1 is re-run.
    package static func tunnelCheck(
        result: RunResult,
        sshHostAlias: String,
        remoteForwardPort: UInt16,
        listenerIsBound: Bool,
        staleAllocatedPort: UInt16? = nil
    ) -> VerificationCheck {
        guard result.succeeded else {
            return VerificationCheck(
                kind: .tunnel,
                passed: false,
                summary: "Could not reach \(sshHostAlias) over SSH.",
                hint: "Run `ssh \(sshHostAlias) true` in a terminal to see why.",
                detail: "ssh exited with code \(result.exitCode)."
            )
        }

        // Only our own framed line decides anything; everything else the
        // connection printed is ignored by construction.
        let answer = framedProbeAnswer(in: result.message)

        if answer == missingCurlSentinel {
            return VerificationCheck(
                kind: .tunnel,
                passed: false,
                summary: "curl is missing on \(sshHostAlias).",
                hint: "The plugin's hooks are a curl one-liner. Install curl there.",
                detail: "The probe reported no curl on the host."
            )
        }

        // A code is three digits or it is not a code. Anything else — including
        // no framed line at all, which means the script never got to print one
        // — is "nothing answered", not a status.
        let code = httpCode(in: result)

        // A tunnel on a port this Mac no longer allocates is its own answer,
        // whichever way the probe came back: reporting only "up" or "nothing"
        // would describe a port the enrollment in front of the user does not
        // name.
        if let staleAllocatedPort {
            switch code {
            case "401":
                return staleConfigTunnelCheck(
                    probedPort: remoteForwardPort,
                    allocatedPort: staleAllocatedPort,
                    tunnelIsUp: listenerIsBound
                )
            case "000", nil:
                return staleConfigTunnelCheck(
                    probedPort: remoteForwardPort,
                    allocatedPort: staleAllocatedPort,
                    tunnelIsUp: false
                )
            default:
                break
            }
        }

        switch code {
        case "401":
            // 401 is the pass — an unauthenticated probe MUST be refused — but
            // only half of it. It proves the request crossed the tunnel and
            // something on this Mac answered; that the something was us is the
            // caller's fact, not the host's, and `reconciled` re-checks it after
            // the probes return.
            guard listenerIsBound else {
                return squatterTunnelCheck(remoteForwardPort: remoteForwardPort)
            }
            return passingTunnelCheck()
        case "000", nil:
            return listenerIsBound
                ? VerificationCheck(
                    kind: .tunnel,
                    passed: false,
                    summary: noLiveTunnelSummary,
                    hint: "The forward exists only while an SSH session to \(sshHostAlias) is open.",
                    detail: "Nothing answered on the host's 127.0.0.1:\(remoteForwardPort)."
                )
                : VerificationCheck(
                    kind: .tunnel,
                    passed: false,
                    summary: "Nothing answered, and localvoxtral is not listening here.",
                    hint: "Fix the listener on this Mac first. This check cannot tell you "
                        + "anything about the tunnel until it is bound.",
                    detail: "Nothing answered on the host's 127.0.0.1:\(remoteForwardPort), "
                        + "and this Mac's listener was not bound."
                )
        case .some(let code):
            return VerificationCheck(
                kind: .tunnel,
                passed: false,
                summary: "Something else answered on port \(remoteForwardPort).",
                hint: "Only localvoxtral should answer there. Find what holds the port and quit it.",
                // Three digits this process validated, not remote text passed
                // through.
                detail: "The reply was HTTP \(code)."
            )
        }
    }

    package static func pluginCheck(result: RunResult, sshHostAlias: String) -> VerificationCheck {
        // `contains` reads the output; nothing below emits it. See
        // `executeVerification` for why that line is absolute here.
        // BOTH halves, not either: 127 is the shell's generic "command not
        // found" and any command in a future probe could produce it, while the
        // message is OUR preamble speaking. Claiming "Claude Code is not
        // installed" off a bare 127 sends the user to install something that is
        // already there (review finding, round 3).
        if result.exitCode == 127, result.message.contains("'claude' was not found") {
            return VerificationCheck(
                kind: .plugin,
                passed: false,
                summary: "Claude Code was not found on \(sshHostAlias).",
                hint: "Install Claude Code there, or put it on the non-interactive SSH PATH.",
                detail: "The host's non-interactive shell could not resolve `claude` "
                    + "(the probe's own PATH resolver reported it and exited 127)."
            )
        }
        guard result.succeeded else {
            return VerificationCheck(
                kind: .plugin,
                passed: false,
                summary: "Could not list plugins on \(sshHostAlias).",
                hint: "Run `ssh \(sshHostAlias) true` in a terminal to see whether the host is reachable.",
                detail: "`claude plugin list` exited with code \(result.exitCode)."
            )
        }
        guard result.message.contains(ClaudePluginAssets.remotePluginName) else {
            return VerificationCheck(
                kind: .plugin,
                passed: false,
                summary: "The plugin is not installed on \(sshHostAlias).",
                hint: "Run step 2 on the host.",
                detail: "`claude plugin list` did not name \(ClaudePluginAssets.remotePluginName)."
            )
        }
        return VerificationCheck(
            kind: .plugin,
            passed: true,
            summary: "The plugin is installed.",
            // The constant we searched for, never the line we found it in: that
            // line can carry the plugin's stored token.
            detail: "`claude plugin list` named \(ClaudePluginAssets.remotePluginName)."
        )
    }
}
