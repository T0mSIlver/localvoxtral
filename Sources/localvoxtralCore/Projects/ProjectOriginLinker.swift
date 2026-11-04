import Foundation

/// Where a checkout's repository is kept (`LearnedTermStore`).
package protocol ProjectOriginStoring: Sendable {
    func snapshot() -> LearnedTerms
    /// A checkout's `origin` names `remote` (#971).
    func recordOrigin(_ remote: ProjectRemote, projectKey: String)
}

/// Reads the repository a checkout's `origin` names.
package protocol CheckoutOriginReading: Sendable {
    /// The repository the checkout's `origin` names, on any host (#971).
    func remote(ofCheckout path: String) async -> ProjectRemote?
}

package struct GitCheckoutOriginReader: CheckoutOriginReading {
    package init() {}

    /// `git remote get-url origin`; nil when the checkout has no `origin` or
    /// its URL names no repository.
    package func remote(ofCheckout path: String) async -> ProjectRemote? {
        guard let origin = await RepoGitRunner.run(
            arguments: ["remote", "get-url", "origin"], root: path, timeoutSeconds: 20, maxBytes: 4096
        ) else { return nil }
        guard !origin.timedOut, origin.exitCode == 0 || origin.exitCode == 2 else {
            Log.backends.error("Projects: git remote get-url origin exited \(origin.exitCode, privacy: .public)")
            return nil
        }
        guard origin.exitCode == 0 else { return nil }
        return ProjectRemote(remoteURL: String(decoding: origin.data, as: UTF8.self))
    }
}

/// Links the listed projects to their repositories (#926, #971). A local
/// checkout's repository is its `origin`, read once a launch; a remote one's
/// comes from its host's hook (`RemoteProjectReports.noteReport`). A
/// checkout linked joins its repository's project, so the terms of one
/// repository are shared across its checkouts.
@MainActor
package final class ProjectOriginLinker {
    private let store: any ProjectOriginStoring
    private let origins: any CheckoutOriginReading
    private let now: @MainActor () -> Date
    private var running: Task<Void, Never>?
    /// Local checkouts whose `origin` was read this launch.
    private var originsRead: Set<String> = []

    package init(
        store: any ProjectOriginStoring,
        origins: any CheckoutOriginReading = GitCheckoutOriginReader(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.store = store
        self.origins = origins
        self.now = now
    }

    /// Reads the origins not read yet. A refresh already running is
    /// returned instead of starting another.
    @discardableResult
    package func refresh() -> Task<Void, Never> {
        if let running { return running }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.link()
            self.running = nil
        }
        running = task
        return task
    }

    private func link() async {
        let listed = store.snapshot().listedCheckouts(now: now())
        for project in listed where project.key.hasPrefix("/") && !originsRead.contains(project.key) {
            originsRead.insert(project.key)
            guard let remote = await origins.remote(ofCheckout: project.key) else { continue }
            if remote.value != project.remote {
                Log.backends.info("Projects: a local project's origin is \(remote.value, privacy: .public)")
                store.recordOrigin(remote, projectKey: project.key)
            }
        }
    }
}
