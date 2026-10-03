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
    /// Set, the inbox file could not be loaded: it is left as it is, the
    /// Inbox is empty and refuses every change (#989).
    package private(set) var storeProblem: StoredFileProblem?
    /// The file as this copy last read or wrote it: another running copy of
    /// the app may write it too (#990).
    private var seen = StoredFileSeen()
    private let makeRouter: @MainActor () -> QuickCaptureRouter
    private let projects: @MainActor () -> [QuickCaptureProject]
    private let agents: @MainActor () -> [ProjectTermProposal.Agent]
    private let drafter: @MainActor () -> QuickCaptureDrafter
    private let github: any QuickCaptureGitHub
    /// Nil when polishing is off: the capture routes its raw words at once.
    private let polisher: @MainActor () -> (any QuickCapturePolishing)?
    private let polishVocabulary: @MainActor ([QuickCaptureProject]) -> [String]
    /// The user's recent GitHub repositories (#930), for a capture left
    /// unplaced; never the router's options.
    private let recentRepositories: @MainActor () async -> [GitHubListedRepository]
    private let now: @MainActor () -> Date
    /// This running copy, as a filing claim or a run owner names it.
    private let processID: Int32
    /// This launch, against a later copy given the same process ID (#1507).
    private let launch = UUID()
    private let isProcessRunning: (Int32) -> Bool
    private let write: (Data, URL) throws -> Void
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
    /// The user accepted "Add <name>?" (#930): the repository becomes a
    /// project, listed once this returns.
    package var onRepositoryAdded: (@MainActor (_ repository: String) async -> Void)?

    package init(
        fileURL: URL?,
        makeRouter: @escaping @MainActor () -> QuickCaptureRouter,
        projects: @escaping @MainActor () -> [QuickCaptureProject],
        agents: @escaping @MainActor () -> [ProjectTermProposal.Agent],
        drafter: @escaping @MainActor () -> QuickCaptureDrafter,
        github: any QuickCaptureGitHub,
        polisher: @escaping @MainActor () -> (any QuickCapturePolishing)? = { nil },
        polishVocabulary: @escaping @MainActor ([QuickCaptureProject]) -> [String] = { _ in [] },
        recentRepositories: @escaping @MainActor () async -> [GitHubListedRepository] = { [] },
        now: @escaping @MainActor () -> Date = { Date() },
        processID: Int32 = getpid(),
        isProcessRunning: @escaping (Int32) -> Bool = QuickCaptureInboxModel.isRunning,
        write: @escaping (Data, URL) throws -> Void = PrivateFile.write
    ) {
        self.processID = processID
        self.isProcessRunning = isProcessRunning
        self.write = write
        self.fileURL = fileURL
        self.makeRouter = makeRouter
        self.projects = projects
        self.agents = agents
        self.drafter = drafter
        self.github = github
        self.polisher = polisher
        self.polishVocabulary = polishVocabulary
        self.recentRepositories = recentRepositories
        self.now = now
        var load = StoredFileLoad<QuickCaptureInbox>.absent
        if let fileURL {
            (load, seen) = StoredFile.loadShared(fileURL, decode: QuickCaptureInboxFile.decode)
        }
        storeProblem = load.problem
        var loaded = load.value ?? QuickCaptureInbox()
        loaded.prune(now: now())
        inbox = loaded
        recoverAbandonedRuns()
        adoptProjects()
    }

    /// This copy, as the runs it starts name it.
    private var owner: QuickCaptureRunningCopy {
        QuickCaptureRunningCopy(processID: processID, launch: launch)
    }

    /// Whether `copy` still runs: this launch, or another process alive.
    /// Asked again whenever a change replays, so a recovery replayed after
    /// a failed save never ends a run this launch started since.
    private var isLive: (QuickCaptureRunningCopy) -> Bool {
        let processID = processID
        let launch = launch
        let isProcessRunning = isProcessRunning
        return { copy in
            copy.processID == processID ? copy.launch == launch : isProcessRunning(copy.processID)
        }
    }

    /// Ends the runs and filings a quit left (#1507), as one transaction
    /// with every other running copy: a copy that still holds one of those
    /// runs in memory then writes on top of the recovery, not over it.
    private func recoverAbandonedRuns() {
        let isLive = self.isLive
        guard QuickCaptureInboxFile.resumingInterrupted(inbox, isLive: isLive) != inbox else { return }
        Log.persistence.notice("Quick capture inbox: ending runs a quit left")
        mutate { $0 = QuickCaptureInboxFile.resumingInterrupted($0, isLive: isLive) }
    }

    package var items: [QuickCaptureItem] { inbox.items }

    /// Whether capture `id` is in the Inbox, on its own or as a follow-up.
    package func holds(_ id: UUID) -> Bool { inbox.holds(id) }

    /// The last write of the inbox file failed, so memory holds changes the
    /// file does not (#988).
    package var hasUnsavedChanges: Bool { !unsaved.isEmpty }
    /// Those changes, in order, for `StoredFile.update` to apply again on
    /// top of another running copy's write (#1260).
    private var unsaved: [(inout QuickCaptureInbox) -> Void] = []

    /// The voice memo recordings a sweep keeps (#988).
    package var recordingIDsToKeep: Set<UUID> { inbox.recordingIDsToKeep }

    /// Points each capture at its project as the list has it now: a checkout
    /// merged into its repository (#971) moves to the key and name the
    /// project leads with. Called at load and whenever the projects change.
    package func adoptProjects() {
        let projects = projects()
        guard inbox.adopting(projects) != inbox else { return }
        mutate { $0 = $0.adopting(projects) }
    }
    package var waitingCount: Int { inbox.items.filter { $0.state != .filed }.count }
    package var projectChoices: [QuickCaptureProject] { projects() }

    /// The projects a capture said in `group` may be polished with and
    /// routed to (#1005); every project for nil. The user can still move a
    /// capture to any project.
    private func projects(in group: ProjectGroup?) -> [QuickCaptureProject] {
        let all = projects()
        guard let group else { return all }
        return all.filter { $0.group == group }
    }

    // MARK: Capture

    /// Adds the capture, polishes it, and starts routing it. Returns the task
    /// that polishes, routes and drafts; the app drops it, tests await it. A
    /// voice memo passes the id its audio is kept under, and when it was
    /// recorded.
    ///
    /// The file holds the raw words before the polish starts. The polish
    /// (#970) runs once, with the names and confirmed terms of every project
    /// in `group` (#1005), or of every project with no group; its
    /// words replace the raw ones in the Inbox, and the router and drafter
    /// read them. A failed polish, or no polishing configuration, routes the
    /// raw words.
    ///
    /// A follow-up (#965) joins an open capture instead: one that begins
    /// "also" or "for that idea" joins the latest, and the router may match
    /// any of them on the same call that picks a project.
    @discardableResult
    package func capture(
        text: String, historyRecordID: UUID?, id: UUID = UUID(), capturedAt: Date? = nil, group: ProjectGroup? = nil
    ) -> Task<Void, Never> {
        guard storeProblem == nil else {
            // The words are in History; the Inbox file is not replaced.
            Log.persistence.error("Quick capture: not saved, the inbox file could not be loaded")
            onStatus?(Self.refusedStatus)
            return Task {}
        }
        var item = QuickCaptureItem(
            id: id, capturedAt: capturedAt ?? now(), text: text, historyRecordID: historyRecordID, group: group)
        item.runOwner = owner
        mutate { $0.add(item) }
        guard storeProblem == nil else {
            // Another running copy left a file this build cannot read.
            onStatus?(Self.refusedStatus)
            return Task {}
        }
        return polishAndPlace(item)
    }

    /// A voice memo's capture (#988), as `capture`, but throws when the
    /// Inbox refuses it or its file could not be written, so the memo's
    /// original stays. After a failed write the words still wait in the
    /// Inbox, and the next save that succeeds keeps them.
    package func captureVoiceMemo(text: String, historyRecordID: UUID?, id: UUID, capturedAt: Date) throws {
        guard storeProblem == nil else { throw StoreRefused() }
        var item = QuickCaptureItem(id: id, capturedAt: capturedAt, text: text, historyRecordID: historyRecordID)
        item.runOwner = owner
        let failure = mutate { $0.add(item) }
        // Refused by the write (another running copy's file): nothing to place.
        if failure is StoreRefused { throw StoreRefused() }
        _ = polishAndPlace(item)
        if let failure { throw failure }
    }

    /// Polishes a new capture, then joins or routes it.
    private func polishAndPlace(_ item: QuickCaptureItem) -> Task<Void, Never> {
        let polisher = polisher()
        guard polisher != nil || pendingPlacements > 0 else {
            return track(place(item, rawText: item.text))
        }
        // Captures are placed in the order they were made (#970 review):
        // polishes run side by side, but a capture joins or routes only once
        // the one before it has, so an "also" whose polish ends first still
        // finds the capture it follows.
        let previous = lastPlaced
        let vocabulary = polisher == nil ? [] : polishVocabulary(projects(in: item.group))
        if polisher != nil {
            Log.backends.notice("Quick capture: saved, polishing with \(vocabulary.count, privacy: .public) terms")
        }
        let placement = Task { @MainActor [weak self] () -> Placement? in
            let polished = await polisher?.polish(item.text, vocabulary: vocabulary)
            let words = polished?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let polished, !words.isEmpty, let self,
               self.inbox.items.contains(where: { $0.id == item.id && $0.state == .routing })
            {
                self.mutate { inbox in inbox.update(item.id) { $0.text = words } }
                Log.backends.notice(
                    "Quick capture: polished in \(String(format: "%.2f", polished.durationSeconds), privacy: .public) s"
                )
                if let recordID = item.historyRecordID {
                    self.onPolished?(recordID, words, polished.durationSeconds)
                }
            } else if polisher != nil {
                Log.backends.notice("Quick capture: not polished, routing the raw words")
            }
            await previous?.value
            guard let self else { return nil }
            guard let current = self.inbox.items.first(where: { $0.id == item.id }), current.state == .routing else {
                Log.backends.notice("Quick capture: discarded before it was placed")
                return nil
            }
            return self.place(current, rawText: item.text)
        }
        return track(Placement(
            placed: Task { await placement.value?.placed.value },
            done: Task { await placement.value?.done.value }
        ))
    }

    /// A capture's way into the Inbox: `placed` ends once it has joined an
    /// open capture or has its route, `done` once its draft is written too.
    private struct Placement {
        let placed: Task<Void, Never>
        let done: Task<Void, Never>
    }

    /// Captures not placed yet, and the latest one's `placed`: the next
    /// capture waits on it.
    private var pendingPlacements = 0
    private var lastPlaced: Task<Void, Never>?

    private func track(_ placement: Placement) -> Task<Void, Never> {
        pendingPlacements += 1
        lastPlaced = placement.placed
        Task { @MainActor [weak self] in
            await placement.placed.value
            self?.pendingPlacements -= 1
        }
        return placement.done
    }

    /// Joins the capture to the open capture it follows up, else routes it.
    /// Either the polished or the raw words beginning "also" make a
    /// follow-up, so a polish that rewords the start cannot undo one.
    private func place(_ item: QuickCaptureItem, rawText: String) -> Placement {
        if QuickCaptureInbox.saysFollowUp(item.text) || QuickCaptureInbox.saysFollowUp(rawText),
           let latest = openCaptures(for: item).first
        {
            if let task = join(item.id, into: latest.id) {
                Log.backends.notice("Quick capture: saved, a follow-up by its first words")
                return Placement(placed: Task {}, done: Task { await task.value })
            }
            Log.backends.notice("Quick capture: the capture it follows was filed meanwhile, routing")
        }
        Log.backends.notice("Quick capture: saved, routing")
        // Read again: a refused join took in another copy's write.
        let open = openCaptures(for: item)
        let openCaptures = open.prefix(QuickCaptureRouting.maxOpenCaptures).map {
            QuickCaptureOpenCapture(id: $0.id, projectKey: $0.projectKey, summary: $0.summary)
        }
        return route(item, openCaptures: Array(openCaptures))
    }

    /// The captures `item` may follow up, latest first.
    private func openCaptures(for item: QuickCaptureItem) -> [QuickCaptureItem] {
        inbox.items
            .filter { $0.id != item.id && $0.acceptsFollowUp(at: item.capturedAt) }
            .filter { item.group == nil || $0.group == item.group }
            .sorted { $0.lastCapturedAt > $1.lastCapturedAt }
    }

    /// Routes `item` and drafts it where it lands, or joins it to the open
    /// capture the router matched.
    private func route(_ item: QuickCaptureItem, openCaptures: [QuickCaptureOpenCapture]) -> Placement {
        let router = makeRouter()
        let projects = projects(in: item.group)
        let text = item.text
        let historyRecordID = item.historyRecordID
        // What is left once the capture has its place: the joined capture's
        // redraft, or this one's draft.
        let placed = Task { @MainActor [weak self] () -> Task<Void, Never>? in
            let answer = await router.answer(capture: text, projects: projects, openCaptures: openCaptures)
            guard let self else { return nil }
            let route: QuickCaptureRoute
            switch answer {
            case .route(let answered):
                route = answered
            case .join(let target, let classifier, let probability):
                if let task = self.join(item.id, into: target) { return task }
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
            return Task { @MainActor [weak self] in
                await self?.draft(item.id, text: text, destination: route.destination, projects: projects)
                if route.destination == .catchAll, route.suggestion == nil {
                    await self?.suggestRepository(for: item.id, text: text)
                }
            }
        }
        return Placement(
            placed: Task { _ = await placed.value },
            done: Task { await placed.value?.value }
        )
    }

    // MARK: Follow-ups (#965)

    /// Joins capture `id` to `target` as its follow-up, and redrafts the
    /// target in its project: from the draft it has, which may hold the
    /// user's edits, else from all its words. Nil, with nothing changed, only
    /// when the target was filed or discarded meanwhile, also by another
    /// running copy.
    private func join(_ id: UUID, into target: UUID) -> Task<Void, Never>? {
        guard let before = inbox.items.first(where: { $0.id == target }),
              before.state == .ready || before.state == .drafting,
              let capture = inbox.items.first(where: { $0.id == id })
        else { return nil }
        var joined = false
        mutate { joined = $0.join(id, into: target) }
        guard joined else {
            Log.backends.notice("Quick capture: not joined, another running copy filed or discarded that capture")
            return nil
        }
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
        // The capture split out routes now, a run this copy owns (#1507).
        let owner = self.owner
        mutate { inbox in
            result = inbox.split(followUpID, from: id)
            if let capture = result?.capture { inbox.update(capture.id) { $0.runOwner = owner } }
        }
        guard let result else { return nil }
        // A draft running now holds the split words.
        draftRuns[id] = nil
        Log.backends.notice("Quick capture: split a follow-up, \(result.restored ? "earlier draft restored" : "redrafting", privacy: .public)")
        let routing = route(result.capture, openCaptures: []).done
        guard !result.restored, let key = item.projectKey,
              let after = inbox.items.first(where: { $0.id == id })
        else {
            if !result.restored, item.state == .drafting {
                mutate { inbox in inbox.update(id) { if $0.state == .drafting { $0.state = .ready } } }
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
        guard case .project(let routed) = destination else { return }
        let key = projects.first { $0.keys.contains(routed) }?.key ?? routed
        // A later run for this capture (a follow-up joined, #965) makes this
        // one's answers moot.
        draftRunCount += 1
        let run = draftRunCount
        draftRuns[id] = run
        let owner = self.owner
        mutate { inbox in
            inbox.update(id) {
                guard !$0.isFilingOrFiled else { return }
                $0.state = .drafting
                $0.runOwner = owner
                $0.note = nil
                $0.codeCheck = nil
                // A remote project's host drafts on its next session hook.
                if key.hasPrefix(LearnedTermProjectResolver.remoteKeyPrefix) {
                    $0.note = QuickCaptureInbox.waitingForHostNote
                }
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
                self.mutate { inbox in
                    guard inbox.items.first(where: { $0.id == id })?.projectKey == key else { return }
                    inbox.applyFirstDraft(outcome, repository: repository, checking: !agents.isEmpty, to: id)
                }
                // The repository was read when the run started: the
                // capture files where the project files now.
                self.adoptProjects()
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
        adoptProjects()
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
        let project = key.flatMap { key in projects.first { $0.keys.contains(key) } }
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
                // Moved again meanwhile: the answer is for a project the
                // capture left.
                self.mutate { inbox in
                    inbox.update(id) {
                        guard $0.projectKey == project.key, $0.state == .ready, $0.repository == nil else { return }
                        $0.repository = repository
                    }
                }
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

    // MARK: Repository suggestions (#930)

    /// Offers one of the user's recent GitHub repositories that no project
    /// names, when the capture's words name it; nothing when gh failed.
    private func suggestRepository(for id: UUID, text: String) async {
        let repositories = await recentRepositories()
        guard let item = inbox.items.first(where: { $0.id == id }), item.state == .ready,
              item.projectKey == nil, item.suggestion == nil,
              let repository = GitHubRepositorySuggestions.suggestion(
                  for: text, repositories: repositories, projects: projects(), now: now())
        else { return }
        Log.backends.notice("Quick capture: suggesting a recent GitHub repository no project names")
        mutate { inbox in
            inbox.update(id) {
                $0.repositorySuggestion = QuickCaptureItem.RepositorySuggestion(
                    repository: repository.nameWithOwner, name: repository.name)
            }
        }
    }

    /// "Add <name>?" (#930): the repository becomes a project, and the
    /// capture moves there as after a move. When it could not be added the
    /// capture stays, and says so.
    @discardableResult
    package func acceptRepositorySuggestion(_ id: UUID) -> Task<Void, Never>? {
        guard let item = inbox.items.first(where: { $0.id == id }), item.state == .ready, item.projectKey == nil,
              let suggestion = item.repositorySuggestion,
              let key = ProjectRemote(githubRepository: suggestion.repository)?.key
        else { return nil }
        return Task { @MainActor [weak self] in
            guard let self else { return }
            await self.onRepositoryAdded?(suggestion.repository)
            Log.backends.notice("Quick capture: the user added a suggested GitHub repository")
            guard self.projects().contains(where: { $0.keys.contains(key) }) else {
                Log.backends.error("Quick capture: the added repository is not listed")
                self.mutate { inbox in
                    inbox.update(id) {
                        $0.repositorySuggestion = nil
                        $0.note = "\(suggestion.name) could not be added. Move it to a project."
                    }
                }
                return
            }
            await self.move(id, toProjectKey: key)?.value
        }
    }

    package func discard(_ id: UUID) {
        let captureIDs = inbox.items.first { $0.id == id }?.captureIDs ?? [id]
        let saveFailure = mutate { $0.discard(id) }
        draftRuns[id] = nil
        // Unsaved, the capture comes back at launch: its audio stays (#988).
        guard saveFailure == nil else { return }
        for captureID in captureIDs { onDone?(captureID) }
    }

    /// The History records of a capture and its follow-ups.
    private func historyRecordIDs(_ item: QuickCaptureItem) -> [UUID] {
        ([item.historyRecordID] + (item.followUps ?? []).map(\.historyRecordID)).compactMap { $0 }
    }

    /// The only path to `gh issue create`.
    @discardableResult
    ///
    /// With `shown`, it files that draft only: unchanged since and bound
    /// for the same repository, also by another running copy.
    package func file(_ id: UUID, shown: QuickCaptureDraftSnapshot? = nil) -> Task<Void, Never>? {
        let eligible: (QuickCaptureItem) -> Bool = { item in
            item.canFile && shown.map(item.matches) ?? true
        }
        guard inbox.items.first(where: { $0.id == id }).map(eligible) == true,
              let item = claim(id, when: eligible), let repository = item.repository
        else { return nil }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = item.bodyToFile
        return Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.github.createIssue(repository: repository, title: title, body: body)
            let saveFailure = self.mutate { inbox in
                inbox.update(id) { item in
                    guard item.state == .filing else { return }
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
            if saveFailure == nil {
                for captureID in item.captureIDs { self.onDone?(captureID) }
            }
            for recordID in self.historyRecordIDs(item) {
                self.onRouted?(recordID, "Filed in \(repository)")
            }
        }
    }

    /// Comment on #N (#965): the one path to `gh issue comment`, for a draft
    /// that extends an open issue. Like File, only on the user's click.
    @discardableResult
    package func comment(_ id: UUID) -> Task<Void, Never>? {
        guard inbox.items.first(where: { $0.id == id })?.canComment == true,
              let item = claim(id, when: \.canComment),
              let repository = item.repository, let issue = item.relatedIssue
        else { return nil }
        let body = item.commentBody
        return Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.github.commentOnIssue(repository: repository, issue: issue, body: body)
            let saveFailure = self.mutate { inbox in
                inbox.update(id) { item in
                    guard item.state == .filing else { return }
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
            if saveFailure == nil {
                for captureID in item.captureIDs { self.onDone?(captureID) }
            }
            for recordID in self.historyRecordIDs(item) {
                self.onRouted?(recordID, "Commented on \(repository)#\(issue)")
            }
        }
    }

    /// Marks capture `id` filing, as the inbox file has it now, and returns
    /// it as claimed. Nil when another running copy filed it, or changed it
    /// so it no longer passes `eligible`, since this copy last read the file
    /// (#990): what File or Comment sends is the claimed item, never this
    /// copy's older one. Nil too when the claim could not be saved: another
    /// copy reading the file would send it as well (#1288). Run again on
    /// another copy's write after a failed save, the change checks
    /// `eligible` again before it claims.
    private func claim(_ id: UUID, when eligible: @escaping (QuickCaptureItem) -> Bool) -> QuickCaptureItem? {
        let token = QuickCaptureItem.FilingClaim(processID: processID, launch: launch)
        var claimed: QuickCaptureItem?
        let failure = mutate { inbox in
            inbox.update(id) { item in
                guard eligible(item) else { return }
                claimed = item
                item.state = .filing
                item.filingClaim = token
            }
        }
        guard let claimed else {
            Log.backends.notice("Quick capture: not sent, another running copy filed or changed it")
            return nil
        }
        guard failure == nil else {
            Log.backends.error("Quick capture: not sent, the Inbox could not save the filing")
            // Only this claim's own capture goes back: replayed onto another
            // copy's write, it leaves that copy's filing alone.
            mutate { inbox in
                inbox.update(id) {
                    guard $0.state == .filing, $0.filingClaim == token else { return }
                    $0.state = .ready
                    $0.note = "Not sent: the Inbox could not be saved."
                }
            }
            return nil
        }
        return claimed
    }

    // MARK: Spoken review (#927)

    /// The draft as the overlay shows it, nil unless `id` is a ready draft.
    package func reviewSnapshot(_ id: UUID) -> QuickCaptureDraftSnapshot? {
        guard let item = inbox.items.first(where: { $0.id == id }), item.isReadyDraft, let projectName = item.projectName
        else { return nil }
        return QuickCaptureDraftSnapshot(
            id: id, projectName: projectName, title: item.title, body: item.body, repository: item.repository
        )
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
            guard item.matches(shown) else {
                Log.backends.notice("Quick capture review: the draft changed or moved since it was shown; not filed")
                return (QuickCaptureReviewStatus.changedSinceShown, nil)
            }
            guard item.canFile, let task = file(shown.id, shown: shown) else {
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
        let owner = self.owner
        mutate { inbox in
            inbox.update(id) {
                guard !$0.isFilingOrFiled else { return }
                $0.changes = changes
                $0.state = .drafting
                $0.runOwner = owner
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

    /// A coding agent filed the capture itself (#923). It is done as after
    /// File (#1177): the audio of the capture and its follow-ups goes once
    /// the Inbox saved it, and every History record says where it went.
    /// The check runs against the file, which another running copy may
    /// have changed (#990).
    package func markFiled(_ id: UUID, url: String) -> Result<QuickCaptureItem, QuickCaptureInbox.MarkFiledRefusal> {
        let moment = now()
        // Stays notFound when the Inbox is refused and the change never runs.
        var result: Result<QuickCaptureItem, QuickCaptureInbox.MarkFiledRefusal> = .failure(.notFound)
        let saveFailure = mutate { result = $0.markFiled(id, url: url, now: moment) }
        if case .success(let item) = result {
            Log.backends.info("Quick capture: a coding agent filed \(url, privacy: .public)")
            // Unsaved, the capture comes back at launch: its audio stays (#988).
            if saveFailure == nil {
                for captureID in item.captureIDs { onDone?(captureID) }
            }
            if let repository = item.repository {
                for recordID in historyRecordIDs(item) {
                    onRouted?(recordID, "Filed in \(repository)")
                }
            }
        }
        return result
    }

    /// The popover's sentence for a capture the refused Inbox did not take.
    package static let refusedStatus = "Inbox unreadable; capture not saved"

    /// The Inbox pane's Start Over: moves the refused file aside
    /// (`StoredFile.moveAside`) and starts an empty Inbox. Throws, keeping
    /// the refusal, when the move could not be verified.
    @discardableResult
    package func moveAsideAndStartOver() throws -> URL {
        guard storeProblem != nil, let fileURL else { throw StoredFile.MoveAsideFailed() }
        let aside = try StoredFile.moveAside(fileURL, lockedBeside: fileURL)
        seen = StoredFileSeen()
        storeProblem = nil
        onChange?()
        return aside
    }

    /// The Inbox appeared: when another running copy wrote the file since
    /// this copy last read or wrote it, the Inbox takes the file as it is
    /// now (#1126). One `lstat` when nothing changed. A refused file stays
    /// refused, and a failed write's change is not dropped: the next write
    /// applies it on top of the other copy's.
    package func reloadIfChanged() {
        guard let fileURL, storeProblem == nil, !hasUnsavedChanges else { return }
        switch StoredFile.reloadIfChanged(fileURL, seen: &seen, decode: QuickCaptureInboxFile.decode) {
        case nil, .absent?:
            return
        case .loaded(var loaded)?:
            loaded.prune(now: now())
            Log.persistence.notice("Quick capture inbox: another running copy wrote the file, read again")
            inbox = loaded
            // A copy that quit may have left runs no recovery has ended yet.
            recoverAbandonedRuns()
            adoptProjects()
        case .refused(let problem)?:
            Log.persistence.error("Quick capture inbox: another copy left a file this build cannot read")
            storeProblem = problem
            inbox = QuickCaptureInbox()
        }
    }

    /// Whether process `pid` runs: a signal 0 that reaches it, or that it
    /// refuses.
    package nonisolated static func isRunning(_ pid: Int32) -> Bool {
        LibC.kill(pid, 0) == 0 || errno == EPERM
    }

    /// Why a change was not taken: the Inbox file could not be loaded.
    package struct StoreRefused: Error {}

    /// Applies `change` and writes the inbox file. Returns why the write
    /// failed; the change stays in memory either way. A refused Inbox
    /// takes no change and returns `StoreRefused`.
    @discardableResult
    private func mutate(_ change: @escaping (inout QuickCaptureInbox) -> Void) -> (any Error)? {
        guard storeProblem == nil else {
            Log.persistence.error("Quick capture inbox: a change was refused, the file could not be loaded")
            return StoreRefused()
        }
        guard let fileURL else {
            change(&inbox)
            return nil
        }
        // The change applies to what another running copy wrote, if it did.
        switch StoredFile.update(
            fileURL, memory: inbox, seen: &seen, unsaved: &unsaved,
            decode: QuickCaptureInboxFile.decode, encode: QuickCaptureInboxFile.encode,
            write: write, change: change)
        {
        case .written(let updated):
            inbox = updated
            return nil
        case .failed(let updated, let error):
            inbox = updated
            Log.persistence.error("Quick capture inbox: save failed: \(error.localizedDescription, privacy: .public)")
            return error
        case .refused(let problem):
            Log.persistence.error("Quick capture inbox: a change was refused, another copy left a file this build cannot read")
            storeProblem = problem
            inbox = QuickCaptureInbox()
            unsaved = []
            return StoreRefused()
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
