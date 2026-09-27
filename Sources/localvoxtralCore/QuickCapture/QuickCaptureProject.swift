import Foundation

/// One project a quick capture can be routed to (#725), as the classifier
/// sees it. Repository names alone route badly ("sometimes it's not
/// representative of the project"), so each goes out with a description:
/// its README's first paragraph, its own terms, and a line about it: the
/// user's, else the one its agent wrote (#891).
///
/// The projects are the learned terms' (`LearnedTerms.listedProjects`), the
/// same ones the learned-terms sheet shows. Nothing here comes from the
/// screen or the clipboard.
package struct QuickCaptureProject: Equatable, Sendable {
    /// `LearnedTermProject.key`: a main checkout's path, or `remote:<label>`.
    package let key: String
    package let name: String
    /// The README's opening paragraphs: read from a local checkout, or kept
    /// from the host's report for a remote project (#745). Nil when neither
    /// has one.
    package let summary: String?
    package let terms: [String]
    /// The project's agent's sentence about it (#891), when it answered.
    package let agentLine: String?
    /// What the user wrote about the project, when they did. It replaces
    /// the agent's sentence.
    package let userLine: String?

    package init(
        key: String, name: String, summary: String?, terms: [String],
        agentLine: String? = nil, userLine: String?
    ) {
        self.key = key
        self.name = name
        self.summary = summary
        self.terms = terms
        self.agentLine = agentLine
        self.userLine = userLine
    }

    /// The description filled in without the user: the agent's sentence,
    /// else the README summary, cut like the user's line. The Project descriptions sheet shows it
    /// until the user writes their own.
    package var automaticLine: String? {
        agentLine ?? summary.map { QuickCaptureProjects.clipped($0, to: QuickCaptureProjects.maxUserLineCharacters) }
    }

    /// The text the classifier reads for this option.
    package var description: String {
        var parts: [String] = ["Project \(name)."]
        if let line = userLine ?? agentLine { parts.append(line) }
        if let summary { parts.append(summary) }
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

    /// Every project a capture can go to (`LearnedTerms.listedProjects`),
    /// most recent first, each with its description.
    ///
    /// - Parameters:
    ///   - userLines: the user's line per project key.
    ///   - readme: the README text of a local project root, nil when none.
    package static func projects(
        from learned: LearnedTerms,
        userLines: [String: String],
        now: Date,
        readme: (String) -> String?
    ) -> [QuickCaptureProject] {
        learned.listedProjects(now: now).map { project in
            let terms = learned.confirmedTerms(projectKey: project.key)
                + learned.unconfirmedProposals(projectKey: project.key)
            let summary = project.key.hasPrefix("/")
                ? readme(project.key).flatMap(summary(ofReadme:))
                : project.summary
            return QuickCaptureProject(
                key: project.key,
                name: project.name,
                summary: summary.map { clipped($0, to: maxSummaryCharacters) },
                terms: Array(terms.prefix(maxTerms)),
                agentLine: project.agentLine,
                userLine: userLines[project.key]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : clipped($0, to: maxUserLineCharacters) }
            )
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
