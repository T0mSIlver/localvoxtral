import Foundation
import Synchronization

/// The Inbox page's model (#732): takes a stopped quick capture, polishes
/// it once (#970), routes it,
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
    /// Nil when polishing is off: the capture routes its raw words at once.
    private let polisher: @MainActor () -> (any QuickCapturePolishing)?
    private let polishVocabulary: @MainActor ([QuickCaptureProject]) -> [String]
    private let now: @MainActor () -> Date
    /// The latest draft run per capture: an older run's answer is dropped.
    private var draftRuns: [UUID: Int] = [:]
    private var draftRunCount = 0
    /// One short sentence for the menu bar popover.
    package var onStatus: (@MainActor (String) -> Void)?
    /// A draft finished: an item went from drafting, or from an issue's
    /// check, to a ready draft (#927, #918).
    /// Called before `onChange`.
    package var onDraftReady: (@MainActor (QuickCaptureItem) -> Void)?
    /// The capture's polished words and how long the polish took, for its
    /// History record (#970).
    package var onPolished: (@MainActor (_ historyRecordID: UUID, _ polishedText: String, _ seconds: Double) -> Void)?
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
        polisher: @escaping @MainActor () -> (any QuickCapturePolishing)? = { nil },
        polishVocabulary: @escaping @MainActor ([QuickCaptureProject]) -> [String] = { _ in [] },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.makeRouter = makeRouter
        self.projects = projects
        self.agents = agents
        self.drafter = drafter
        self.github = github
        self.polisher = polisher
        self.polishVocabulary = polishVocabulary
        self.now = now
        var loaded = fileURL.map(QuickCaptureInboxFile.load(from:)) ?? QuickCaptureInbox()
        loaded.prune(now: now())
        inbox = loaded
    }

    package var items: [QuickCaptureItem] { inbox.items }
    package var waitingCount: Int { inbox.items.filter { $0.state != .filed }.count }
    package var projectChoices: [QuickCaptureProject] { projects() }

    // MARK: Capture

    /// Adds the capture, polishes it, and starts routing it. Returns the task
    /// that polishes, routes and drafts; the app drops it, tests await it. A
    /// voice memo passes the id its audio is kept under, and when it was
    /// recorded.
    ///
    /// The file holds the raw words before the polish starts. The polish
    /// (#970) runs once, with every project's names and confirmed terms; its
    /// words replace the raw ones in the Inbox, and the router and drafter
    /// read them. A failed polish, or no polishing configuration, routes the
    /// raw words.
    ///
    /// A follow-up (#965) joins an open capture instead: one that begins
    /// "also" or "for that idea" joins the latest, and the router may match
    /// any of them on the same call that picks a project.
    @discardableResult
    package func capture(
        text: String, historyRecordID: UUID?, id: UUID = UUID(), capturedAt: Date? = nil
    ) -> Task<Void, Never> {
        let item = QuickCaptureItem(
            id: id, capturedAt: capturedAt ?? now(), text: text, historyRecordID: historyRecordID)
        mutate { $0.add(item) }
        guard let polisher = polisher() else { return place(item, rawText: text) }
        let vocabulary = polishVocabulary(projects())
        Log.backends.notice("Quick capture: saved, polishing with \(vocabulary.count, privacy: .public) terms")
        return Task { @MainActor [weak self] in
            let polished = await polisher.polish(text, vocabulary: vocabulary)
            guard let self else { return }
            guard var current = self.inbox.items.first(where: { $0.id == item.id }), current.state == .routing else {
                Log.backends.notice("Quick capture: discarded while it was polished")
                return
            }
            let words = polished?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let polished, !words.isEmpty {
                self.mutate { inbox in inbox.update(item.id) { $0.text = words } }
                current.text = words
                Log.backends.notice(
                    "Quick capture: polished in \(String(format: "%.2f", polished.durationSeconds), privacy: .public) s"
                )
                if let recordID = historyRecordID {
                    self.onPolished?(recordID, words, polished.durationSeconds)
                }
            } else {
                Log.backends.notice("Quick capture: not polished, routing the raw words")
            }
            await self.place(current, rawText: text).value
        }
    }

    /// Joins the capture to the open capture it follows up, else routes it.
    /// Either the polished or the raw words beginning "also" make a
    /// follow-up, so a polish that rewords the start cannot undo one.
    private func place(_ item: QuickCaptureItem, rawText: String) -> Task<Void, Never> {
        let open = inbox.items
            .filter { $0.id != item.id && $0.acceptsFollowUp(at: item.capturedAt) }
            .sorted { $0.lastCapturedAt > $1.lastCapturedAt }
        if QuickCaptureInbox.saysFollowUp(item.text) || QuickCaptureInbox.saysFollowUp(rawText),
           let latest = open.first
        {
            Log.backends.notice("Quick capture: saved, a follow-up by its first words")
            let task = join(item.id, into: latest.id)
            return Task { await task?.value }
        }
        Log.backends.notice("Quick capture: saved, routing")
        let openCaptures = open.prefix(QuickCaptureRouting.maxOpenCaptures).map {
            QuickCaptureOpenCapture(id: $0.id, projectKey: $0.projectKey, summary: $0.summary)
        }
        return route(item, openCaptures: Array(openCaptures))
    }

    /// Routes `item` and drafts it where it lands, or joins it to the open
    /// capture the router matched.
    private func route(_ item: QuickCaptureItem, openCaptures: [QuickCaptureOpenCapture]) -> Task<Void, Never> {
        let router = makeRouter()
        let projects = projects()
        let text = item.text
        let historyRecordID = item.historyRecordID
        return Task { @MainActor [weak self] in
            let answer = await router.answer(capture: text, projects: projects, openCaptures: openCaptures)
            guard let self else { return }
            let route: QuickCaptureRoute
            switch answer {
            case .route(let answered):
                route = answered
            case .join(let target, let classifier, let probability):
                if let task = self.join(item.id, into: target) {
                    await task.value
                    return
                }
                // The capture it continues was filed or discarded meanwhile.
                route = QuickCaptureRoute(
                    destination: .catchAll, classifier: classifier, reason: .lowConfidence, topProbability: probability,
                    suggestion: openCaptures.first { $0.id == target }?.projectKey
                )
            }
            self.mutate { $0.applyRoute(route, to: item.id, projects: projects) }
            let name = self.inbox.items.first { $0.id == item.id }?.projectName
            self.onStatus?(name.map { "Sent to \($0) inbox" } ?? "Sent to inbox")
            if let recordID = historyRecordID {
                self.onRouted?(recordID, name ?? "Inbox")
            }
            await self.draft(item.id, text: text, destination: route.destination, projects: projects)
        }
    }

    // MARK: Follow-ups (#965)

    /// Joins capture `id` to `target` as its follow-up, and redrafts the
    /// target in its project: from the draft it has, which may hold the
    /// user's edits, else from all its words. Nil, with nothing changed, only
    /// when the target was filed or discarded meanwhile.
    private func join(_ id: UUID, into target: UUID) -> Task<Void, Never>? {
        guard let before = inbox.items.first(where: { $0.id == target }),
              before.state == .ready || before.state == .drafting,
              let capture = inbox.items.first(where: { $0.id == id })
        else { return nil }
        mutate { $0.join(id, into: target) }
        Log.backends.notice("Quick capture: joined an open capture as its follow-up")
        onStatus?(QuickCaptureFollowUpStatus.joined)
        if let recordID = capture.historyRecordID {
            onRouted?(recordID, "Added to \(before.projectName.map { "a \($0) capture" } ?? "an Inbox capture")")
        }
        // A capture with no project keeps the words and drafts nothing.
        guard let key = before.projectKey else { return Task {} }
        let projects = projects()
        let input: String
        if let draft = before.draftSnapshot {
            input = QuickCaptureSpokenReview.redraftCapture(
                original: before.words, title: draft.title, body: draft.body,
                changes: (before.changes ?? []) + ["Add what the user said next: \(capture.text)"]
            )
        } else {
            input = before.words + "\n\n" + capture.text
        }
        return Task { @MainActor [weak self] in
            await self?.draft(target, text: input, destination: .project(key), projects: projects)
        }
    }

    /// Split (#965): the follow-up becomes its own capture again, routed to
    /// a project (never joined back), and the item gets back the draft it had
    /// before that follow-up, else is redrafted from its remaining words.
    @discardableResult
    package func split(_ followUpID: UUID, from id: UUID) -> Task<Void, Never>? {
        guard let item = inbox.items.first(where: { $0.id == id }), item.state == .ready || item.state == .drafting
        else { return nil }
        var result: (capture: QuickCaptureItem, restored: Bool)?
        mutate { result = $0.split(followUpID, from: id) }
        guard let result else { return nil }
        // A draft running now holds the split words.
        draftRuns[id] = nil
        Log.backends.notice("Quick capture: split a follow-up, \(result.restored ? "earlier draft restored" : "redrafting", privacy: .public)")
        let routing = route(result.capture, openCaptures: [])
        guard !result.restored, let key = item.projectKey,
              let after = inbox.items.first(where: { $0.id == id })
        else {
            if !result.restored, item.state == .drafting {
                mutate { inbox in inbox.update(id) { $0.state = .ready } }
            }
            return routing
        }
        let projects = projects()
        return Task { @MainActor [weak self] in
            await self?.draft(id, text: after.words, destination: .project(key), projects: projects)
            await routing.value
        }
    }

    private func draft(_ id: UUID, text: String, destination: QuickCaptureRoute.Destination, projects: [QuickCaptureProject]) async {
        guard case .project(let key) = destination else { return }
        // A later run for this capture (a follow-up joined, #965) makes this
        // one's answers moot.
        draftRunCount += 1
        let run = draftRunCount
        draftRuns[id] = run
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
                guard let self, self.draftRuns[id] == run, let item = self.inbox.items.first(where: { $0.id == id }),
                      item.state == .drafting, item.projectKey == key
                else { return false }
                self.mutate { $0.applyFirstDraft(outcome, repository: repository, checking: !agents.isEmpty, to: id) }
                guard let now = self.inbox.items.first(where: { $0.id == id }) else { return false }
                if case .draft = outcome { shown.withLock { $0 = (now.title, now.body) } }
                return now.state == .drafting || now.codeCheck?.state == .checking
            }
        )
        guard let final else { return }
        guard draftRuns[id] == run else {
            Log.backends.notice("Quick capture draft: superseded by a later draft of the same capture, dropped")
            return
        }
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
            await self?.draft(id, text: item.words, destination: .project(key), projects: projects)
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
                await self.draft(id, text: item.words, destination: .project(project.key), projects: projects)
            } else if project.issueRepository == nil, project.key.hasPrefix("/") {
                let repository = await self.github.repository(ofCheckout: project.key)
                self.mutate { inbox in inbox.update(id) { if $0.repository == nil { $0.repository = repository } } }
            }
        }
    }

    /// One click on the router's guess (#938): the capture moves there and
    /// drafts, as after a move. A project gone from the list since routing
    /// leaves the capture where it is, and says so.
    @discardableResult
    package func acceptSuggestion(_ id: UUID) -> Task<Void, Never>? {
        guard let suggestion = inbox.items.first(where: { $0.id == id })?.suggestion else { return nil }
        guard projects().contains(where: { $0.key == suggestion.projectKey }) else {
            mutate { inbox in
                inbox.update(id) {
                    $0.suggestion = nil
                    $0.note = "\(suggestion.projectName) is no longer a project. Move it to one."
                }
            }
            return nil
        }
        return move(id, toProjectKey: suggestion.projectKey)
    }

    package func discard(_ id: UUID) {
        let followUps = inbox.items.first { $0.id == id }?.followUps ?? []
        mutate { $0.discard(id) }
        draftRuns[id] = nil
        onDone?(id)
        for followUp in followUps { onDone?(followUp.id) }
    }

    /// The History records of a capture and its follow-ups.
    private func historyRecordIDs(_ item: QuickCaptureItem) -> [UUID] {
        ([item.historyRecordID] + (item.followUps ?? []).map(\.historyRecordID)).compactMap { $0 }
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
            for followUp in item.followUps ?? [] { self.onDone?(followUp.id) }
            for recordID in self.historyRecordIDs(item) {
                self.onRouted?(recordID, "Filed in \(repository)")
            }
        }
    }

    /// Comment on #N (#965): the one path to `gh issue comment`, for a draft
    /// that extends an open issue. Like File, only on the user's click.
    @discardableResult
    package func comment(_ id: UUID) -> Task<Void, Never>? {
        guard let item = inbox.items.first(where: { $0.id == id }), item.canComment,
              let repository = item.repository, let issue = item.relatedIssue
        else { return nil }
        mutate { inbox in inbox.update(id) { $0.state = .filing } }
        let body = item.commentBody
        return Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.github.commentOnIssue(repository: repository, issue: issue, body: body)
            self.mutate { inbox in
                inbox.update(id) { item in
                    switch result {
                    case .success(let url):
                        item.state = .filed
                        item.filedURL = url
                        item.filedAt = self.now()
                        item.commentedOn = issue
                        item.note = nil
                    case .failure(let failure):
                        item.state = .ready
                        item.note = failure == .ghNotFound
                            ? "GitHub CLI not found."
                            : "The comment failed. Check that gh is logged in."
                    }
                }
            }
            guard case .success = result else { return }
            self.onDone?(id)
            for followUp in item.followUps ?? [] { self.onDone?(followUp.id) }
            for recordID in self.historyRecordIDs(item) {
                self.onRouted?(recordID, "Commented on \(repository)#\(issue)")
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
            original: item.words, title: item.title, body: item.body, changes: changes
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

/// The popover's sentence for a follow-up that joined a capture (#965).
package enum QuickCaptureFollowUpStatus {
    package static let joined = "Added to an earlier capture"
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
