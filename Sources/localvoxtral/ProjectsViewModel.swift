import ClaudeContextWire
import Foundation
import Observation

/// The Projects pane's observable face (#939): the projects the learned
/// terms list, built by `ProjectsPane` in the core so Linux tests reach it.
/// It also links each local checkout to the repository its `origin` names,
/// so a repository's checkouts share one project (#971).
@MainActor
@Observable
final class ProjectsViewModel {
    /// Bumped when a checkout's repository or a project's group lands, so
    /// the Projects pane reads them again.
    private(set) var projectsRevision = 0
    /// The agent sessions running now and the enrolled hosts, for the
    /// Projects pane (#939). The app sets them; empty in tests and previews.
    @ObservationIgnored var liveSessions: @MainActor () -> [ClaudeSessionSnapshot] = { [] }
    @ObservationIgnored var enrolledHosts: @MainActor () -> [(id: String, name: String)] = { [] }
    @ObservationIgnored private let store: LearnedTermStore?
    @ObservationIgnored private let learnedTerms: @MainActor () -> LearnedTerms
    @ObservationIgnored private let linker: ProjectOriginLinker?

    init(
        learnedTerms: @escaping @MainActor () -> LearnedTerms,
        learnedTermStore: LearnedTermStore? = nil,
        origins: any CheckoutOriginReading = GitCheckoutOriginReader()
    ) {
        store = learnedTermStore
        self.learnedTerms = learnedTerms
        linker = learnedTermStore.map { ProjectOriginLinker(store: $0, origins: origins) }
        Task { [weak self] in await self?.refreshProjects() }
    }

    /// Links the local checkouts to their repositories: at launch, and each
    /// time the Projects pane opens, for the checkouts not read yet.
    func refreshProjects() async {
        guard let store, let linker else { return }
        _ = await store.loadedSnapshot()
        await linker.refresh().value
        _ = await store.loadedSnapshot()
        projectsRevision += 1
    }

    /// The Group column's choice for one row (#1005).
    func setGroup(_ group: ProjectGroup?, keys: [String]) async {
        guard let store else { return }
        store.setGroup(group, keys: keys)
        _ = await store.loadedSnapshot()
        projectsRevision += 1
    }

    /// The Projects pane's rows (#939).
    ///
    /// - Parameter dictationProjectKeys: the project key of each dictation
    ///   in the last seven days.
    func projectRows(dictationProjectKeys: [String?]) -> [ProjectsPaneRow] {
        _ = projectsRevision
        let learned = learnedTerms()
        return ProjectsPane.rows(
            projects: ListedProjects.projects(from: learned, now: Date()),
            learned: learned,
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
}
