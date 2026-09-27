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
        /// Settings > Remote hosts > Keep the tunnel open.
        package var keepsTunnelOpen: Bool
        /// The highest plugin version the host's hooks reported since launch:
        /// a version, "1.9.0 or older" for a hook that sent none, nil when
        /// nothing was heard.
        package var reportedPluginVersion: String?

        package init(
            label: String,
            sshHostAlias: String? = nil,
            lastSeenAt: Date?,
            pluginNeedsUpdate: Bool,
            forwardFailure: String? = nil,
            keepsTunnelOpen: Bool = false,
            reportedPluginVersion: String? = nil
        ) {
            self.label = label
            self.sshHostAlias = sshHostAlias
            self.lastSeenAt = lastSeenAt
            self.pluginNeedsUpdate = pluginNeedsUpdate
            self.forwardFailure = forwardFailure
            self.keepsTunnelOpen = keepsTunnelOpen
            self.reportedPluginVersion = reportedPluginVersion
        }
    }

    /// One dictation's join line (`ClaudeSessionJoinSummary.noticeText`) and
    /// when it was resolved.
    package struct JoinLine: Sendable, Equatable {
        package var at: Date
        package var line: String

        package init(at: Date, line: String) {
            self.at = at
            self.line = line
        }
    }

    /// Where `/usr/local/bin/localvoxtral` points, against the running app.
    package struct CommandLink: Sendable, Equatable {
        package var state: AgentCLIInstallState
        /// The link's destination as written, nil when it is not a link.
        package var target: String?

        package init(state: AgentCLIInstallState, target: String? = nil) {
            self.state = state
            self.target = target
        }
    }

    /// The running app: its version and where it runs from, which tells an
    /// `/Applications` copy from a `try-pr.sh` one.
    package var appVersion: String?
    package var appBundlePath: String?
    package var commandLink: CommandLink?
    package var microphone: Permission
    package var accessibilityTrusted: Bool
    package var speech: Engine
    package var polish: Engine
    /// Nil when the app runs no integration model.
    package var claudePlugin: ClaudePluginStatus?
    /// With whether a Codex hook reached the app: an installed plugin whose
    /// hooks Codex never trusted runs nothing.
    package var codexPlugin: CodexPluginInstallService.Status?
    package var codexHookHeard: Bool
    package var opencodePlugin: OpencodePluginInstallService.Status?
    package var vibeHooks: VibeHooksInstallService.Status?
    /// The dictation note per agent; an agent left out is not checked.
    package var dictationNotes: [DictationNoteAgent: DictationNoteInstallService.Status]
    /// Enrolled hosts, revoked ones left out.
    package var remoteHosts: [RemoteHost]
    /// The last dictations' join lines, most recent first; empty when
    /// nothing was dictated since launch.
    package var recentJoins: [JoinLine]
    package var now: Date

    package init(
        appVersion: String? = nil,
        appBundlePath: String? = nil,
        commandLink: CommandLink? = nil,
        microphone: Permission,
        accessibilityTrusted: Bool,
        speech: Engine,
        polish: Engine,
        claudePlugin: ClaudePluginStatus?,
        codexPlugin: CodexPluginInstallService.Status? = nil,
        codexHookHeard: Bool = false,
        opencodePlugin: OpencodePluginInstallService.Status? = nil,
        vibeHooks: VibeHooksInstallService.Status? = nil,
        dictationNotes: [DictationNoteAgent: DictationNoteInstallService.Status] = [:],
        remoteHosts: [RemoteHost],
        recentJoins: [JoinLine],
        now: Date
    ) {
        self.appVersion = appVersion
        self.appBundlePath = appBundlePath
        self.commandLink = commandLink
        self.microphone = microphone
        self.accessibilityTrusted = accessibilityTrusted
        self.speech = speech
        self.polish = polish
        self.claudePlugin = claudePlugin
        self.codexPlugin = codexPlugin
        self.codexHookHeard = codexHookHeard
        self.opencodePlugin = opencodePlugin
        self.vibeHooks = vibeHooks
        self.dictationNotes = dictationNotes
        self.remoteHosts = remoteHosts
        self.recentJoins = recentJoins
        self.now = now
    }
}

/// The checks, in the order a dictation needs them: the app, permissions,
/// engines, the agent integrations, then what the last dictations joined.
/// Every check that is not fine names one step that fixes it.
package enum AgentCLIDoctorChecks {
    package static func checks(_ facts: AgentCLIDoctorFacts) -> [AgentCLICheck] {
        var checks = [app(facts, withPath: true)]
        if let link = facts.commandLink { checks.append(commandLink(link, appBundlePath: facts.appBundlePath)) }
        checks += [microphone(facts.microphone), accessibility(facts.accessibilityTrusted)]
        checks.append(engine(id: "speech", title: "Speech engine", facts.speech))
        checks.append(engine(id: "polish", title: "Polish engine", facts.polish))
        checks.append(claudePlugin(facts.claudePlugin))
        if let status = facts.codexPlugin { checks.append(codexPlugin(status, hookHeard: facts.codexHookHeard)) }
        if let status = facts.opencodePlugin { checks.append(opencodePlugin(status)) }
        if let status = facts.vibeHooks { checks.append(vibeHooks(status)) }
        for agent in DictationNoteAgent.allCases {
            if let status = facts.dictationNotes[agent] { checks.append(dictationNote(agent, status)) }
        }
        checks += remoteHosts(facts.remoteHosts, now: facts.now)
        checks.append(lastJoin(facts.recentJoins, now: facts.now))
        return checks
    }

    /// What a remote host's own `doctor` gets from this Mac: no path, no
    /// other host, nothing about the agents on this Mac. `hostIndex` picks the
    /// host whose token asked, nil when it is not in `facts`.
    package static func hostChecks(_ facts: AgentCLIDoctorFacts, hostIndex: Int?) -> [AgentCLICheck] {
        var checks = [app(facts, withPath: false)]
        checks += [microphone(facts.microphone), accessibility(facts.accessibilityTrusted)]
        checks.append(engine(id: "speech", title: "Speech engine", facts.speech, withSummary: false))
        checks.append(engine(id: "polish", title: "Polish engine", facts.polish, withSummary: false))
        if let hostIndex, facts.remoteHosts.indices.contains(hostIndex) {
            var check = remoteHost(facts.remoteHosts[hostIndex], id: "remote-host", now: facts.now)
            // The host is the one asking: "run doctor on the host" is where it is.
            if check.fix == keepTunnelOpenHostFix { check.fix = keepTunnelOpenHostFixFromHost }
            checks.append(check)
        }
        checks.append(lastJoin(facts.recentJoins, now: facts.now))
        return checks
    }

    static func app(_ facts: AgentCLIDoctorFacts, withPath: Bool) -> AgentCLICheck {
        var detail = "localvoxtral \(facts.appVersion ?? "(unknown version)")"
        if withPath, let path = facts.appBundlePath { detail += ", running from \(path)" }
        return AgentCLICheck(id: "app", title: "App", state: .ok, detail: detail + ".")
    }

    static func commandLink(_ link: AgentCLIDoctorFacts.CommandLink, appBundlePath: String?) -> AgentCLICheck {
        let id = "command-link"
        let title = "Command"
        let path = AgentCLIInstallState.linkPath
        switch link.state {
        case .installed:
            return AgentCLICheck(id: id, title: title, state: .ok, detail: "\(path) points to this app.")
        case .notInstalled:
            return AgentCLICheck(
                id: id, title: title, state: .skipped, detail: "\(path) is not installed.",
                fix: "Settings > General > Command-line tool > Install…"
            )
        case .otherCopy:
            let running = appBundlePath.map { ", but the app running is \($0)" } ?? ""
            return AgentCLICheck(
                id: id, title: title, state: .warning,
                detail: "\(path) points to \(link.target ?? "another copy of the app")\(running).",
                fix: "Settings > General > Command-line tool > Update…, or quit this copy and open the other one."
            )
        case .foreign:
            return AgentCLICheck(
                id: id, title: title, state: .warning,
                detail: "\(path) is not a link to localvoxtral\(link.target.map { "; it points to \($0)" } ?? "").",
                fix: "Move \(path) away, then Settings > General > Command-line tool > Install…"
            )
        }
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

    /// `withSummary: false` leaves out a failed engine's summary, which can
    /// name a local path.
    static func engine(
        id: String, title: String, _ engine: AgentCLIDoctorFacts.Engine, withSummary: Bool = true
    ) -> AgentCLICheck {
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
                    id: id, title: title, state: .failed,
                    detail: withSummary ? "On this Mac, failed: \(summary)" : "On this Mac, failed.",
                    fix: "Start a dictation; it starts the engine again. "
                        + "Settings > About > Export diagnostics… saves its recent output."
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

    static func codexPlugin(_ status: CodexPluginInstallService.Status, hookHeard: Bool) -> AgentCLICheck {
        let id = "codex-plugin"
        let title = "Codex plugin"
        switch status {
        case .unknown:
            return AgentCLICheck(
                id: id, title: title, state: .skipped, detail: "Codex was not found, or `codex plugin list` failed."
            )
        case .notInstalled:
            return AgentCLICheck(
                id: id, title: title, state: .skipped, detail: "Not installed.",
                fix: "To join Codex sessions: Settings > Codex > Install."
            )
        case .disabled:
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: "Installed, turned off in Codex's plugin list.",
                fix: "Turn localvoxtral on in Codex's plugin list, then restart Codex sessions."
            )
        case .installed where !hookHeard:
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: "Installed; no Codex hook has reached the app yet.",
                fix: "Start Codex and trust the localvoxtral hooks when it asks."
            )
        case .installed:
            return AgentCLICheck(id: id, title: title, state: .ok, detail: "Installed, hooks heard.")
        case .updateAvailable:
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: "Installed at another version than this app ships.",
                fix: "Settings > Codex > Update, then restart Codex sessions."
            )
        }
    }

    static func opencodePlugin(_ status: OpencodePluginInstallService.Status) -> AgentCLICheck {
        let id = "opencode-plugin"
        let title = "opencode plugin"
        let detail = OpencodePluginInstallService.sentence(for: status)
        let button = OpencodePluginInstallService.setupButtonTitle(for: status) ?? "Set up…"
        switch status {
        case .installed:
            return AgentCLICheck(id: id, title: title, state: .ok, detail: detail)
        case .notInstalled:
            return AgentCLICheck(
                id: id, title: title, state: .skipped, detail: detail,
                fix: "To join opencode sessions: Settings > opencode > \(button)"
            )
        case .updateAvailable:
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: detail,
                fix: "Settings > opencode > \(button), then restart opencode."
            )
        case .listedMissing, .installedUnlisted, .unknown:
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: detail,
                fix: "Settings > opencode > \(button)"
            )
        }
    }

    static func vibeHooks(_ status: VibeHooksInstallService.Status) -> AgentCLICheck {
        let id = "vibe-hooks"
        let title = "Mistral Vibe hooks"
        let detail = VibeHooksInstallService.sentence(for: status)
        let button = VibeHooksInstallService.setupButtonTitle(for: status) ?? "Set up…"
        switch status {
        case .installed:
            return AgentCLICheck(id: id, title: title, state: .ok, detail: detail)
        case .notInstalled:
            return AgentCLICheck(
                id: id, title: title, state: .skipped, detail: detail,
                fix: "To join Vibe sessions: Settings > Mistral Vibe > \(button)"
            )
        case .updateAvailable:
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: detail,
                fix: "Settings > Mistral Vibe > \(button), then restart Vibe sessions."
            )
        case .conflictingHooks:
            return AgentCLICheck(
                id: id, title: title, state: .failed, detail: detail,
                fix: "Settings > Mistral Vibe names the line to fix in ~/.vibe/hooks.toml."
            )
        case .hooksWithoutShim, .shimWithoutHooks, .unknown:
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: detail,
                fix: "Settings > Mistral Vibe > \(button)"
            )
        }
    }

    /// The pane each agent's note row sits in.
    static func paneTitle(_ agent: DictationNoteAgent) -> String { agent.displayName }

    static func dictationNote(
        _ agent: DictationNoteAgent, _ status: DictationNoteInstallService.Status
    ) -> AgentCLICheck {
        let id = "dictation-note.\(agent.rawValue)"
        let title = "Dictation note for \(agent.displayName)"
        let detail = DictationNoteInstallService.sentence(for: status)
        let row = "Settings > \(paneTitle(agent)) > Tell \(agent.displayName) you dictate"
        switch status {
        case .added:
            return AgentCLICheck(id: id, title: title, state: .ok, detail: detail)
        case .notAdded:
            return AgentCLICheck(id: id, title: title, state: .skipped, detail: detail, fix: "\(row) > Add.")
        case .differs:
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: detail,
                fix: "\(row) > Update, then restart \(agent.displayName) sessions."
            )
        case .needsManualFix(let path, _):
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: detail,
                fix: "Edit \(DictationNoteInstallService.displayPath(path)) by hand: the note is the block "
                    + "between the localvoxtral dictation note markers."
            )
        case .unknown:
            return AgentCLICheck(id: id, title: title, state: .skipped, detail: detail)
        }
    }

    /// A host that never sent context over a day after enrolling reads the
    /// same as one whose tunnel died: both mean no hook reaches this Mac.
    static let silentHostAge: TimeInterval = 24 * 3_600

    static let keepTunnelOpenHostFix = "The app holds the tunnel. On the host, `localvoxtral doctor` "
        + "(from the remote plugin) checks the port, the token and the plugin sessions run."
    static let keepTunnelOpenHostFixFromHost = "The app holds the tunnel; the host-side checks above say "
        + "which end is missing."

    static func remoteHosts(_ hosts: [AgentCLIDoctorFacts.RemoteHost], now: Date) -> [AgentCLICheck] {
        guard !hosts.isEmpty else {
            return [AgentCLICheck(id: "remote-hosts", title: "Remote hosts", state: .skipped, detail: "None enrolled.")]
        }
        return hosts.enumerated().map { index, host in
            remoteHost(host, id: "remote-host.\(index + 1)", now: now)
        }
    }

    static func remoteHost(_ host: AgentCLIDoctorFacts.RemoteHost, id: String, now: Date) -> AgentCLICheck {
        let title = "Remote host \(host.label)"
        let plugin = host.reportedPluginVersion.map { " Plugin \($0)." } ?? ""
        let tunnel = host.keepsTunnelOpen ? " Keep the tunnel open is on." : ""
        if let failure = host.forwardFailure {
            return AgentCLICheck(
                id: id, title: title, state: .failed, detail: "The tunnel failed: \(failure)",
                fix: host.sshHostAlias.map { "Run `ssh \($0) true` in a terminal to see ssh's own error." }
                    ?? "Settings > Remote hosts: remove the host and enroll it again with its SSH alias."
            )
        }
        if host.pluginNeedsUpdate {
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: "Its plugin is older than this app.\(plugin)",
                fix: "Settings > Remote hosts > Update Host…, then restart the agent sessions on that host."
            )
        }
        guard let lastSeen = host.lastSeenAt else {
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: "Never sent context.\(tunnel)",
                fix: host.keepsTunnelOpen
                    ? keepTunnelOpenHostFix
                    : "Settings > Remote hosts: turn on Keep the tunnel open. "
                        + "Without it, only the first ssh session to the host carries the tunnel."
            )
        }
        let age = now.timeIntervalSince(lastSeen)
        let detail = "Last context \(ageText(age)) ago.\(plugin)\(tunnel)"
        guard age < silentHostAge else {
            return AgentCLICheck(
                id: id, title: title, state: .warning, detail: detail,
                fix: host.keepsTunnelOpen
                    ? keepTunnelOpenHostFix
                    : "If you worked there since, turn on Keep the tunnel open in Settings > Remote hosts."
            )
        }
        return AgentCLICheck(id: id, title: title, state: .ok, detail: detail)
    }

    private static func ageText(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h" }
        return "\(hours / 24) days"
    }

    /// How many join lines the app keeps.
    package static let recentJoinLimit = 5

    /// The state follows the most recent dictation; `lines` holds them all,
    /// most recent first, each with its age.
    static func lastJoin(_ joins: [AgentCLIDoctorFacts.JoinLine], now: Date) -> AgentCLICheck {
        let id = "last-join"
        let title = "Last dictation's session"
        guard let last = joins.first else {
            return AgentCLICheck(id: id, title: title, state: .skipped, detail: "Nothing dictated since launch.")
        }
        let lines = joins.prefix(recentJoinLimit).map { "\(ageText(now.timeIntervalSince($0.at))) ago: \($0.line)" }
        guard last.line.hasPrefix("arm=none") else {
            return AgentCLICheck(id: id, title: title, state: .ok, detail: last.line, lines: lines)
        }
        return AgentCLICheck(
            id: id, title: title, state: .warning, detail: last.line,
            fix: "Joined no agent session. If you dictated into one, `causes` names the step that stopped it; "
                + "see How a dictation finds its session in docs/coding-agents.md.",
            lines: lines
        )
    }
}
