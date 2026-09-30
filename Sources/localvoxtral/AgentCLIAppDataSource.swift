import ClaudeContextWire
import Foundation

/// What the `localvoxtral` command reads in the running app (#721): the
/// history store, the learned terms and Settings. The broker's connection
/// thread asks; everything here runs on the main actor, and the store reads
/// run on their own tasks as they do for the History pane.
@MainActor
final class AgentCLIAppDataSource: AgentCLIDataSource {
    private weak var viewModel: DictationViewModel?
    private weak var sessions: ClaudeSessionRegistry?

    init(viewModel: DictationViewModel, sessions: ClaudeSessionRegistry? = nil) {
        self.viewModel = viewModel
        self.sessions = sessions
    }

    func historyKept() async -> Bool {
        guard let viewModel else { return false }
        return viewModel.settings.dictationHistoryRetention.savesDictations && viewModel.sessionStore != nil
    }

    func dictations(matching text: String, since: Date?, limit: Int) async -> [AgentCLIDictation] {
        guard let store = viewModel?.sessionStore else { return [] }
        var query = DictationHistoryQuery()
        query.searchText = text
        query.since = since
        query.limit = limit
        return await store.entries(matching: query).map(Self.dictation)
    }

    /// The store's newest entry: every dictation with text is saved, inserted
    /// or not, and a read waits for the save still queued.
    func lastDictation() async -> AgentCLIDictation? {
        await viewModel?.sessionStore?.recentEntries(limit: 1).first.map(Self.dictation)
    }

    func userTerms() async -> [String] {
        viewModel?.settings.polishSpeakerTerms ?? []
    }

    func refusedTerms() async -> [String] {
        viewModel?.settings.polishDismissedTermSuggestions ?? []
    }

    func learnedTerms() async -> LearnedTerms {
        await viewModel?.learnedTermStore?.loadedSnapshot() ?? LearnedTerms()
    }

    func recordProposal(
        _ terms: [String],
        proposer: String,
        project: LearnedTermProjectIdentity,
        excluding: [String]
    ) async -> [String] {
        guard let store = viewModel?.learnedTermStore else { return [] }
        return await store.recordCommandProposal(terms, proposer: proposer, project: project, excluding: excluding)
    }

    func status() async -> AgentCLIStatus {
        guard let viewModel else { return .notRunning }
        let settings = viewModel.settings
        let polishModel: String = switch settings.polishingBackendMode {
        case .managedLocal: settings.resolvedManagedLLMPolishingModel
        case .mistralAPI: settings.resolvedMistralPolishingModel
        case .externalURL: settings.llmPolishingModel
        }
        return AgentCLIStatus(
            running: true,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            dictating: viewModel.isDictating,
            historyKept: await historyKept(),
            dictation: AgentCLIEngine(
                backend: settings.dictationBackendMode.rawValue,
                model: settings.effectiveModelName,
                enabled: true
            ),
            polish: AgentCLIEngine(
                backend: settings.polishingBackendMode.rawValue,
                model: polishModel,
                enabled: settings.llmPolishingEnabled
            ),
            lastJoin: viewModel.session.lastDictationJoin
        )
    }

    func doctorFacts() async -> AgentCLIDoctorFacts {
        guard let viewModel else {
            return AgentCLIDoctorFacts(
                microphone: .notAsked, accessibilityTrusted: false, speech: .off, polish: .off,
                claudePlugin: nil, remoteHosts: [], recentJoins: [], now: Date()
            )
        }
        let settings = viewModel.settings
        let backends = viewModel.backendManager
        let microphone: AgentCLIDoctorFacts.Permission = switch viewModel.session.currentMicrophoneAuthorizationStatus() {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notAsked
        }
        // Only the key an engine in use needs, the same key a dictation
        // would load: no Keychain prompt for one the user does not use.
        func mistralKeySet() -> Bool {
            settings.ensureSecretsLoaded([.mistralAPIKey])
            return !settings.mistralAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let speech: AgentCLIDoctorFacts.Engine = switch settings.dictationBackendMode {
        case .managedLocal: .managed(backends.speechdStatus)
        case .mistralAPI: .mistralAPI(keySet: mistralKeySet())
        case .externalURL: .externalURL
        }
        let polish: AgentCLIDoctorFacts.Engine = if !settings.llmPolishingEnabled {
            .off
        } else {
            switch settings.polishingBackendMode {
            case .managedLocal: .managed(backends.polishdStatus)
            case .mistralAPI: .mistralAPI(keySet: mistralKeySet())
            case .externalURL: .externalURL
            }
        }
        var facts = AgentCLIDoctorFacts(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBundlePath: Bundle.main.bundlePath,
            commandLink: Self.commandLink(),
            microphone: microphone,
            accessibilityTrusted: viewModel.isAccessibilityTrusted,
            speech: speech,
            polish: polish,
            claudePlugin: nil,
            remoteHosts: [],
            recentJoins: viewModel.context.recentJoinOutcomes,
            now: Date()
        )
        if let integration = viewModel.claudeIntegrationSettings {
            // Both list plugins through their CLI (1–3 s each), so together,
            // inside the broker's 10 s.
            async let claude: Void = integration.refreshLocalPluginStatus()
            async let codex: Void = integration.refreshCodexStatus()
            _ = await (claude, codex)
            integration.refreshOpencodeStatus()
            integration.refreshVibeStatus()
            integration.refreshDictationNoteStatuses()
            integration.refreshHosts()
            facts.claudePlugin = integration.localPluginStatus
            facts.codexPlugin = integration.codexStatus
            facts.codexHookHeard = integration.codexHookHeard
            facts.opencodePlugin = integration.opencodeStatus
            facts.vibeHooks = integration.vibeStatus
            facts.dictationNotes = integration.dictationNoteStatuses
            facts.remoteHosts = Self.remoteHosts(integration, sessions: sessions)
        }
        return facts
    }

    /// Enrolled hosts in the Remote hosts pane's order, revoked ones left out.
    static func remoteHosts(
        _ integration: ClaudeIntegrationSettingsModel, sessions: ClaudeSessionRegistry?
    ) -> [AgentCLIDoctorFacts.RemoteHost] {
        let registered = Dictionary(
            (integration.registry?.hosts() ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return integration.hosts.filter { !$0.isRevoked }.map { row in
            let host = registered[row.id]
            return AgentCLIDoctorFacts.RemoteHost(
                label: row.label,
                sshHostAlias: row.sshHostAlias,
                lastSeenAt: row.lastSeenAt,
                pluginNeedsUpdate: row.pluginNeedsUpdate,
                forwardFailure: row.forwardIsFailure ? row.forwardStatusText : nil,
                keepsTunnelOpen: row.persistentForwardEnabled,
                reportedPluginVersion: host?.reportedPluginVersion.map(AgentCLIDoctorChecks.versionText),
                installedPluginVersion: host?.reportedPluginVersion,
                installedVibeHooksVersion: host?.reportedVibeHooksVersion,
                sessions: (sessions?.liveRemoteSessions(hostID: row.id) ?? []).map(AgentCLIDoctorFacts.RemoteHost.Session.init)
            )
        }
    }

    /// Host-safe checks for the enrolled host with this id
    /// (`AgentCLIDoctorChecks.hostChecks`), for the remote listener's
    /// `/v1/doctor`.
    func hostDoctorChecks(hostID: String) async -> [AgentCLICheck] {
        let facts = await doctorFacts()
        let rows = viewModel?.claudeIntegrationSettings?.hosts.filter { !$0.isRevoked } ?? []
        return AgentCLIDoctorChecks.hostChecks(facts, hostIndex: rows.firstIndex { $0.id == hostID })
    }

    static func commandLink() -> AgentCLIDoctorFacts.CommandLink? {
        guard let binary = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent(AgentCLIInstallState.binaryName).path
        else { return nil }
        return AgentCLIDoctorFacts.CommandLink(
            state: AgentCLIInstallState.read(bundledBinary: binary),
            target: try? FileManager.default.destinationOfSymbolicLink(atPath: AgentCLIInstallState.linkPath)
        )
    }

    func captures() async -> [QuickCaptureItem]? {
        viewModel?.quickCapture?.model.items
    }

    func markCaptureFiled(
        _ id: UUID, url: String
    ) async -> Result<QuickCaptureItem, QuickCaptureInbox.MarkFiledRefusal>? {
        viewModel?.quickCapture?.model.markFiled(id, url: url)
    }

    /// History keeps the text with the clipboard placeholder, never the
    /// clipboard itself, and so does this.
    static func dictation(_ entry: DictationHistoryEntry) -> AgentCLIDictation {
        AgentCLIDictation(
            id: entry.id.uuidString,
            startedAt: entry.startedAt,
            finishedAt: entry.finishedAt,
            project: entry.projectKey.map { AgentCLIProject(key: $0, name: entry.projectName ?? $0) },
            agent: entry.joinedAgent,
            targetApp: entry.targetAppBundleID,
            rawText: entry.rawText,
            finalText: entry.finalText,
            inserted: entry.commitSucceeded,
            status: entry.status.rawValue
        )
    }
}
