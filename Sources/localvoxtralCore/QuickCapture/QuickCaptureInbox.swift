#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// One quick capture on its way to an issue (#732): the user's words, where
/// the router sent it, and the agent's draft once there is one. Nothing is
/// filed until the user presses File; a capture the router or the agent
/// could not place keeps the user's words.
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
    /// The words as dictated. Never edited, so a bad draft can be redone.
    package let text: String
    /// The History record this capture was saved as, when History is on.
    package var historyRecordID: UUID?
    package var state: State
    package var route: QuickCaptureRoute?
    /// The project the capture belongs to now: the router's choice, or where
    /// the user moved it. Nil for the catch-all.
    package var projectKey: String?
    package var projectName: String?
    /// `owner/name` for `gh issue create --repo`. Resolved from a local
    /// checkout's remote; typed by the user otherwise.
    package var repository: String?
    package var title: String
    package var body: String
    package var relation: QuickCaptureDraft.Draft.Relation
    package var relatedIssue: Int?
    /// Why there is no draft, in one short sentence.
    package var note: String?
    package var filedURL: String?
    /// When File succeeded; what the Inbox's 7-day listing counts from.
    package var filedAt: Date?

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

    /// File needs a repository and a title, and never runs twice.
    package var canFile: Bool {
        state == .ready
            && QuickCaptureInbox.isRepository(repository)
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The body File sends: the draft, or the user's words when there is no
    /// draft, with the dictated words kept under it.
    package var bodyToFile: String {
        let draft = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        return (draft.isEmpty ? "" : draft + "\n\n") + "Dictated:\n\n" + quoted
    }
}

/// Every capture not yet filed or discarded, plus the filed ones for a
/// while, as a value. `QuickCaptureInboxFile` is the file around it.
package struct QuickCaptureInbox: Codable, Equatable, Sendable {
    package static let currentVersion = 1
    /// Filed captures stay listed this long, then drop off.
    package static let keepFiledDays = 7

    package var version: Int = QuickCaptureInbox.currentVersion
    package var items: [QuickCaptureItem] = []

    package init(items: [QuickCaptureItem] = []) {
        self.items = items
    }

    package mutating func add(_ item: QuickCaptureItem) {
        items.insert(item, at: 0)
    }

    package mutating func update(_ id: UUID, _ change: (inout QuickCaptureItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    package mutating func discard(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// The router's answer. A project gets its name; the catch-all waits.
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
                item.state = .ready
                item.note = "Not routed to a project. Move it to one."
            }
        }
    }

    package mutating func applyDraft(_ outcome: QuickCaptureDraft.Outcome, repository: String?, to id: UUID) {
        update(id) { item in
            item.state = .ready
            if item.repository == nil { item.repository = repository }
            switch outcome {
            case .draft(let draft, _):
                item.title = draft.title
                item.body = draft.body
                item.relation = draft.relation
                item.relatedIssue = draft.issue
                item.note = nil
            case .failed(let failure):
                item.note = Self.note(for: failure)
            case .notRun(let reason):
                item.note = Self.note(for: reason)
            }
        }
    }

    /// The user moved it. A draft written for another repository stays as
    /// text the user can edit; the repository is the new project's.
    package mutating func move(_ id: UUID, to project: QuickCaptureProject?, repository: String?) {
        update(id) { item in
            item.projectKey = project?.key
            item.projectName = project?.name
            item.repository = repository
            item.relation = .none
            item.relatedIssue = nil
            if project != nil, item.note == "Not routed to a project. Move it to one." { item.note = nil }
        }
    }

    /// Drops captures filed more than `keepFiledDays` ago.
    package mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.keepFiledDays) * 86_400)
        items.removeAll { $0.state == .filed && ($0.filedAt ?? $0.capturedAt) < cutoff }
    }

    /// `owner/name`, GitHub's charset.
    package static func isRepository(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    static func note(for failure: ProjectTermProposal.Failure) -> String {
        switch failure {
        case .agentNotFound: "No Claude Code or Mistral Vibe found to draft it."
        case .timedOut: "The draft took too long."
        case .budgetExceeded, .turnLimit: "The draft hit its cost or turn limit."
        default: "The draft failed."
        }
    }

    static func note(for reason: QuickCaptureDraft.NotRun) -> String {
        switch reason {
        case .catchAll: "Not routed to a project. Move it to one."
        case .remoteProject: "No draft for a project on another machine."
        case .checkoutMissing: "The project's folder is gone."
        }
    }
}

package enum QuickCaptureInboxFile {
    /// An unreadable or future file reads as empty and is left in place.
    package static func load(from url: URL) -> QuickCaptureInbox {
        guard let data = try? Data(contentsOf: url) else { return QuickCaptureInbox() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let inbox = try? decoder.decode(QuickCaptureInbox.self, from: data),
              inbox.version <= QuickCaptureInbox.currentVersion
        else {
            Log.persistence.error("Quick capture inbox: unreadable file kept aside")
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable"))
            return QuickCaptureInbox()
        }
        // A capture interrupted mid-route or mid-draft by a quit waits for
        // the user with its words.
        var result = inbox
        for index in result.items.indices where [.routing, .drafting, .filing].contains(result.items[index].state) {
            result.items[index].state = .ready
            if result.items[index].title.isEmpty, result.items[index].note == nil {
                result.items[index].note = "Interrupted before a draft."
            }
        }
        return result
    }

    /// The file holds dictated words, so it is never readable by anyone
    /// else, not even for a moment: a 0600 temporary file renamed over it.
    package static func save(_ inbox: QuickCaptureInbox, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fileManager.createFile(
            atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: encoder.encode(inbox))
            try handle.close()
            // rename(2) replaces the old file in one step, on both platforms.
            guard rename(temporary.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
