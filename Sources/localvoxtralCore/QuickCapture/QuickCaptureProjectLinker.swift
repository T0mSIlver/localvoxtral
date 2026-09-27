import Foundation

/// Where a project's repository and GitHub's description of it are kept
/// (`LearnedTermStore`).
package protocol QuickCaptureProjectLinkStoring: Sendable {
    func snapshot() -> LearnedTerms
    func recordOriginRepository(_ repository: String, projectKey: String)
    func recordGitHub(_ facts: GitHubRepositoryFacts, repository: String)
}

/// Links quick capture's projects to GitHub (#926). A local checkout's
/// repository is its `origin`, read once a launch; a remote one's comes
/// from its host's hook (`RemoteQuickCaptureRequests.noteReport`). Then
/// `gh api` describes each repository once a week, or whenever the Projects
/// pane opens. Nothing here waits on the capture path: a
/// capture routes with what is already kept.
@MainActor
package final class QuickCaptureProjectLinker {
    private let store: any QuickCaptureProjectLinkStoring
    private let github: any QuickCaptureGitHub
    private let now: @MainActor () -> Date
    private var running: Task<Void, Never>?
    /// Local checkouts whose `origin` was read this launch.
    private var originsRead: Set<String> = []
    /// Repositories gh could not describe this launch; asked again only by
    /// a forced refresh.
    private var failed: Set<String> = []

    package init(
        store: any QuickCaptureProjectLinkStoring,
        github: any QuickCaptureGitHub,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.store = store
        self.github = github
        self.now = now
    }

    /// Reads the origins not read yet and describes the repositories whose
    /// description is missing or a week old; every one with `force`. A
    /// refresh already running is returned instead of starting another.
    @discardableResult
    package func refresh(force: Bool = false) -> Task<Void, Never> {
        if let running { return running }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.link(force: force)
            self.running = nil
        }
        running = task
        return task
    }

    private func link(force: Bool) async {
        let moment = now()
        let learned = store.snapshot()
        let listed = learned.listedProjects(now: moment)
        var wanted = learned.repositoriesNeedingGitHub(now: moment, force: force)
        for project in listed where project.key.hasPrefix("/") && !originsRead.contains(project.key) {
            originsRead.insert(project.key)
            guard let repository = await github.repository(ofCheckout: project.key) else { continue }
            if repository != project.repository {
                Log.backends.info("Quick capture: a local project's origin is \(repository, privacy: .public)")
                store.recordOriginRepository(repository, projectKey: project.key)
                if !wanted.contains(repository) { wanted.append(repository) }
            }
        }
        if force { failed.removeAll() }
        for repository in wanted where !failed.contains(repository) {
            if let facts = await github.repositoryFacts(repository) {
                store.recordGitHub(facts, repository: repository)
            } else {
                failed.insert(repository)
            }
        }
    }
}
