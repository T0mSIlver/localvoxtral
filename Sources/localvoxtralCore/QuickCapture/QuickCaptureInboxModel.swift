import Foundation
import Synchronization

/// The Inbox page's model (#732): takes a stopped quick capture, routes it,
/// drafts it in two stages (#918: the polishing model's first draft, then
/// the agent's check against the code for an issue), and files it only when
/// the user presses File. Every change is written to the inbox file at once, so a
/// capture survives a quit at any step.
///
/// Not `@Observable`: Observation does not link on the Linux toolchain the
/// core is tested with. The app's view model observes `onChange` instead.
@MainActor
package final class QuickCaptureInboxModel {
    package private(set) var inbox: QuickCaptureInbox {
        didSet {
            noteDraftsThatFinished(from: oldValue)
            onChange?()
        }
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
    /// A draft finished: an item went from drafting, or from an issue's
    /// check, to a ready draft (#927, #918).
    /// Called before `onChange`.
    package var onDraftReady: (@MainActor (QuickCaptureItem) -> Void)?
    /// Where the capture went, for its History record.
    package var onRouted: (@MainActor (_ historyRecordID: UUID, _ destination: String) -> Void)?
    /// A capture was filed or discarded, so audio kept for it can go.
    package var onDone: (@MainActor (_ id: UUID) -> Void)?
    /// The user typed `owner/name` for a project that has no repository
    /// (#926): kept on the project, so the Inbox asks once.
    package var onRepositoryAnswered: (@MainActor (_ projectKey: String, _ repository: String) -> Void)?

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
    /// and drafts; the app drops it, tests await it. A voice memo passes the
    /// id its audio is kept under, and when it was recorded.
    @discardableResult
    package func capture(
        text: String, historyRecordID: UUID?, id: UUID = UUID(), capturedAt: Date? = nil
    ) -> Task<Void, Never> {
        let item = QuickCaptureItem(
            id: id, capturedAt: capturedAt ?? now(), text: text, historyRecordID: historyRecordID)
        mutate { $0.add(item) }
        Log.backends.notice("Quick capture: saved, routing")
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
        mutate { inbox in
            inbox.update(id) {
                $0.state = .drafting
                $0.note = nil
                $0.codeCheck = nil
                // A remote project's host drafts on its next session hook.
                if !key.hasPrefix("/") { $0.note = QuickCaptureInbox.waitingForHostNote }
            }
        }
        let repository = await repository(of: projects.first { $0.key == key })
        let drafter = drafter()
        let agents = agents()
        Log.backends.notice(
            "Quick capture draft: started, \(drafter.writesFirstDrafts ? "first draft then check" : "agent only", privacy: .public), \(key.hasPrefix("/") ? "local" : "remote", privacy: .public) project"
        )
        // What the first draft said, to tell whether the user edited it
        // before the check came back.
        let shown = Mutex<(title: String, body: String)?>(nil)
        let final = await drafter.draft(
            capture: text, route: destination, projects: projects, agents: agents,
            onFirstDraft: { @MainActor [weak self] outcome in
                guard let self, let item = self.inbox.items.first(where: { $0.id == id }),
                      item.state == .drafting, item.projectKey == key
                else { return false }
                self.mutate { $0.applyFirstDraft(outcome, repository: repository, checking: !agents.isEmpty, to: id) }
                guard let now = self.inbox.items.first(where: { $0.id == id }) else { return false }
                if case .draft = outcome { shown.withLock { $0 = (now.title, now.body) } }
                return now.state == .drafting || now.codeCheck?.state == .checking
            }
        )
        guard let final else { return }
        guard let item = inbox.items.first(where: { $0.id == id }), item.projectKey == key else {
            Log.backends.notice("Quick capture draft: the capture was moved or discarded, draft dropped")
            return
        }
        if item.state == .filing || item.state == .filed {
            Log.backends.notice("Quick capture draft: filed before the check finished, check dropped")
            // Mid-filing, the filing may still fail: the check then reads as
            // failed, so Draft Again can bring it back.
            mutate { inbox in
                inbox.update(id) {
                    if $0.state == .filed { $0.codeCheck = nil } else { $0.codeCheck?.state = .failed }
                }
            }
            return
        }
        mutate { $0.applyDraft(final, repository: repository, firstDraft: shown.withLock { $0 }, to: id) }
        if let after = inbox.items.first(where: { $0.id == id }), after.codeCheck?.keptEdits == true {
            Log.backends.notice("Quick capture draft: checked, the user's edits kept")
        }
    }

    /// Drafts a capture again in its project, both stages, after its draft
    /// or its check failed.
    @discardableResult
    package func draftAgain(_ id: UUID) -> Task<Void, Never>? {
        guard let item = inbox.items.first(where: { $0.id == id }), item.canDraftAgain, let key = item.projectKey else {
            return nil
        }
        let projects = projects()
        guard projects.contains(where: { $0.key == key }) else { return nil }
        Log.backends.notice("Quick capture draft: drafting again")
        return Task { @MainActor [weak self] in
            await self?.draft(id, text: item.text, destination: .project(key), projects: projects)
        }
    }

    /// The project's filing repository, else a local checkout's `origin`
    /// read now, before the project list has it.
    private func repository(of project: QuickCaptureProject?) async -> String? {
        guard let project else { return nil }
        if let repository = project.issueRepository { return repository }
        return project.key.hasPrefix("/") ? await github.repository(ofCheckout: project.key) : nil
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
        guard QuickCaptureInbox.isRepository(trimmed),
              let key = inbox.items.first(where: { $0.id == id })?.projectKey,
              let project = projects().first(where: { $0.key == key }), project.repository == nil
        else { return }
        onRepositoryAnswered?(key, trimmed)
    }

    /// Moves a capture to another project, or to the catch-all with nil. A
    /// capture with no draft yet gets one in its new project.
    @discardableResult
    package func move(_ id: UUID, toProjectKey key: String?) -> Task<Void, Never>? {
        let projects = projects()
        let project = key.flatMap { key in projects.first { $0.key == key } }
        guard let item = inbox.items.first(where: { $0.id == id }), item.state == .ready else { return nil }
        mutate { $0.move(id, to: project, repository: project?.issueRepository) }
        guard let project else { return nil }
        let needsDraft = item.title.isEmpty
        return Task { @MainActor [weak self] in
            guard let self else { return }
            if needsDraft {
                await self.draft(id, text: item.text, destination: .project(project.key), projects: projects)
            } else if project.issueRepository == nil, project.key.hasPrefix("/") {
                let repository = await self.github.repository(ofCheckout: project.key)
                self.mutate { inbox in inbox.update(id) { if $0.repository == nil { $0.repository = repository } } }
            }
        }
    }

    package func discard(_ id: UUID) {
        mutate { $0.discard(id) }
        onDone?(id)
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
                        item.filedAt = self.now()
                        item.note = nil
                    case .failure(let failure):
                        item.state = .ready
                        item.note = failure == .ghNotFound
                            ? "GitHub CLI not found."
                            : "Filing failed. Check that gh is logged in."
                    }
                }
            }
            guard case .success = result else { return }
            self.onDone?(id)
            if let recordID = item.historyRecordID {
                self.onRouted?(recordID, "Filed in \(repository)")
            }
        }
    }

    // MARK: Spoken review (#927)

    /// The draft as the overlay shows it, nil unless `id` is a ready draft.
    package func reviewSnapshot(_ id: UUID) -> QuickCaptureDraftSnapshot? {
        guard let item = inbox.items.first(where: { $0.id == id }), item.isReadyDraft, let projectName = item.projectName
        else { return nil }
        return QuickCaptureDraftSnapshot(id: id, projectName: projectName, title: item.title, body: item.body)
    }

    /// What the review's words did, as the popover's sentence. "file it"
    /// files only the draft the overlay showed, unchanged since; the returned
    /// task is the filing or the redraft, for tests to await.
    package func applySpokenReview(
        _ review: QuickCaptureSpokenReview, to shown: QuickCaptureDraftSnapshot
    ) -> (status: String, task: Task<Void, Never>?) {
        guard let item = inbox.items.first(where: { $0.id == shown.id }), item.isReadyDraft else {
            Log.backends.notice("Quick capture review: the draft left the Inbox; nothing done")
            return (QuickCaptureReviewStatus.gone, nil)
        }
        switch review {
        case .nothing:
            return (QuickCaptureReviewStatus.kept, nil)
        case .drop:
            discard(shown.id)
            Log.backends.notice("Quick capture review: dropped")
            return (QuickCaptureReviewStatus.dropped, nil)
        case .file:
            guard item.title == shown.title, item.body == shown.body else {
                Log.backends.notice("Quick capture review: the draft changed since it was shown; not filed")
                return (QuickCaptureReviewStatus.changedSinceShown, nil)
            }
            guard item.canFile, let task = file(shown.id) else {
                Log.backends.notice("Quick capture review: the draft cannot be filed")
                return (QuickCaptureReviewStatus.cannotFile, nil)
            }
            Log.backends.notice("Quick capture review: filing")
            let reported = Task { @MainActor [weak self] in
                await task.value
                guard let self else { return }
                let filed = self.inbox.items.first { $0.id == shown.id }?.state == .filed
                self.onStatus?(filed ? QuickCaptureReviewStatus.filed : QuickCaptureReviewStatus.filingFailed)
            }
            return (QuickCaptureReviewStatus.filing, reported)
        case .change(let change):
            guard let task = redraft(shown.id, change: change) else {
                return (QuickCaptureReviewStatus.gone, nil)
            }
            Log.backends.notice("Quick capture review: redrafting with a change")
            return (QuickCaptureReviewStatus.redrafting, task)
        }
    }

    /// Reruns the drafter with the dictated words, the current draft and
    /// every change asked for so far.
    @discardableResult
    package func redraft(_ id: UUID, change: String) -> Task<Void, Never>? {
        guard let item = inbox.items.first(where: { $0.id == id }), item.isReadyDraft, let key = item.projectKey else {
            return nil
        }
        let changes = (item.changes ?? []) + [change]
        // Drafting at once: the cue drops it, and a second review finds no
        // ready draft until the redraft lands.
        mutate { inbox in
            inbox.update(id) {
                $0.changes = changes
                $0.state = .drafting
            }
        }
        let text = QuickCaptureSpokenReview.redraftCapture(
            original: item.text, title: item.title, body: item.body, changes: changes
        )
        let projects = projects()
        return Task { @MainActor [weak self] in
            await self?.draft(id, text: text, destination: .project(key), projects: projects)
        }
    }

    private func noteDraftsThatFinished(from old: QuickCaptureInbox) {
        guard let onDraftReady else { return }
        // Drafting, or an issue's check still running (#918): the cue waits
        // for the checked draft, and fires at once for other kinds.
        let drafting = Set(old.items.filter { $0.state == .drafting || $0.codeCheck?.state == .checking }.map(\.id))
        guard !drafting.isEmpty else { return }
        for item in inbox.items where drafting.contains(item.id) && item.isReadyDraft {
            onDraftReady(item)
        }
    }

    /// A coding agent filed the capture itself (#923). Its History record
    /// says so, as after File.
    package func markFiled(_ id: UUID, url: String) -> Result<QuickCaptureItem, QuickCaptureInbox.MarkFiledRefusal> {
        var changed = inbox
        let result = changed.markFiled(id, url: url, now: now())
        if case .success(let item) = result {
            mutate { $0 = changed }
            Log.backends.info("Quick capture: a coding agent filed \(url, privacy: .public)")
            if let recordID = item.historyRecordID, let repository = item.repository {
                onRouted?(recordID, "Filed in \(repository)")
            }
        }
        return result
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

/// The popover's sentences for what a spoken review did (#927), within its
/// 44 characters.
package enum QuickCaptureReviewStatus {
    package static let filing = "Filing the draft"
    package static let filed = "Draft filed"
    package static let filingFailed = "Filing failed; see the Inbox"
    package static let dropped = "Draft dropped"
    package static let redrafting = "Redrafting with your change"
    package static let kept = "Draft kept in the Inbox"
    package static let gone = "That draft left the Inbox"
    package static let changedSinceShown = "The draft changed; nothing filed"
    package static let cannotFile = "Can't file it; open the Inbox"
}
