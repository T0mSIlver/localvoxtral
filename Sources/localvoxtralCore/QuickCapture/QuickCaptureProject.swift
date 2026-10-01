import Foundation

/// One project a quick capture can be routed to (#725), as the classifier
/// sees it. Repository names alone route badly ("sometimes it's not
/// representative of the project"), so each goes out with a description:
/// the user's line, else GitHub's description (#926), else the one its
/// agent wrote (#891); its README's first paragraphs; GitHub's topics; its
/// own terms.
///
/// The projects are the learned terms' (`LearnedTerms.listedProjects`): one
/// per repository, named after it (#971), whichever checkouts it has on the
/// Mac and on hosts.
/// Nothing here comes from the screen or the clipboard.
package struct QuickCaptureProject: Equatable, Sendable {
    /// `LearnedTermProject.key`: a main checkout's path, or `remote:<label>`.
    /// For a repository checked out in several places, the Mac's checkout
    /// when its folder is there, since it drafts without waiting for a host.
    package let key: String
    /// Every checkout's key, `key` first, then the repository record's
    /// (`repo:<remote>`) when the project has a remote.
    package let keys: [String]
    package let name: String
    /// The README's opening paragraphs: read from a local checkout, or kept
    /// from the host's report for a remote project (#745). Nil when neither
    /// has one.
    package let summary: String?
    package let terms: [String]
    /// The project's agent's sentence about it (#891), when it answered.
    package let agentLine: String?
    /// What the user wrote about the project, when they did. It replaces
    /// GitHub's description and the agent's sentence.
    package let userLine: String?
    /// `owner/name` from the project's `origin` or the user's answer.
    package let repository: String?
    /// Where File sends its issues (`LearnedTermProject.issueRepository`).
    package let issueRepository: String?
    package let github: GitHubRepositoryFacts?
    /// The user's Work or Personal choice (#1005), nil in no group.
    package let group: ProjectGroup?

    package init(
        key: String, name: String, summary: String?, terms: [String],
        agentLine: String? = nil, userLine: String?,
        keys: [String]? = nil, repository: String? = nil, issueRepository: String? = nil,
        github: GitHubRepositoryFacts? = nil, group: ProjectGroup? = nil
    ) {
        self.key = key
        self.keys = keys ?? [key]
        self.name = name
        self.summary = summary
        self.terms = terms
        self.agentLine = agentLine
        self.userLine = userLine
        self.repository = repository
        self.issueRepository = issueRepository ?? repository
        self.github = github
        self.group = group
    }

    func renamed(_ name: String) -> QuickCaptureProject {
        QuickCaptureProject(
            key: key, name: name, summary: summary, terms: terms, agentLine: agentLine, userLine: userLine,
            keys: keys, repository: repository, issueRepository: issueRepository, github: github, group: group
        )
    }

    /// GitHub's description, as a sentence, and the upstream a fork has.
    package var githubLine: String? {
        guard let github else { return nil }
        var parts: [String] = []
        if let description = github.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            let clipped = QuickCaptureProjects.clipped(description, to: QuickCaptureProjects.maxUserLineCharacters)
            parts.append(clipped.hasSuffix(".") || clipped.hasSuffix("…") ? clipped : clipped + ".")
        }
        if let parent = github.parent { parts.append("A fork of \(parent).") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The description filled in without the user: GitHub's, else the
    /// agent's sentence, else the README summary, cut like the user's line.
    /// The Projects pane shows it until the user writes their
    /// own.
    package var automaticLine: String? {
        githubLine ?? agentLine
            ?? summary.map { QuickCaptureProjects.clipped($0, to: QuickCaptureProjects.maxUserLineCharacters) }
    }

    /// The text the classifier reads for this option, in the order #920
    /// measured: the line, the README, GitHub's topics, the terms.
    package var description: String {
        var parts: [String] = ["Project \(name)."]
        if let line = userLine ?? githubLine ?? agentLine { parts.append(line) }
        if let summary { parts.append(summary) }
        if userLine == nil, let topics = github?.topics, !topics.isEmpty {
            parts.append("Topics: " + topics.prefix(QuickCaptureProjects.maxTopics).joined(separator: ", ") + ".")
        }
        if !terms.isEmpty { parts.append("Its names: " + terms.joined(separator: ", ") + ".") }
        return parts.joined(separator: " ")
    }
}

package enum QuickCaptureProjects {
    package static let maxTerms = 30
    /// Two paragraphs, 400 characters: on the Jev replay (2026-09-26) that
    /// routed a little better than one paragraph or three, and a first
    /// paragraph alone is often a tagline ("Knowledge is announced on video").
    package static let maxSummaryCharacters = 400
    package static let summaryParagraphs = 2
    package static let maxUserLineCharacters = 200

    /// GitHub allows 20 topics; the router reads this many.
    package static let maxTopics = 12

    /// Every project a capture can go to (`LearnedTerms.listedProjects`),
    /// most recent first, each with its description. Projects that name one
    /// repository are one option (#926): the Mac's checkout's key, else the
    /// most recent, with the terms of all of them. A Mac checkout whose
    /// folder is gone leads only when no host has the repository.
    ///
    /// - Parameters:
    ///   - userLines: the user's line per project key.
    ///   - readme: the README text of a local project root, nil when none.
    ///   - checkoutExists: whether a local project root is still a folder.
    package static func projects(
        from learned: LearnedTerms,
        userLines: [String: String],
        now: Date,
        readme: (String) -> String?,
        checkoutExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) -> [QuickCaptureProject] {
        let listed = learned.listedCheckouts(now: now)
        var groups: [[LearnedTermProject]] = []
        var groupOfRepository: [String: Int] = [:]
        for project in listed {
            let repository = project.repositoryRecordKey ?? project.repository.map { "github:" + $0 }
            if let repository, let index = groupOfRepository[repository] {
                groups[index].append(project)
            } else {
                if let repository { groupOfRepository[repository] = groups.count }
                groups.append([project])
            }
        }
        let built = groups.map { group -> (project: QuickCaptureProject, remote: ProjectRemote?) in
            var members = group.filter { $0.key.hasPrefix("/") } + group.filter { !$0.key.hasPrefix("/") }
            if group.count > 1, let lead = members.firstIndex(where: { !$0.key.hasPrefix("/") || checkoutExists($0.key) }) {
                members.insert(members.remove(at: lead), at: 0)
            }
            let primary = members[0]
            // The repository's own record holds a linked project's terms and
            // its agent's answer (#971).
            let remote = primary.isLinkedCheckout ? primary.projectRemote : nil
            let repositoryRecord = remote.flatMap { remote in learned.projects.first { $0.key == remote.key } }
            let records = members + (repositoryRecord.map { [$0] } ?? [])
            var seen = Set<String>()
            var terms: [String] = []
            for member in records {
                for term in learned.confirmedTerms(projectKey: member.key) + learned.unconfirmedProposals(projectKey: member.key)
                where seen.insert(term.caseFoldedForMatching).inserted {
                    terms.append(term)
                }
            }
            var summary: String?
            for member in members where summary == nil {
                summary = member.key.hasPrefix("/") ? readme(member.key).flatMap(Self.summary(ofReadme:)) : member.summary
            }
            let keys = members.map(\.key) + (remote.map { [$0.key] } ?? [])
            let userLine = keys.lazy.compactMap { key in
                userLines[key]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : clipped($0, to: maxUserLineCharacters) }
            }.first
            let github = records.lazy.compactMap(\.github).first
            let project = QuickCaptureProject(
                key: primary.key,
                name: remote?.name ?? primary.name,
                summary: summary.map { clipped($0, to: maxSummaryCharacters) },
                terms: Array(terms.prefix(maxTerms)),
                agentLine: records.lazy.compactMap(\.agentLine).first,
                userLine: userLine,
                keys: keys,
                repository: primary.repository,
                issueRepository: primary.issueRepository,
                github: github,
                group: keys.lazy.compactMap { learned.group(ofProjectKey: $0) }.first
            )
            return (project, remote)
        }
        return named(built)
    }

    /// Each project under its repository's name; `owner/repo` for those that
    /// share a name with another listed project and have a remote to tell
    /// them apart (#971).
    static func named(_ built: [(project: QuickCaptureProject, remote: ProjectRemote?)]) -> [QuickCaptureProject] {
        var counts: [String: Int] = [:]
        for entry in built { counts[entry.project.name.caseFoldedForMatching, default: 0] += 1 }
        return built.map { entry in
            guard counts[entry.project.name.caseFoldedForMatching, default: 0] > 1, let remote = entry.remote else {
                return entry.project
            }
            return entry.project.renamed(remote.path)
        }
    }

    /// The summary kept for a remote project from the README opening its
    /// host sent (#745): the same cut as a local README's.
    package static func summary(ofRemoteReadme data: Data) -> String? {
        summary(ofReadme: String(decoding: data.prefix(maxRemoteReadmeBytes), as: UTF8.self))
            .map { clipped($0, to: maxSummaryCharacters) }
    }

    /// How much of a README a host sends: its opening is all that is read.
    package static let maxRemoteReadmeBytes = 16_384

    /// The README at a checkout's root: `README.md`, `README`, `readme.md`,
    /// `README.markdown`, the first one that reads. Capped at 64 KB, since
    /// only its opening is used.
    package static func readme(atRoot root: String, fileManager: FileManager = .default) -> String? {
        for name in ["README.md", "README", "readme.md", "README.markdown", "Readme.md"] {
            let path = (root as NSString).appendingPathComponent(name)
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            // Lenient decoding: the cut can split a multibyte character.
            guard let data = try? handle.read(upToCount: 65_536) else { continue }
            return String(decoding: data, as: UTF8.self)
        }
        return nil
    }

    /// The first `summaryParagraphs` paragraphs of prose, joined: front
    /// matter, headings, HTML, badge and image lines, block quotes, lists,
    /// tables and code blocks are skipped, and Markdown links keep their
    /// text. Nil when the README has no prose.
    package static func summary(ofReadme markdown: String) -> String? {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        {
            lines = lines[(end + 1)...]
        }
        var paragraphs: [String] = []
        var paragraph: [String] = []
        var inFence = false
        var inHTMLComment = false
        func endParagraph() {
            let text = inlineText(paragraph.joined(separator: " "))
            if !text.isEmpty { paragraphs.append(text) }
            paragraph = []
        }
        for raw in lines {
            guard paragraphs.count < summaryParagraphs else { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                endParagraph()
                continue
            }
            if inFence { continue }
            if inHTMLComment {
                if line.contains("-->") { inHTMLComment = false }
                continue
            }
            if line.hasPrefix("<!--") {
                if !line.contains("-->") { inHTMLComment = true }
                continue
            }
            if line.isEmpty || isNotProse(line) {
                endParagraph()
                continue
            }
            paragraph.append(line)
        }
        if paragraphs.count < summaryParagraphs { endParagraph() }
        let text = paragraphs.prefix(summaryParagraphs).joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private static func isNotProse(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix("<") || line.hasPrefix(">") || line.hasPrefix("|") { return true }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        if line.allSatisfy({ "=-_*".contains($0) }) { return true }
        // A bare link on its own line: an embedded video or a demo URL.
        if line.range(of: #"^<?https?://\S+>?$"#, options: .regularExpression) != nil { return true }
        // A line of nothing but images and links: badges, a logo.
        let stripped = line.replacingOccurrences(
            of: #"\[?!\[[^\]]*\]\([^)]*\)\]?(\([^)]*\))?"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty
    }

    /// Links and images become their text; emphasis, code marks, HTML tags
    /// and entities go.
    private static func inlineText(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        // A README's `&nbsp;` spacer, and any other entity, is no prose.
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: #"&(#[0-9]+|[A-Za-z]+);"#, with: " ", options: .regularExpression)
        for mark in ["**", "__", "`"] {
            result = result.replacingOccurrences(of: mark, with: "")
        }
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    package static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
