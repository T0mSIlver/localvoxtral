import ClaudeContextWire
import Foundation

/// What `localvoxtral doctor` reads from the running app, as plain values.
/// The app fills it from its permission, engine and integration models; the
/// checks below are the part that needs no app, so they run in tests.
package struct AgentCLIDoctorFacts: Sendable, Equatable {
    package enum Permission: Sendable, Equatable {
        case granted
        case denied
        case restricted
        case notAsked
    }

    package enum Engine: Sendable, Equatable {
        case managed(ManagedBackendStatus)
        case mistralAPI(keySet: Bool)
        /// A server the user runs; the app does not check it.
        case externalURL
        case off
    }

    package struct RemoteHost: Sendable, Equatable {
        package var label: String
        package var sshHostAlias: String?
        package var lastSeenAt: Date?
        package var pluginNeedsUpdate: Bool
        /// The app-held forward's failure sentence, nil when it has none.
        package var forwardFailure: String?

        package init(
            label: String,
            sshHostAlias: String? = nil,
            lastSeenAt: Date?,
            pluginNeedsUpdate: Bool,
            forwardFailure: String? = nil
        ) {
            self.label = label
            self.sshHostAlias = sshHostAlias
            self.lastSeenAt = lastSeenAt
            self.pluginNeedsUpdate = pluginNeedsUpdate
            self.forwardFailure = forwardFailure
        }
    }

    package var microphone: Permission
    package var accessibilityTrusted: Bool
    package var speech: Engine
    package var polish: Engine
    /// Nil when the app runs no integration model.
    package var claudePlugin: ClaudePluginStatus?
    /// Enrolled hosts, revoked ones left out.
    package var remoteHosts: [RemoteHost]
    /// The last dictation's join line (`ClaudeSessionJoinSummary.noticeText`),
    /// nil when nothing was dictated since launch.
    package var lastJoinLine: String?
    package var now: Date

    package init(
        microphone: Permission,
        accessibilityTrusted: Bool,
        speech: Engine,
        polish: Engine,
        claudePlugin: ClaudePluginStatus?,
        remoteHosts: [RemoteHost],
        lastJoinLine: String?,
        now: Date
    ) {
        self.microphone = microphone
        self.accessibilityTrusted = accessibilityTrusted
        self.speech = speech
        self.polish = polish
        self.claudePlugin = claudePlugin
        self.remoteHosts = remoteHosts
        self.lastJoinLine = lastJoinLine
        self.now = now
    }
}

/// The checks, in the order a dictation needs them: permissions, engines,
/// the agent integrations, then what the last dictation joined. Every check
/// that is not fine names one step that fixes it.
package enum AgentCLIDoctorChecks {
    package static func checks(_ facts: AgentCLIDoctorFacts) -> [AgentCLICheck] {
        var checks = [microphone(facts.microphone), accessibility(facts.accessibilityTrusted)]
        checks.append(engine(id: "speech", title: "Speech engine", facts.speech))
        checks.append(engine(id: "polish", title: "Polish engine", facts.polish))
        checks.append(claudePlugin(facts.claudePlugin))
        checks += remoteHosts(facts.remoteHosts, now: facts.now)
        checks.append(lastJoin(facts.lastJoinLine))
        return checks
    }

    static func microphone(_ permission: AgentCLIDoctorFacts.Permission) -> AgentCLICheck {
        let title = "Microphone"
        switch permission {
        case .granted:
            return AgentCLICheck(id: "microphone", title: title, state: .ok, detail: "Allowed.")
        case .notAsked:
            return AgentCLICheck(
                id: "microphone", title: title, state: .warning, detail: "Not asked yet.",
                fix: "Start a dictation and allow the microphone. The dialog can open on another display."
            )
        case .denied:
            return AgentCLICheck(
                id: "microphone", title: title, state: .failed, detail: "Denied.",
                fix: "System Settings > Privacy & Security > Microphone: turn on localvoxtral."
            )
        case .restricted:
            return AgentCLICheck(
                id: "microphone", title: title, state: .failed, detail: "Blocked by a device profile.",
                fix: "Ask whoever manages this Mac to allow the microphone for localvoxtral."
            )
        }
    }

    static func accessibility(_ trusted: Bool) -> AgentCLICheck {
        trusted
            ? AgentCLICheck(id: "accessibility", title: "Accessibility", state: .ok, detail: "Allowed.")
            : AgentCLICheck(
                id: "accessibility", title: "Accessibility", state: .failed,
                detail: "Not allowed, so text cannot be inserted.",
                fix: "System Settings > Privacy & Security > Accessibility: turn localvoxtral off, then on. "
                    + "A copy with another signature loses the grant without saying so."
            )
    }

    static func engine(id: String, title: String, _ engine: AgentCLIDoctorFacts.Engine) -> AgentCLICheck {
        switch engine {
        case .off:
            return AgentCLICheck(id: id, title: title, state: .skipped, detail: "Off.")
        case .externalURL:
            return AgentCLICheck(id: id, title: title, state: .skipped, detail: "External URL, not checked.")
        case .mistralAPI(let keySet):
            return keySet
                ? AgentCLICheck(id: id, title: title, state: .ok, detail: "Mistral API, key set.")
                : AgentCLICheck(
                    id: id, title: title, state: .failed, detail: "Mistral API, no key.",
                    fix: "Settings > Engines: paste a Mistral API key."
                )
        case .managed(let status):
            switch status {
            case .ready:
                return AgentCLICheck(id: id, title: title, state: .ok, detail: "On this Mac, ready.")
            case .starting:
                return AgentCLICheck(id: id, title: title, state: .warning, detail: "On this Mac, starting.")
            case .stopped:
                return AgentCLICheck(
                    id: id, title: title, state: .warning, detail: "On this Mac, stopped.",
                    fix: "Start a dictation; the engine starts with it."
                )
            case .preparingModel(let progress):
                return AgentCLICheck(
                    id: id, title: title, state: .warning,
                    detail: "On this Mac, downloading the model\(percent(progress))."
                )
            case .pausedModelDownload(let progress):
                return AgentCLICheck(
                    id: id, title: title, state: .warning,
                    detail: "On this Mac, model download paused\(percent(progress)).",
                    fix: "Settings > Engines: resume the download."
                )
            case .failed(let summary, _):
                return AgentCLICheck(
                    id: id, title: title, state: .failed, detail: "On this Mac, failed: \(summary)",
                    fix: "Settings > Engines: restart the engine. "
                        + "Settings > About > Export Diagnostics… has its recent output."
                )
            }
        }
    }

    private static func percent(_ progress: ModelDownloadProgress) -> String {
        guard let total = progress.totalBytes, total > 0 else { return "" }
        return ", \(Int(Double(progress.downloadedBytes) / Double(total) * 100)) %"
    }

    static func claudePlugin(_ status: ClaudePluginStatus?) -> AgentCLICheck {
        let id = "claude-plugin"
        let title = "Claude Code plugin"
        switch status {
        case nil:
            return AgentCLICheck(id: id, title: title, state: .skipped, detail: "Not checked.")
        case .unknown:
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: "Could not list Claude Code's plugins.",
                fix: "Check that `claude plugin list` works in a terminal."
            )
        case .notInstalled:
            return AgentCLICheck(
                id: id, title: title, state: .skipped, detail: "Not installed.",
                fix: "To join Claude Code sessions: Settings > Claude Code > Install."
            )
        case .installed(let version):
            return AgentCLICheck(
                id: id, title: title, state: .ok, detail: version.map { "Installed \($0)." } ?? "Installed."
            )
        case .updateAvailable(let installed, let bundled):
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: "Installed \(installed), this app ships \(bundled).",
                fix: "Settings > Claude Code > Update, then restart Claude Code sessions: "
                    + "a running session keeps the hooks it started with."
            )
        case .failedToLoad:
            return AgentCLICheck(
                id: id, title: title, state: .failed,
                detail: "Installed, but Claude Code cannot read the marketplace it came from.",
                fix: "Settings > Claude Code > Repair."
            )
        }
    }

    /// A host that never sent context over a day after enrolling reads the
    /// same as one whose tunnel died: both mean no hook reaches this Mac.
    static let silentHostAge: TimeInterval = 24 * 3_600

    static func remoteHosts(_ hosts: [AgentCLIDoctorFacts.RemoteHost], now: Date) -> [AgentCLICheck] {
        guard !hosts.isEmpty else {
            return [AgentCLICheck(id: "remote-hosts", title: "Remote hosts", state: .skipped, detail: "None enrolled.")]
        }
        return hosts.enumerated().map { index, host in
            let id = "remote-host.\(index + 1)"
            let title = "Remote host \(host.label)"
            if let failure = host.forwardFailure {
                return AgentCLICheck(
                    id: id, title: title, state: .failed, detail: "The tunnel failed: \(failure)",
                    fix: host.sshHostAlias.map { "Run `ssh \($0) true` in a terminal to see ssh's own error." }
                        ?? "Settings > Remote hosts: remove the host and enroll it again with its SSH alias."
                )
            }
            if host.pluginNeedsUpdate {
                return AgentCLICheck(
                    id: id, title: title, state: .warning, detail: "Its plugin is older than this app.",
                    fix: "Settings > Remote hosts > Update, then restart the agent sessions on that host."
                )
            }
            guard let lastSeen = host.lastSeenAt else {
                return AgentCLICheck(
                    id: id, title: title, state: .warning, detail: "Never sent context.",
                    fix: "Settings > Remote hosts: turn on Keep the tunnel open. "
                        + "Without it, only the first ssh session to the host carries the tunnel."
                )
            }
            let age = now.timeIntervalSince(lastSeen)
            let detail = "Last context \(ageText(age)) ago."
            guard age < silentHostAge else {
                return AgentCLICheck(
                    id: id, title: title, state: .warning, detail: detail,
                    fix: "If you worked there since, turn on Keep the tunnel open in Settings > Remote hosts."
                )
            }
            return AgentCLICheck(id: id, title: title, state: .ok, detail: detail)
        }
    }

    private static func ageText(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h" }
        return "\(hours / 24) days"
    }

    static func lastJoin(_ line: String?) -> AgentCLICheck {
        let id = "last-join"
        let title = "Last dictation's session"
        guard let line else {
            return AgentCLICheck(id: id, title: title, state: .skipped, detail: "Nothing dictated since launch.")
        }
        guard line.hasPrefix("arm=none") else {
            return AgentCLICheck(id: id, title: title, state: .ok, detail: line)
        }
        return AgentCLICheck(
            id: id, title: title, state: .warning, detail: line,
            fix: "Joined no agent session. If you dictated into one, `causes` names the step that stopped it; "
                + "see How a dictation finds its session in docs/coding-agents.md."
        )
    }
}
