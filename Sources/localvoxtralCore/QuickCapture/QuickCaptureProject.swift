import Foundation

/// One project a quick capture can be routed to (#725), as the classifier
/// sees it. Repository names alone route badly ("sometimes it's not
/// representative of the project"), so each goes out with a description:
/// its README's first paragraph, its own terms, and a line the user wrote.
///
/// The projects are the ones the learned-terms file holds, which is every
/// project a joined dictation has shown the app (#609 stamps each one).
/// Nothing here comes from the screen or the clipboard.
package struct QuickCaptureProject: Equatable, Sendable {
    /// `LearnedTermProject.key`: a main checkout's path, or `remote:<label>`.
    package let key: String
    package let name: String
    /// The README's first paragraph. Nil for a remote project, whose files
    /// are on another machine, and for a checkout without one.
    package let summary: String?
    package let terms: [String]
    /// What the user wrote about the project, when they did.
    package let userLine: String?

    package init(key: String, name: String, summary: String?, terms: [String], userLine: String?) {
        self.key = key
        self.name = name
        self.summary = summary
        self.terms = terms
        self.userLine = userLine
    }

    /// The text the classifier reads for this option.
    package var description: String {
        var parts: [String] = ["Project \(name)."]
        if let userLine { parts.append(userLine) }
        if let summary { parts.append(summary) }
        if !terms.isEmpty { parts.append("Its names: " + terms.joined(separator: ", ") + ".") }
        return parts.joined(separator: " ")
    }
}

package enum QuickCaptureProjects {
    package static let maxTerms = 30
    package static let maxSummaryCharacters = 500
    package static let maxUserLineCharacters = 200

    /// Every project in `learned`, most recently dictated first.
    ///
    /// - Parameters:
    ///   - userLines: the user's line per project key.
    ///   - readme: the README text of a local project root, nil when none.
    package static func projects(
        from learned: LearnedTerms,
        userLines: [String: String],
        readme: (String) -> String?
    ) -> [QuickCaptureProject] {
        learned.projects
            .filter { !$0.key.isEmpty && !$0.name.isEmpty }
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { project in
                let terms = learned.confirmedTerms(projectKey: project.key)
                    + learned.unconfirmedProposals(projectKey: project.key)
                let summary = project.key.hasPrefix("/")
                    ? readme(project.key).flatMap(firstParagraph(ofReadme:))
                    : nil
                return QuickCaptureProject(
                    key: project.key,
                    name: project.name,
                    summary: summary.map { clipped($0, to: maxSummaryCharacters) },
                    terms: Array(terms.prefix(maxTerms)),
                    userLine: userLines[project.key]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .flatMap { $0.isEmpty ? nil : clipped($0, to: maxUserLineCharacters) }
                )
            }
    }

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

    /// The first paragraph of prose: front matter, headings, HTML, badge and
    /// image lines, block quotes, lists, tables and code blocks are skipped,
    /// and Markdown links keep their text. Nil when the README has no prose.
    package static func firstParagraph(ofReadme markdown: String) -> String? {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        {
            lines = lines[(end + 1)...]
        }
        var paragraph: [String] = []
        var inFence = false
        var inHTMLComment = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                if !paragraph.isEmpty { break }
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
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(line)
        }
        let text = inlineText(paragraph.joined(separator: " "))
        return text.isEmpty ? nil : text
    }

    private static func isNotProse(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix("<") || line.hasPrefix(">") || line.hasPrefix("|") { return true }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        if line.allSatisfy({ "=-_*".contains($0) }) { return true }
        // A line of nothing but images and links: badges, a logo.
        let stripped = line.replacingOccurrences(
            of: #"\[?!\[[^\]]*\]\([^)]*\)\]?(\([^)]*\))?"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty
    }

    /// Links and images become their text; emphasis and code marks go.
    private static func inlineText(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for mark in ["**", "__", "`"] {
            result = result.replacingOccurrences(of: mark, with: "")
        }
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
