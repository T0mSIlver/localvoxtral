import ClaudeContextWire
import Foundation
import Observation
import Synchronization

/// The Inbox page's observable face (#725). The work is
/// `QuickCaptureInboxModel`'s, in the core so Linux tests reach it; this
/// wraps it for SwiftUI and builds its router and drafter from Settings.
@MainActor
@Observable
final class QuickCaptureInboxViewModel {
    private(set) var items: [QuickCaptureItem] = []
    /// Bumped when a project's repository, GitHub description or filing
    /// choice lands, so the Projects pane reads them again.
    private(set) var projectsRevision = 0
    /// The agent sessions running now and the enrolled hosts, for the
    /// Projects pane (#939). The app sets them; empty in tests and previews.
    @ObservationIgnored var liveSessions: @MainActor () -> [ClaudeSessionSnapshot] = { [] }
    @ObservationIgnored var enrolledHosts: @MainActor () -> [(id: String, name: String)] = { [] }
    @ObservationIgnored let model: QuickCaptureInboxModel
    @ObservationIgnored private let store: LearnedTermStore?
    @ObservationIgnored private let learnedTerms: @MainActor () -> LearnedTerms
    @ObservationIgnored private let linker: QuickCaptureProjectLinker?

    init(
        settings: SettingsStore,
        learnedTerms: @escaping @MainActor () -> LearnedTerms,
        learnedTermStore: LearnedTermStore? = nil,
        fileURL: URL?,
        applicationSupport: URL,
        github: any QuickCaptureGitHub = QuickCaptureGHClient(),
        usageRecorder: (any UsageRecording)? = nil
    ) {
        let remote = RemoteDraftsSlot()
        let drafter = QuickCaptureDrafter(
            runner: QuickCaptureDraftProcessRunner(
                vibeHome: applicationSupport.appendingPathComponent("vibe-home", isDirectory: true),
                userVibeDirectory: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".vibe", isDirectory: true)
            ),
            openIssues: { await github.openIssues(ofCheckout: $0, repository: $1) },
            context: { root, repository, capture in
                await QuickCaptureContextGatherer(
                    run: QuickCaptureContextGatherer.processRun(),
                    openIssues: { await github.openIssues(ofCheckout: $0, repository: $1) },
                    checkoutRepository: { await github.repository(ofCheckout: $0) }
                ).gather(root: root, repository: repository, capture: capture)
            },
            remote: { capture, project, firstDrafter, onFirstDraft in
                guard let requests = remote.value.withLock({ $0 }) else { return .notRun(.remoteProject) }
                return await requests.draft(
                    capture: capture, project: project, firstDrafter: firstDrafter, onFirstDraft: onFirstDraft
                )
            },
            usageRecorder: usageRecorder
        )
        remoteSlot = remote
        model = QuickCaptureInboxModel(
            fileURL: fileURL,
            makeRouter: { QuickCaptureRouter(classifiers: Self.classifiers(settings: settings, usageRecorder: usageRecorder)) },
            projects: {
                QuickCaptureProjects.projects(
                    from: learnedTerms(),
                    userLines: settings.quickCaptureProjectLines,
                    now: Date(),
                    readme: { QuickCaptureProjects.readme(atRoot: $0) }
                )
            },
            agents: { [.claude, .vibe, .opencode] },
            drafter: { drafter.withFirstDrafter(Self.firstDrafter(settings: settings, usageRecorder: usageRecorder)) },
            github: github
        )
        store = learnedTermStore
        self.learnedTerms = learnedTerms
        linker = learnedTermStore.map { QuickCaptureProjectLinker(store: $0, github: github) }
        items = model.items
        model.onChange = { [weak self] in
            guard let self else { return }
            self.items = self.model.items
        }
        model.onRepositoryAnswered = { [weak learnedTermStore] key, repository in
            learnedTermStore?.recordTypedRepository(repository, projectKey: key)
        }
        Task { [weak self] in await self?.refreshProjects() }
    }

    /// Links the projects to their repositories and GitHub's descriptions
    /// (#926): at launch and after each capture for what is missing or a
    /// week old, everything when the Projects pane opens.
    func refreshProjects(force: Bool = false) async {
        guard let store, let linker else { return }
        _ = await store.loadedSnapshot()
        await linker.refresh(force: force).value
        _ = await store.loadedSnapshot()
        projectsRevision += 1
    }

    /// Takes a capture, then links any project it is the first sign of.
    func capture(text: String, historyRecordID: UUID?) {
        _ = model.capture(text: text, historyRecordID: historyRecordID)
        Task { [weak self] in await self?.refreshProjects() }
    }

    /// The "File issues here" choice for a fork.
    func setFilesUpstream(_ upstream: Bool, repository: String) async {
        guard let store else { return }
        store.setFilesUpstream(upstream, repository: repository)
        _ = await store.loadedSnapshot()
        projectsRevision += 1
    }

    /// The `owner/name` the user gave a project with no GitHub `origin`,
    /// then GitHub's description of it.
    func setTypedRepository(_ repository: String, projectKey: String) async {
        guard let store else { return }
        store.recordTypedRepository(repository, projectKey: projectKey)
        await refreshProjects()
    }

    /// The Projects pane's rows (#939).
    ///
    /// - Parameter dictationProjectKeys: the project key of each dictation
    ///   in the last seven days.
    func projectRows(dictationProjectKeys: [String?]) -> [ProjectsPaneRow] {
        _ = projectsRevision
        return ProjectsPane.rows(
            projects: model.projectChoices,
            learned: learnedTerms(),
            captures: items,
            hostNames: enrolledHosts(),
            liveSessions: liveSessions(),
            dictationProjectKeys: dictationProjectKeys
        )
    }

    /// The Projects table's "No project" entry (#972): the terms outside
    /// every row.
    func unlistedTerms() -> ProjectsPaneUnlisted? {
        ProjectsPane.unlisted(learned: learnedTerms(), rows: projectRows(dictationProjectKeys: []))
    }

    @ObservationIgnored private var remoteSlot: RemoteDraftsSlot?

    /// Lets a remote project's host draft its captures (#745). Nil, as
    /// without enrolled hosts, leaves them undrafted.
    func attachRemote(_ requests: RemoteQuickCaptureRequests?) {
        remoteSlot?.value.withLock { $0 = requests }
    }

    private final class RemoteDraftsSlot: Sendable {
        let value = Mutex<RemoteQuickCaptureRequests?>(nil)
    }

    static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("localvoxtral", isDirectory: true)
            .appendingPathComponent("quick-captures.json")
    }

    var waitingCount: Int { items.filter { $0.state != .filed }.count }

    /// The router Settings picked (#918): the polishing model by default,
    /// Jev first when chosen and a key is set, with the polishing model as
    /// its fallback. With neither, every capture waits in the Inbox for the
    /// user to place it.
    static func classifiers(
        settings: SettingsStore, usageRecorder: (any UsageRecording)? = nil
    ) -> [any QuickCaptureClassifying] {
        var classifiers: [any QuickCaptureClassifying] = []
        let useJev = settings.quickCaptureRouter == .jev
        if useJev { settings.ensureSecretsLoaded([.jevAPIKey]) }
        let jevKey = settings.jevAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if useJev, !jevKey.isEmpty {
            classifiers.append(JevClassifier(
                host: jevHost(forKey: jevKey), apiKey: jevKey, usageRecorder: usageRecorder))
        }
        if let polishing = settings.llmPolishingConfiguration {
            classifiers.append(QuickCaptureChatClassifier(
                endpoint: LLMPolishingService.normalizedChatCompletionsURL(polishing.endpointURL),
                apiKey: polishing.apiKey,
                model: polishing.model,
                extraBody: chatExtraBody(polishing),
                usageBackend: polishing.usageBackend,
                usageRecorder: usageRecorder
            ))
        }
        return classifiers
    }

    /// The first draft's writer (#918): the polishing model, at low
    /// reasoning effort on the Mistral shape. Nil without a polishing
    /// configuration; the agent then drafts alone.
    static func firstDrafter(
        settings: SettingsStore, usageRecorder: (any UsageRecording)? = nil
    ) -> (any QuickCaptureFirstDrafting)? {
        guard let polishing = settings.llmPolishingConfiguration else { return nil }
        return QuickCaptureFirstDrafter(
            endpoint: LLMPolishingService.normalizedChatCompletionsURL(polishing.endpointURL),
            apiKey: polishing.apiKey,
            model: polishing.model,
            extraBody: firstDraftExtraBody(polishing),
            usageBackend: polishing.usageBackend,
            usageRecorder: usageRecorder
        )
    }

    /// The model's lowest reasoning effort on the Mistral shape, whatever
    /// polish uses: GLM's `low`, Mistral's own `none` (it rejects `low`).
    /// At a higher effort GLM 5.3's reasoning once used the whole token cap
    /// (#918). A self-hosted server keeps its polish switches.
    static func firstDraftExtraBody(_ configuration: LLMPolishingConfiguration) -> [String: any Sendable] {
        guard configuration.requestShape == .mistral else { return chatExtraBody(configuration) }
        guard let wireValue = MistralReasoningEffort.forModel(configuration.model).wireValue else { return [:] }
        return ["reasoning_effort": wireValue]
    }

    /// Vercel AI Gateway keys start `vck_`; any other key is TypeSafe's.
    static func jevHost(forKey key: String) -> Jev.Host {
        key.hasPrefix("vck_") ? .vercelGateway : .typesafe
    }

    /// The fields the polish request adds that change whether a reasoning
    /// model answers quickly: the Mistral shape's reasoning effort, or a
    /// self-hosted server's chat template switches and thinking budget.
    static func chatExtraBody(_ configuration: LLMPolishingConfiguration) -> [String: any Sendable] {
        if configuration.requestShape == .mistral {
            let effort = configuration.mistralReasoningEffort ?? MistralReasoningEffort.forModel(configuration.model)
            guard let wireValue = effort.wireValue else { return [:] }
            return ["reasoning_effort": wireValue]
        }
        var extra: [String: any Sendable] = [:]
        if let arguments = configuration.chatTemplateArguments { extra["chat_template_kwargs"] = arguments }
        if let budget = configuration.thinkingBudgetTokens { extra["thinking_budget_tokens"] = budget }
        return extra
    }
}
