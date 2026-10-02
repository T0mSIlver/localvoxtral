#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Where an issue's draft stands against the code (#918): the agent's check
/// that follows the first draft.
package struct QuickCaptureCodeCheck: Codable, Equatable, Sendable {
    package enum State: String, Codable, Equatable, Sendable {
        /// The agent is reading the code; the first draft can be filed.
        case checking
        /// The draft shown is the agent's, unless the user had edited it.
        case checked
        /// The check did not finish; the first draft stands. `note` says why.
        case failed
    }

    package var state: State
    /// The repository paths the agent read, when it checked.
    package var filesRead: [String]
    /// `ProjectTermProposal.Agent.rawValue` of the agent that checked.
    package var agent: String?
    /// True when the check finished after the user edited the draft: their
    /// text stays, and the agent's is not applied.
    package var keptEdits: Bool

    package init(state: State, filesRead: [String] = [], agent: String? = nil, keptEdits: Bool = false) {
        self.state = state
        self.filesRead = filesRead
        self.agent = agent
        self.keptEdits = keptEdits
    }
}

/// One quick capture on its way to an issue (#732): the user's words, where
/// the router sent it, and its draft once there is one. Nothing is filed
/// until the user presses File; a capture the router or the agent could not
/// place keeps the user's words.
///
/// The Inbox file's schema, read by other tools (the Inbox CLI, #923; the
/// needs-you cue, #909). Fields added since version 1 are optional, so an
/// older file loads:
/// - `kind` (#918): nil until a first draft sorts it, and for captures
///   saved before; read nil as `.issue` (`isIssue`).
/// - `codeCheck` (#918): an issue's check against the code, or the agent's
///   draft that read it; nil for other kinds and before an agent answered.
/// - `followUps` (#965): later captures joined to this one; `text` stays
///   the first capture's words, and `words` is all of them.
/// - `commentedOn` (#965): the issue a comment was posted on instead of
///   filing; `filedURL` is then the comment's URL.
/// A draft is final once `state == .ready`, `title` is set and
/// `codeCheck?.state != .checking`.
package struct QuickCaptureItem: Codable, Equatable, Sendable, Identifiable {
    package enum State: String, Codable, Equatable, Sendable {
        case routing
        case drafting
        /// Waiting for the user: a draft, or the reason there is none.
        case ready
        case filing
        case filed
    }

    package let id: UUID
    package let capturedAt: Date
    /// The words as dictated, then as polished once before routing (#970).
    /// Never edited after that, so a bad draft can be redone. History keeps
    /// the raw transcript.
    package var text: String
    /// The History record this capture was saved as, when History is on.
    package var historyRecordID: UUID?
    package var state: State
    package var route: QuickCaptureRoute?
    /// The project the capture belongs to now: the router's choice, or where
    /// the user moved it. Nil for the catch-all.
    package var projectKey: String?
    package var projectName: String?
    /// The project the router guessed under its bar (#938), while the
    /// capture waits unplaced. Nothing is drafted for it until the user
    /// moves the capture there.
    package var suggestion: Suggestion?

    package struct Suggestion: Codable, Equatable, Sendable {
        package let projectKey: String
        package let projectName: String

        package init(projectKey: String, projectName: String) {
            self.projectKey = projectKey
            self.projectName = projectName
        }
    }
    /// `owner/name` for `gh issue create --repo`. Resolved from a local
    /// checkout's remote; typed by the user otherwise.
    package var repository: String?
    /// The draft's short title, for every kind.
    package var title: String
    /// An issue's body, a question's answer, or a task or note restated.
    package var body: String
    package var kind: QuickCaptureKind?
    package var codeCheck: QuickCaptureCodeCheck?
    package var relation: QuickCaptureDraft.Draft.Relation
    package var relatedIssue: Int?
    /// Why there is no draft, in one short sentence.
    package var note: String?
    package var filedURL: String?
    /// When File succeeded; what the Inbox's 7-day listing counts from.
    package var filedAt: Date?
    /// The changes the user asked for by voice (#927), oldest first. The
    /// redraft reads them with `text`, which stays as dictated.
    package var changes: [String]?
    /// Later captures joined to this one (#965), oldest first.
    package var followUps: [FollowUp]?
    /// The issue Comment on #N posted to (#965); nil when filed as an issue.
    package var commentedOn: Int?

    /// A later capture joined to this one (#965): it began "also", or the
    /// router matched it here. Its words, History record and audio id stay
    /// its own, so Split can take it back out.
    package struct FollowUp: Codable, Equatable, Sendable, Identifiable {
        package let id: UUID
        package let capturedAt: Date
        package let text: String
        package var historyRecordID: UUID?
        /// The item's draft when this joined, for Split to give back; nil
        /// when it had none.
        package var draftBefore: DraftSnapshot?

        package init(id: UUID, capturedAt: Date, text: String, historyRecordID: UUID?, draftBefore: DraftSnapshot?) {
            self.id = id
            self.capturedAt = capturedAt
            self.text = text
            self.historyRecordID = historyRecordID
            self.draftBefore = draftBefore
        }
    }

    /// A draft as it stood, to put back.
    package struct DraftSnapshot: Codable, Equatable, Sendable {
        package var title: String
        package var body: String
        package var kind: QuickCaptureKind?
        package var codeCheck: QuickCaptureCodeCheck?
        package var relation: QuickCaptureDraft.Draft.Relation
        package var relatedIssue: Int?
    }

    package init(id: UUID = UUID(), capturedAt: Date, text: String, historyRecordID: UUID? = nil) {
        self.id = id
        self.capturedAt = capturedAt
        self.text = text
        self.historyRecordID = historyRecordID
        self.state = .routing
        self.title = ""
        self.body = ""
        self.relation = .none
    }

    /// A draft waiting for the user under a project: what the needs-you cue
    /// and the spoken review (#927) work on. An issue still being checked
    /// against the code (#918) is not ready yet.
    package var isReadyDraft: Bool {
        state == .ready && projectKey != nil && projectName != nil
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && codeCheck?.state != .checking
    }

    /// Only an issue is filed; a capture no draft sorted counts as one.
    package var isIssue: Bool { (kind ?? .issue) == .issue }

    /// Every word dictated for this idea: the first capture's, then each
    /// follow-up's (#965).
    package var words: String {
        ([text] + (followUps ?? []).map(\.text)).joined(separator: "\n\n")
    }

    /// The ids of its captures: its own, then each follow-up's. A voice
    /// memo's recording is kept under one of them (#988).
    package var captureIDs: [UUID] {
        [id] + (followUps ?? []).map(\.id)
    }

    /// When the last of its captures was made.
    package var lastCapturedAt: Date {
        (followUps ?? []).map(\.capturedAt).reduce(capturedAt, max)
    }

    /// A new capture may join it (#965): not filed or on its way there, and
    /// captured or last joined within the hour of `date`, either side (a
    /// voice memo can be older than the capture it follows).
    package func acceptsFollowUp(at date: Date) -> Bool {
        (state == .ready || state == .drafting)
            && abs(date.timeIntervalSince(lastCapturedAt)) <= QuickCaptureInbox.followUpWindow
    }

    /// The draft's title, else the first words, for a router option.
    package var summary: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? QuickCaptureDraft.oneLine(text, limit: 160) : title
    }

    package var draftSnapshot: DraftSnapshot? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return DraftSnapshot(
            title: title, body: body, kind: kind, codeCheck: codeCheck, relation: relation, relatedIssue: relatedIssue
        )
    }

    /// Comment on #N (#965): an issue's draft that extends an open issue of
    /// its repository, when File could run.
    package var canComment: Bool {
        canFile && relation == .extends && relatedIssue != nil
    }

    /// What Comment on #N posts: the draft's title over what File would send.
    package var commentBody: String {
        "**\(title.trimmingCharacters(in: .whitespacesAndNewlines))**\n\n" + bodyToFile
    }

    /// File needs an issue, a repository and a title, and never runs twice.
    /// It does not wait for the check against the code.
    package var canFile: Bool {
        state == .ready
            && isIssue
            && QuickCaptureInbox.isRepository(repository)
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A draft that failed, or whose check failed, can be drafted again in
    /// its project.
    package var canDraftAgain: Bool {
        state == .ready && projectKey != nil && (title.isEmpty || codeCheck?.state == .failed)
    }

    /// The body File sends: the draft, or the user's words when there is no
    /// draft, with the dictated words kept under it.
    package var bodyToFile: String {
        let draft = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = words.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        return (draft.isEmpty ? "" : draft + "\n\n") + "Dictated:\n\n" + quoted
    }
}

/// Every capture not yet filed or discarded, plus the filed ones for a
/// while, as a value. `QuickCaptureInboxFile` is the file around it.
package struct QuickCaptureInbox: Codable, Equatable, Sendable {
    package static let currentVersion = 1
    /// Filed captures stay listed this long, then drop off.
    package static let keepFiledDays = 7
    /// A new capture joins an item captured or joined this recently (#965).
    package static let followUpWindow: TimeInterval = 3600

    package var version: Int = QuickCaptureInbox.currentVersion
    package var items: [QuickCaptureItem] = []

    package init(items: [QuickCaptureItem] = []) {
        self.items = items
    }

    /// The captures whose recordings stay: every capture not yet filed,
    /// and each of its follow-ups (#988).
    package var recordingIDsToKeep: Set<UUID> {
        Set(items.filter { $0.state != .filed }.flatMap(\.captureIDs))
    }

    /// Whether capture `id` is listed, on its own or as a follow-up.
    package func holds(_ id: UUID) -> Bool {
        items.contains { $0.captureIDs.contains(id) }
    }

    package mutating func add(_ item: QuickCaptureItem) {
        items.insert(item, at: 0)
    }

    package mutating func update(_ id: UUID, _ change: (inout QuickCaptureItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    /// Every capture and suggestion under the key and name of the project
    /// that holds its key now. A capture still drafting or checking keeps
    /// its key, since its run answers for it.
    package func adopting(_ projects: [QuickCaptureProject]) -> QuickCaptureInbox {
        var result = self
        for index in result.items.indices {
            let item = result.items[index]
            if let key = item.projectKey, let project = projects.first(where: { $0.keys.contains(key) }) {
                let runs = item.state == .drafting || item.codeCheck?.state == .checking
                if !runs { result.items[index].projectKey = project.key }
                result.items[index].projectName = project.name
                Self.followFilingChoice(of: project, &result.items[index])
            }
            if let suggestion = item.suggestion,
               let project = projects.first(where: { $0.keys.contains(suggestion.projectKey) })
            {
                result.items[index].suggestion = QuickCaptureItem.Suggestion(projectKey: project.key, projectName: project.name)
            }
        }
        return result
    }

    /// A capture not filed yet files where its project files now: a fork's
    /// "File issues here" choice changed since it took the fork's or the
    /// upstream's repository. The issue its draft extended or duplicated
    /// belongs to the other repository, so the link goes. A repository the
    /// user typed for the capture is neither of the project's and stays.
    private static func followFilingChoice(of project: QuickCaptureProject, _ item: inout QuickCaptureItem) {
        guard item.state != .filing, item.state != .filed,
              let target = project.issueRepository, let current = item.repository,
              current.caseInsensitiveCompare(target) != .orderedSame
        else { return }
        let projectRepositories = [project.repository, project.github?.parent].compactMap { $0 }
        guard projectRepositories.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) else { return }
        item.repository = target
        item.relation = .none
        item.relatedIssue = nil
    }

    package mutating func discard(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// The router's answer. A project gets its name; the catch-all waits,
    /// with the router's guess when it made one.
    package mutating func applyRoute(_ route: QuickCaptureRoute, to id: UUID, projects: [QuickCaptureProject]) {
        update(id) { item in
            item.route = route
            if case .project(let key) = route.destination, let project = projects.first(where: { $0.key == key }) {
                item.projectKey = key
                item.projectName = project.name
                item.state = .drafting
            } else {
                item.projectKey = nil
                item.projectName = nil
                item.suggestion = route.suggestion.flatMap { key in
                    projects.first { $0.key == key }.map { QuickCaptureItem.Suggestion(projectKey: key, projectName: $0.name) }
                }
                item.state = .ready
                item.note = "Not routed to a project. Move it to one."
            }
        }
    }

    /// The first draft (#918). A draft makes the capture ready to review,
    /// and an issue's check starts when `checking`. A failure leaves it
    /// drafting when the agent will draft it from scratch, else ready with
    /// the reason.
    package mutating func applyFirstDraft(
        _ outcome: QuickCaptureDraft.Outcome, repository: String?, checking: Bool, to id: UUID
    ) {
        update(id) { item in
            if item.repository == nil { item.repository = repository }
            switch outcome {
            case .draft(let draft, _):
                item.state = .ready
                item.kind = draft.kind
                item.title = draft.title
                item.body = draft.body
                item.relation = draft.relation
                item.relatedIssue = draft.issue
                item.note = nil
                item.codeCheck = draft.kind == .issue && checking ? QuickCaptureCodeCheck(state: .checking) : nil
            case .failed(let failure):
                guard !checking else { return }
                item.state = .ready
                item.note = Self.note(for: failure)
            case .notRun(let reason):
                guard !checking else { return }
                item.state = .ready
                item.note = Self.note(for: reason)
            }
        }
    }

    /// The agent's run: the draft itself when no first draft was shown, else
    /// its check. A check replaces the first draft only if the user left it
    /// as it came (`firstDraft`); a filed or discarded capture ignores it.
    package mutating func applyDraft(
        _ outcome: QuickCaptureDraft.Outcome,
        repository: String?,
        firstDraft: (title: String, body: String)? = nil,
        to id: UUID
    ) {
        update(id) { item in
            if item.state == .ready, item.codeCheck?.state == .checking {
                Self.applyCheck(outcome, firstDraft: firstDraft, to: &item)
                return
            }
            guard item.state == .drafting else { return }
            item.state = .ready
            if item.repository == nil { item.repository = repository }
            switch outcome {
            case .draft(let draft, _):
                item.kind = .issue
                item.title = draft.title
                item.body = draft.body
                item.relation = draft.relation
                item.relatedIssue = draft.issue
                item.note = nil
                // The agent read the code to draft it.
                item.codeCheck = QuickCaptureCodeCheck(
                    state: .checked, filesRead: draft.filesRead ?? [], agent: draft.agent?.rawValue
                )
            case .failed(let failure):
                item.note = Self.note(for: failure)
            case .notRun(let reason):
                item.note = Self.note(for: reason)
            }
        }
    }

    private static func applyCheck(
        _ outcome: QuickCaptureDraft.Outcome, firstDraft: (title: String, body: String)?, to item: inout QuickCaptureItem
    ) {
        switch outcome {
        case .draft(let draft, _):
            let untouched = firstDraft.map { $0.title == item.title && $0.body == item.body } ?? false
            item.codeCheck = QuickCaptureCodeCheck(
                state: .checked, filesRead: draft.filesRead ?? [], agent: draft.agent?.rawValue, keptEdits: !untouched
            )
            guard untouched else { return }
            item.title = draft.title
            item.body = draft.body
            item.relation = draft.relation
            item.relatedIssue = draft.issue
            item.note = nil
        case .failed(let failure):
            item.codeCheck?.state = .failed
            item.note = Self.checkNote(for: failure)
        case .notRun(let reason):
            item.codeCheck?.state = .failed
            item.note = Self.note(for: reason)
        }
    }

    /// The user moved it. A draft written for another repository stays as
    /// text the user can edit; the repository is the new project's.
    package mutating func move(_ id: UUID, to project: QuickCaptureProject?, repository: String?) {
        update(id) { item in
            item.projectKey = project?.key
            item.projectName = project?.name
            item.suggestion = nil
            item.repository = repository
            item.relation = .none
            item.relatedIssue = nil
            // A check still reading the old project's code no longer applies.
            if item.codeCheck?.state == .checking { item.codeCheck = nil }
            if project != nil, item.note == "Not routed to a project. Move it to one." { item.note = nil }
        }
    }

    /// Moves capture `followUpID` into `target` as its follow-up (#965).
    /// False, with nothing changed, when either is gone.
    @discardableResult
    package mutating func join(_ followUpID: UUID, into target: UUID) -> Bool {
        guard followUpID != target,
              let capture = items.first(where: { $0.id == followUpID }),
              items.contains(where: { $0.id == target })
        else { return false }
        items.removeAll { $0.id == followUpID }
        update(target) { item in
            let followUp = QuickCaptureItem.FollowUp(
                id: capture.id, capturedAt: capture.capturedAt, text: capture.text,
                historyRecordID: capture.historyRecordID, draftBefore: item.draftSnapshot
            )
            item.followUps = (item.followUps ?? []) + [followUp]
        }
        return true
    }

    /// A capture that says it continues the last one (#965): it starts
    /// "also" or "for that idea", after an "and" or "oh" at most.
    package static func saysFollowUp(_ text: String) -> Bool {
        var words = text.lowercased().split { !$0.isLetter && $0 != "'" }.prefix(5).map(String.init)
        while let first = words.first, ["and", "oh"].contains(first) { words.removeFirst() }
        return words.first == "also" || words.prefix(3) == ["for", "that", "idea"]
    }

    /// Takes follow-up `followUpID` back out of `id` as its own capture,
    /// placed right above it. The last follow-up gives the item back the
    /// draft it had before it joined; `restored` says so, and otherwise the
    /// draft still holds the split words and needs redrafting.
    package mutating func split(
        _ followUpID: UUID, from id: UUID
    ) -> (capture: QuickCaptureItem, restored: Bool)? {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let followUps = items[index].followUps,
              let position = followUps.firstIndex(where: { $0.id == followUpID })
        else { return nil }
        let followUp = followUps[position]
        var restored = false
        update(id) { item in
            item.followUps?.remove(at: position)
            if item.followUps?.isEmpty == true { item.followUps = nil }
            if position == followUps.count - 1, let before = followUp.draftBefore {
                item.title = before.title
                item.body = before.body
                item.kind = before.kind
                item.codeCheck = before.codeCheck
                item.relation = before.relation
                item.relatedIssue = before.relatedIssue
                item.state = .ready
                item.note = nil
                // The check the follow-up interrupted never lands.
                if item.codeCheck?.state == .checking {
                    item.codeCheck?.state = .failed
                    item.note = "Not checked against the code: a follow-up interrupted the check."
                }
                restored = true
            }
        }
        let capture = QuickCaptureItem(
            id: followUp.id, capturedAt: followUp.capturedAt, text: followUp.text, historyRecordID: followUp.historyRecordID
        )
        items.insert(capture, at: index)
        return (capture, restored)
    }

    package enum MarkFiledRefusal: Error, Equatable, Sendable {
        case notFound
        /// Still routing, drafting or filing, or already filed.
        case notReady(QuickCaptureItem.State)
        /// Not `https://github.com/<owner>/<name>/issues/<n>`, or another
        /// repository than the capture's.
        case notAnIssue
        case otherRepository(String)
        /// A question, task or note (#918) is never filed.
        case notAnIssueKind(QuickCaptureKind)
    }

    /// A coding agent filed it with its own `gh` (#923): records the URL as
    /// File's success would. A capture with no repository takes the URL's.
    package mutating func markFiled(
        _ id: UUID, url: String, now: Date
    ) -> Result<QuickCaptureItem, MarkFiledRefusal> {
        guard let item = items.first(where: { $0.id == id }) else { return .failure(.notFound) }
        guard item.state == .ready else { return .failure(.notReady(item.state)) }
        if let kind = item.kind, kind != .issue { return .failure(.notAnIssueKind(kind)) }
        guard let repository = Self.issueRepository(url) else { return .failure(.notAnIssue) }
        if let expected = item.repository, expected.caseInsensitiveCompare(repository) != .orderedSame {
            return .failure(.otherRepository(expected))
        }
        var filed = item
        update(id) { item in
            item.state = .filed
            item.filedURL = url
            item.filedAt = now
            item.note = nil
            if item.repository == nil { item.repository = repository }
            filed = item
        }
        return .success(filed)
    }

    /// `owner/name` of a GitHub issue URL, nil for anything else.
    package static func issueRepository(_ url: String) -> String? {
        let pattern = #"^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/[1-9][0-9]*$"#
        guard url.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return url.dropFirst("https://github.com/".count).components(separatedBy: "/issues/").first
    }

    /// Drops captures filed more than `keepFiledDays` ago.
    package mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.keepFiledDays) * 86_400)
        items.removeAll { $0.state == .filed && ($0.filedAt ?? $0.capturedAt) < cutoff }
    }

    /// `owner/name`, GitHub's charset. Neither part is `.` or `..`: a
    /// host's value becomes a `gh api repos/…` path (#926).
    package static func isRepository(_ value: String?) -> Bool {
        guard let value,
              value.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        else { return false }
        return !value.split(separator: "/").contains { $0.allSatisfy { $0 == "." } }
    }

    static func note(for failure: ProjectTermProposal.Failure) -> String {
        switch failure {
        case .agentNotFound: "No Claude Code, Mistral Vibe or opencode found to draft it."
        case .timedOut: "The draft took too long."
        case .budgetExceeded, .turnLimit: "The draft hit its cost or turn limit."
        default: "The draft failed."
        }
    }

    static func checkNote(for failure: ProjectTermProposal.Failure) -> String {
        switch failure {
        case .agentNotFound: "Not checked against the code: no Claude Code, Mistral Vibe or opencode found."
        case .timedOut: "Not checked against the code: the check took too long."
        case .budgetExceeded, .turnLimit: "Not checked against the code: the check hit its cost or turn limit."
        default: "Not checked against the code: the check failed."
        }
    }

    /// While a remote project's draft waits for one of its sessions to
    /// send a hook, which it does only while it works.
    package static let waitingForHostNote = "Drafts when a session of this project is next active."

    static func note(for reason: QuickCaptureDraft.NotRun) -> String {
        switch reason {
        case .catchAll: "Not routed to a project. Move it to one."
        case .remoteProject: "No draft for a project on another machine."
        case .checkoutMissing: "The project's folder is gone."
        case .noHostSession: "No session of this project answered on its host."
        case .hostNeedsUpdate: "Update the host to draft there."
        }
    }
}

package enum QuickCaptureInboxFile {
    /// An unreadable or future file is refused and left in place (#989):
    /// the model then refuses every write, since the next one would replace
    /// the user's captures.
    package static func load(from url: URL) -> StoredFileLoad<QuickCaptureInbox> {
        let load = StoredFile.load(
            QuickCaptureInbox.self, from: url, currentVersion: QuickCaptureInbox.currentVersion, decoder: decoder)
        guard let inbox = load.value else { return load }
        return .loaded(resumingInterrupted(inbox))
    }

    /// The file's contents as written, for a save that re-reads what another
    /// running copy wrote (#990): its captures mid-route are not interrupted.
    package static func decode(_ data: Data) -> StoredFileLoad<QuickCaptureInbox> {
        StoredFile.decode(
            QuickCaptureInbox.self, from: data, name: "quick-captures.json",
            currentVersion: QuickCaptureInbox.currentVersion, decoder: decoder)
    }

    /// A capture interrupted mid-route or mid-draft by a quit waits for the
    /// user with its words.
    package static func resumingInterrupted(_ inbox: QuickCaptureInbox) -> QuickCaptureInbox {
        var result = inbox
        for index in result.items.indices where result.items[index].codeCheck?.state == .checking {
            result.items[index].codeCheck?.state = .failed
            result.items[index].note = "Interrupted before the check against the code."
        }
        for index in result.items.indices where [.routing, .drafting, .filing].contains(result.items[index].state) {
            result.items[index].state = .ready
            if result.items[index].title.isEmpty,
               [nil, QuickCaptureInbox.waitingForHostNote].contains(result.items[index].note)
            {
                result.items[index].note = "Interrupted before a draft."
            }
        }
        return result
    }

    package static func encode(_ inbox: QuickCaptureInbox) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(inbox)
    }

    package static func save(_ inbox: QuickCaptureInbox, to url: URL) throws {
        try PrivateFile.write(encode(inbox), to: url)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A file that holds the user's words or audio names.
package enum PrivateFile {
    /// Never readable by anyone else, not even for a moment, and never left
    /// empty by a power cut: `DurableFile`'s 0600 temporary file, synced and
    /// renamed over the old one.
    package static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        try DurableFile.write(data, to: url)
    }
}
