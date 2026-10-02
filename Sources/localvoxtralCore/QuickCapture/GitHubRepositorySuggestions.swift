import Foundation

/// One of the user's GitHub repositories as `gh repo list` reports it
/// (#930). Never a project: only what the Inbox may offer to add.
package struct GitHubListedRepository: Codable, Equatable, Sendable {
    /// `owner/name`.
    package let nameWithOwner: String
    package let description: String?
    package let pushedAt: Date

    package init(nameWithOwner: String, description: String?, pushedAt: Date) {
        self.nameWithOwner = nameWithOwner
        self.description = description
        self.pushedAt = pushedAt
    }

    package var name: String { String(nameWithOwner.split(separator: "/").last ?? "") }
}

/// The repository an unplaced capture may be about (#930, #920 L2): one the
/// user pushed to lately that no listed project names. `gh repo list` is no
/// source of projects; a repository joins the router's options only once the
/// user accepts the suggestion.
package enum GitHubRepositorySuggestions {
    package static let listArguments = [
        "repo", "list", "--json", "nameWithOwner,description,pushedAt", "--limit", "100",
    ]
    /// Pushed within this many days: on the owner's account that leaves 12
    /// of 43 repositories (#920).
    package static let recentDays = 30
    /// The list is fetched at most this often.
    package static let refreshSeconds: TimeInterval = 86_400

    /// The repositories in `listArguments`' output; nil when it is not that
    /// JSON. Entries that are no `owner/name` are dropped.
    package static func repositories(inOutput data: Data) -> [GitHubListedRepository]? {
        struct Wire: Decodable {
            var nameWithOwner: String
            var description: String?
            var pushedAt: String
        }
        guard let wire = try? JSONDecoder().decode([Wire].self, from: data) else { return nil }
        let parser = ISO8601DateFormatter()
        return wire.compactMap { entry in
            guard QuickCaptureInbox.isRepository(entry.nameWithOwner), let pushed = parser.date(from: entry.pushedAt)
            else { return nil }
            let description = entry.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            return GitHubListedRepository(
                nameWithOwner: entry.nameWithOwner,
                description: description?.isEmpty == false ? description : nil,
                pushedAt: pushed
            )
        }
    }

    /// The repository to offer for `capture`: pushed within `recentDays`,
    /// named by no project, and named by the capture (its name's words in a
    /// row, or run together as spoken: "vid theque", "mlx audio swift"), else
    /// sharing at least two longer words with its description. The best
    /// match wins, then the latest push. Nil when none matches.
    package static func suggestion(
        for capture: String, repositories: [GitHubListedRepository], projects: [QuickCaptureProject], now: Date
    ) -> GitHubListedRepository? {
        let named = Set(projects.flatMap { project -> [String] in
            [project.repository, project.issueRepository].compactMap { $0?.lowercased() }
                + project.keys.filter { $0.hasPrefix(ProjectRemote.keyPrefix) }.compactMap { key in
                    ProjectRemote(String(key.dropFirst(ProjectRemote.keyPrefix.count)))?.githubRepository?.lowercased()
                }
        })
        let cutoff = now.addingTimeInterval(-Double(recentDays) * 86_400)
        let words = Self.words(capture)
        let candidates = repositories.filter { $0.pushedAt >= cutoff && !named.contains($0.nameWithOwner.lowercased()) }
        let scored = candidates.compactMap { repository -> (GitHubListedRepository, Int)? in
            let score = Self.score(repository, words: words)
            return score > 0 ? (repository, score) : nil
        }
        return scored.max { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0.pushedAt < rhs.0.pushedAt
        }?.0
    }

    /// 100 when the capture names the repository, else the count of shared
    /// description words when there are at least two.
    private static func score(_ repository: GitHubListedRepository, words: [String]) -> Int {
        let nameWords = Self.words(repository.name)
        let joined = nameWords.joined()
        guard !joined.isEmpty else { return 0 }
        if joined.count >= 3 {
            for start in words.indices {
                var run = ""
                for word in words[start...].prefix(nameWords.count + 2) {
                    run += word
                    if run == joined { return 100 }
                    if run.count >= joined.count { break }
                }
            }
        }
        let captureWords = Set(words.filter { $0.count >= minimumDescriptionWord })
        let shared = Set(Self.words(repository.description ?? "").filter { $0.count >= minimumDescriptionWord })
            .intersection(captureWords)
        return shared.count >= 2 ? shared.count : 0
    }

    /// Description words shorter than this ("the", "with", "tool") match
    /// too much.
    private static let minimumDescriptionWord = 5

    /// Lowercased runs of letters and digits.
    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }
}

/// The user's recent repositories, from `gh repo list` at most once a day
/// (#930). The last answer and when it was asked are kept in a file, so a
/// relaunch does not ask again. A failed `gh` leaves the list empty until
/// the next day's ask.
@MainActor
package final class GitHubRepositoryListCache {
    private struct Stored: Codable {
        var askedAt: Date
        var repositories: [GitHubListedRepository]
    }

    private let fileURL: URL?
    private let fetch: @Sendable () async -> [GitHubListedRepository]?
    private let now: @MainActor () -> Date
    private var stored: Stored?
    private var running: Task<[GitHubListedRepository], Never>?

    package init(
        fileURL: URL?,
        fetch: @escaping @Sendable () async -> [GitHubListedRepository]?,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.fetch = fetch
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            stored = try? decoder.decode(Stored.self, from: data)
        }
    }

    /// The kept list, asked again once it is a day old. Callers at the same
    /// time share one ask.
    package func repositories() async -> [GitHubListedRepository] {
        if let running { return await running.value }
        let moment = now()
        if let stored, moment.timeIntervalSince(stored.askedAt) < GitHubRepositorySuggestions.refreshSeconds,
           moment >= stored.askedAt
        {
            return stored.repositories
        }
        let fetch = fetch
        let task = Task { await fetch() ?? [] }
        running = task
        let repositories = await task.value
        running = nil
        stored = Stored(askedAt: moment, repositories: repositories)
        save()
        return repositories
    }

    private func save() {
        guard let fileURL, let stored else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try PrivateFile.write(encoder.encode(stored), to: fileURL)
        } catch {
            Log.persistence.error("Quick capture: the repository list was not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
