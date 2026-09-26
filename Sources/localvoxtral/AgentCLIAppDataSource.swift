import ClaudeContextWire
import Foundation

/// What the `localvoxtral` command reads in the running app (#721): the
/// history store, the learned terms and Settings. The broker's connection
/// thread asks; everything here runs on the main actor, and the store reads
/// run on their own tasks as they do for the History pane.
@MainActor
final class AgentCLIAppDataSource: AgentCLIDataSource {
    private weak var viewModel: DictationViewModel?

    init(viewModel: DictationViewModel) {
        self.viewModel = viewModel
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
