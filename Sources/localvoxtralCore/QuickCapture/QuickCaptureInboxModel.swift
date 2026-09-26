import Foundation

/// The Inbox page's model (#732): takes a stopped quick capture, routes it,
/// has the project's agent draft it, and files it only when the user
/// presses File. Every change is written to the inbox file at once, so a
/// capture survives a quit at any step.
///
/// Not `@Observable`: Observation does not link on the Linux toolchain the
/// core is tested with. The app's view model observes `onChange` instead.
@MainActor
package final class QuickCaptureInboxModel {
    package private(set) var inbox: QuickCaptureInbox {
        didSet { onChange?() }
    }
    /// Every change to `inbox`.
    package var onChange: (@MainActor () -> Void)?

    private let fileURL: URL?
    private let makeRouter: @MainActor () -> QuickCaptureRouter
    private let projects: @MainActor () -> [QuickCaptureProject]
    private let agents: @MainActor () -> [ProjectTermProposal.Agent]
    private let drafter: @MainActor () -> QuickCaptureDrafter
    private let github: any QuickCaptureGitHub
    private let now: @MainActor () -> Date
    /// One short sentence for the menu bar popover.
    package var onStatus: (@MainActor (String) -> Void)?
    /// Where the capture went, for its History record.
    package var onRouted: (@MainActor (_ historyRecordID: UUID, _ destination: String) -> Void)?

    package init(
        fileURL: URL?,
        makeRouter: @escaping @MainActor () -> QuickCaptureRouter,
        projects: @escaping @MainActor () -> [QuickCaptureProject],
        agents: @escaping @MainActor () -> [ProjectTermProposal.Agent],
        drafter: @escaping @MainActor () -> QuickCaptureDrafter,
        github: any QuickCaptureGitHub,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.makeRouter = makeRouter
        self.projects = projects
        self.agents = agents
        self.drafter = drafter
        self.github = github
        self.now = now
        var loaded = fileURL.map(QuickCaptureInboxFile.load(from:)) ?? QuickCaptureInbox()
        loaded.prune(now: now())
        inbox = loaded
    }

    package var items: [QuickCaptureItem] { inbox.items }
    package var waitingCount: Int { inbox.items.filter { $0.state != .filed }.count }
    package var projectChoices: [QuickCaptureProject] { projects() }

    // MARK: Capture

    /// Adds the capture and starts routing it. Returns the task that routes
    /// and drafts; the app drops it, tests await it.
    @discardableResult
    package func capture(text: String, historyRecordID: UUID?) -> Task<Void, Never> {
        let item = QuickCaptureItem(capturedAt: now(), text: text, historyRecordID: historyRecordID)
        mutate { $0.add(item) }
        Log.backends.info("Quick capture: saved, routing")
        let router = makeRouter()
        let projects = projects()
        return Task { @MainActor [weak self] in
            let route = await router.route(capture: text, projects: projects)
            guard let self else { return }
            self.mutate { $0.applyRoute(route, to: item.id, projects: projects) }
            let name = self.inbox.items.first { $0.id == item.id }?.projectName
            self.onStatus?(name.map { "Sent to \($0) inbox" } ?? "Sent to inbox")
            if let recordID = historyRecordID {
                self.onRouted?(recordID, name ?? "Inbox")
            }
            await self.draft(item.id, text: text, destination: route.destination, projects: projects)
        }
    }

    private func draft(_ id: UUID, text: String, destination: QuickCaptureRoute.Destination, projects: [QuickCaptureProject]) async {
        guard case .project(let key) = destination else { return }
        mutate { inbox in inbox.update(id) { $0.state = .drafting } }
        let repository = key.hasPrefix("/") ? await github.repository(ofCheckout: key) : nil
        let outcome = await drafter().draft(capture: text, route: destination, projects: projects, agents: agents())
        mutate { $0.applyDraft(outcome, repository: repository, to: id) }
    }

    // MARK: Review

    package func setTitle(_ title: String, for id: UUID) {
        mutate { inbox in inbox.update(id) { $0.title = title } }
    }

    package func setBody(_ body: String, for id: UUID) {
        mutate { inbox in inbox.update(id) { $0.body = body } }
    }

    package func setRepository(_ repository: String, for id: UUID) {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate { inbox in inbox.update(id) { $0.repository = trimmed.isEmpty ? nil : trimmed } }
    }

    /// Moves a capture to another project, or to the catch-all with nil. A
    /// capture with no draft yet gets one in its new project.
    @discardableResult
    package func move(_ id: UUID, toProjectKey key: String?) -> Task<Void, Never>? {
        let projects = projects()
        let project = key.flatMap { key in projects.first { $0.key == key } }
        guard let item = inbox.items.first(where: { $0.id == id }), item.state == .ready else { return nil }
        mutate { $0.move(id, to: project, repository: nil) }
        guard let project else { return nil }
        let needsDraft = item.title.isEmpty
        return Task { @MainActor [weak self] in
            guard let self else { return }
            if needsDraft {
                await self.draft(id, text: item.text, destination: .project(project.key), projects: projects)
            } else if project.key.hasPrefix("/") {
                let repository = await self.github.repository(ofCheckout: project.key)
                self.mutate { inbox in inbox.update(id) { if $0.repository == nil { $0.repository = repository } } }
            }
        }
    }

    package func discard(_ id: UUID) {
        mutate { $0.discard(id) }
    }

    /// The only path to `gh issue create`.
    @discardableResult
    package func file(_ id: UUID) -> Task<Void, Never>? {
        guard let item = inbox.items.first(where: { $0.id == id }), item.canFile, let repository = item.repository else {
            return nil
        }
        mutate { inbox in inbox.update(id) { $0.state = .filing } }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = item.bodyToFile
        return Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.github.createIssue(repository: repository, title: title, body: body)
            self.mutate { inbox in
                inbox.update(id) { item in
                    switch result {
                    case .success(let url):
                        item.state = .filed
                        item.filedURL = url
                        item.note = nil
                    case .failure(let failure):
                        item.state = .ready
                        item.note = failure == .ghNotFound
                            ? "GitHub CLI not found."
                            : "Filing failed. Check that gh is logged in."
                    }
                }
            }
            if case .success = result, let recordID = item.historyRecordID {
                self.onRouted?(recordID, "Filed in \(repository)")
            }
        }
    }

    private func mutate(_ change: (inout QuickCaptureInbox) -> Void) {
        change(&inbox)
        guard let fileURL else { return }
        do {
            try QuickCaptureInboxFile.save(inbox, to: fileURL)
        } catch {
            Log.persistence.error("Quick capture inbox: save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
