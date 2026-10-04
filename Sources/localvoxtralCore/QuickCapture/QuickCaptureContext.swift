import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What the first draft reads about a project (#918): the README's opening,
/// the repository guide's rules for issues, `git grep` hits for the
/// capture's words, and the tracker (open issues, recent closed issues and
/// merged pull requests). About 7,500 tokens on this repository.
///
/// Gathered by the app in a local checkout, or by a remote project's host
/// and posted back as a bundle (`bundle`, `parse(bundle:)`). Every field is
/// untrusted text repo contents can steer: it is capped here and only ever
/// quoted into the prompt.
package struct QuickCaptureContext: Equatable, Sendable {
    /// An issue or pull request by number and title.
    package struct Reference: Equatable, Sendable {
        package let number: Int
        package let title: String

        package init(number: Int, title: String) {
            self.number = number
            self.title = title
        }
    }

    package var readme: String?
    package var issueRules: String?
    /// `path:line:text`, one hit per entry.
    package var codeHits: [String]
    /// Nil when `gh` could not list them; the prompt says so.
    package var openIssues: [QuickCaptureDraft.OpenIssue]?
    package var closedIssues: [Reference]?
    package var mergedPullRequests: [Reference]?

    package init(
        readme: String? = nil,
        issueRules: String? = nil,
        codeHits: [String] = [],
        openIssues: [QuickCaptureDraft.OpenIssue]? = nil,
        closedIssues: [Reference]? = nil,
        mergedPullRequests: [Reference]? = nil
    ) {
        self.readme = readme
        self.issueRules = issueRules
        self.codeHits = codeHits
        self.openIssues = openIssues
        self.closedIssues = closedIssues
        self.mergedPullRequests = mergedPullRequests
    }

    // MARK: Caps

    package static let maxReadmeCharacters = 3_000
    package static let maxRulesCharacters = 6_000
    /// How much of a guide is read to find its rules.
    package static let maxGuideBytes = 65_536
    package static let maxSearchWords = 8
    package static let hitsPerWord = 4
    package static let maxHitCharacters = 160
    package static let maxClosedIssues = 40
    package static let maxMergedPullRequests = 20

    // MARK: Words

    /// Words a search skips: too common to find anything.
    private static let stopwords: Set<String> = [
        "about", "actually", "after", "again", "also", "because", "before", "being", "could", "does", "doing",
        "doesn", "don't", "each", "even", "every", "from", "going", "have", "having", "here", "into", "just",
        "know", "like", "make", "maybe", "more", "much", "need", "needs", "only", "other", "really", "should",
        "some", "something", "still", "that", "their", "them", "then", "there", "these", "they", "thing",
        "things", "think", "this", "those", "through", "today", "tomorrow", "very", "want", "wants", "well",
        "were", "what", "when", "where", "which", "while", "will", "with", "without", "would", "your", "yeah",
        "okay", "check", "look", "please", "able", "sure", "kind", "sort", "stuff", "right", "work", "works",
    ]

    /// The capture's words worth a `git grep`: letters, digits, `_`, `-`
    /// and `.`, four characters or more, not a stopword, longest first,
    /// `maxSearchWords` at most. A plural loses its `s`, since a search is
    /// by substring. Each word starts with a letter or digit, so it can never
    /// read as an option.
    package static func searchWords(in capture: String) -> [String] {
        var seen: Set<String> = []
        var words: [String] = []
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        for raw in capture.components(separatedBy: allowed.inverted) {
            var word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-._")).lowercased()
            guard word.count >= 4, word.count <= 40, word.unicodeScalars.allSatisfy(\.isASCII),
                  !stopwords.contains(word)
            else { continue }
            if word.count > 5, word.hasSuffix("s"), !word.hasSuffix("ss") { word.removeLast() }
            if seen.insert(word).inserted { words.append(word) }
        }
        return Array(words.enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .prefix(maxSearchWords)
            .map(\.element))
    }

    /// A search word as the host may run it: what `searchWords` makes.
    package static func isSearchWord(_ word: String) -> Bool {
        word.range(of: #"^[a-z0-9][a-z0-9_.-]{1,39}$"#, options: .regularExpression) != nil
    }

    // MARK: Guide

    /// The guide's sections about issues, proof, tests and pull requests
    /// (`##` or deeper headings that name them), capped; the guide's opening
    /// when no heading does.
    package static func issueRules(ofGuide markdown: String) -> String? {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var sections: [String] = []
        var current: [String]?
        let pattern = #"(?i)\b(issues?|proof|tests?|testing|pull requests?|PRs?|review|contribut\w*)\b"#
        var inFence = false
        for line in lines {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, line.hasPrefix("## ") || line.hasPrefix("### ") {
                if let current { sections.append(current.joined(separator: "\n")) }
                current = line.range(of: pattern, options: .regularExpression) != nil ? [line] : nil
                continue
            }
            if !inFence, line.hasPrefix("# ") {
                if let current { sections.append(current.joined(separator: "\n")) }
                current = nil
                continue
            }
            current?.append(line)
        }
        if let current { sections.append(current.joined(separator: "\n")) }
        let text = sections.isEmpty
            ? markdown
            : sections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : clipped(trimmed, to: maxRulesCharacters)
    }

    /// `AGENTS.md`, else `CLAUDE.md`, at a checkout's root. A CLAUDE.md
    /// that only imports AGENTS.md (`@AGENTS.md`) is AGENTS.md.
    package static let guideNames = ["AGENTS.md", "CLAUDE.md"]

    // MARK: Search hits

    /// `git grep -n -I -i -F --max-count 2 -e <word>` output, cut to
    /// `hitsPerWord` lines of `maxHitCharacters`.
    package static func hits(fromGrep data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .prefix(hitsPerWord)
            .map { QuickCaptureDraft.oneLine(String($0), limit: maxHitCharacters) }
    }

    package static func grepArguments(word: String) -> [String] {
        ["grep", "-n", "-I", "-i", "-F", "--max-count", "2", "-e", word, "--"]
    }

    // MARK: Tracker

    /// In `repository`, the one captures are filed in (#919): in a fork,
    /// gh's own pick is the upstream.
    package static func ghClosedIssuesArguments(repository: String) -> [String] {
        ["issue", "list", "--repo", repository, "--state", "closed", "--limit", String(maxClosedIssues), "--json", "number,title"]
    }

    package static func ghMergedPullRequestsArguments(repository: String) -> [String] {
        ["pr", "list", "--repo", repository, "--state", "merged", "--limit", String(maxMergedPullRequests), "--json", "number,title"]
    }

    /// `gh … --json number,title`; nil when it is not that.
    package static func parseReferences(_ data: Data, limit: Int) -> [Reference]? {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return Array(items.compactMap { item -> Reference? in
            guard let number = item["number"] as? Int, let title = item["title"] as? String else { return nil }
            return Reference(number: number, title: QuickCaptureDraft.oneLine(title, limit: 200))
        }.prefix(limit))
    }

    // MARK: Remote bundle

    /// A host's bundle: sections, each opened by a line `@@lvx <name>`.
    /// `readme` and `guide` are the files' openings, `grep` the hits as
    /// `git grep` prints them, `open`, `closed` and `merged` gh's JSON.
    /// A marker line inside a file only moves text between sections, all
    /// of them quoted alike.
    package static let bundleMarker = "@@lvx "
    package static let maxBundleBytes = 96 * 1024

    package static func parse(bundle data: Data) -> QuickCaptureContext {
        var sections: [String: [Substring]] = [:]
        var name: String?
        let text = String(decoding: data.prefix(maxBundleBytes), as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(bundleMarker) {
                name = String(line.dropFirst(bundleMarker.count)).trimmingCharacters(in: .whitespaces)
                if sections[name!] == nil { sections[name!] = [] }
                continue
            }
            if let name { sections[name]?.append(line) }
        }
        func section(_ key: String) -> String? {
            sections[key].map { $0.joined(separator: "\n") }
        }
        func json(_ key: String) -> Data? {
            section(key).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Data($0.utf8) }
        }
        return QuickCaptureContext(
            readme: section("readme").flatMap(readmeOpening),
            issueRules: section("guide").flatMap(issueRules(ofGuide:)),
            codeHits: section("grep").map { grep in
                Array(grep.split(whereSeparator: \.isNewline)
                    .prefix(maxSearchWords * hitsPerWord)
                    .map { QuickCaptureDraft.oneLine(String($0), limit: maxHitCharacters) })
            } ?? [],
            openIssues: json("open").flatMap(QuickCaptureDraft.parseIssueList)
                .map { Array($0.prefix(QuickCaptureDraft.maxListedIssues)) },
            closedIssues: json("closed").flatMap { parseReferences($0, limit: maxClosedIssues) },
            mergedPullRequests: json("merged").flatMap { parseReferences($0, limit: maxMergedPullRequests) }
        )
    }

    /// A README's first `maxReadmeCharacters`, as Markdown.
    package static func readmeOpening(_ markdown: String) -> String? {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : clipped(trimmed, to: maxReadmeCharacters)
    }

    static func clipped(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

/// Gathers a local checkout's context: files read directly, `git grep` and
/// `gh` through `BoundedProcess`, each bounded and allowed to fail alone.
package struct QuickCaptureContextGatherer: Sendable {
    /// Runs a tool in the checkout; nil when it failed, timed out or was
    /// capped. The seam tests replace.
    package typealias Run = @Sendable (_ tool: Tool, _ arguments: [String], _ root: String) async -> Data?

    package enum Tool: Sendable {
        case git
        case gh
    }

    private let run: Run
    private let openIssues: @Sendable (String, String?) async -> [QuickCaptureDraft.OpenIssue]?
    /// A checkout's GitHub repository (`QuickCaptureFiling`'s pick) when the
    /// project names none.
    private let checkoutRepository: @Sendable (String) async -> String?
    private let readFile: @Sendable (String, Int) -> String?

    package init(
        run: @escaping Run,
        openIssues: @escaping @Sendable (String, String?) async -> [QuickCaptureDraft.OpenIssue]?,
        checkoutRepository: @escaping @Sendable (String) async -> String?,
        readFile: @escaping @Sendable (String, Int) -> String? = QuickCaptureContextGatherer.readPrefix
    ) {
        self.run = run
        self.openIssues = openIssues
        self.checkoutRepository = checkoutRepository
        self.readFile = readFile
    }

    /// - Parameter repository: the repository captures are filed in, when
    ///   the project names one. Without one, nor a GitHub checkout, the
    ///   tracker is not listed.
    package func gather(root: String, repository: String?, capture: String) async -> QuickCaptureContext {
        var resolved = repository.flatMap { QuickCaptureInbox.isRepository($0) ? $0 : nil }
        if resolved == nil { resolved = await checkoutRepository(root) }
        let tracker = resolved
        let run = run
        func list(_ arguments: @escaping @Sendable (String) -> [String]) async -> Data? {
            guard let tracker else { return nil }
            return await run(.gh, arguments(tracker), root)
        }
        async let open = openIssues(root, tracker)
        async let closed = list(QuickCaptureContext.ghClosedIssuesArguments(repository:))
        async let merged = list(QuickCaptureContext.ghMergedPullRequestsArguments(repository:))
        var hits: [String] = []
        for word in QuickCaptureContext.searchWords(in: capture) {
            if let data = await run(.git, QuickCaptureContext.grepArguments(word: word), root) {
                hits += QuickCaptureContext.hits(fromGrep: data)
            }
        }
        let readme = QuickCaptureProjects.readme(atRoot: root).flatMap(QuickCaptureContext.readmeOpening)
        var rules: String?
        for name in QuickCaptureContext.guideNames {
            let path = (root as NSString).appendingPathComponent(name)
            guard let text = readFile(path, QuickCaptureContext.maxGuideBytes) else { continue }
            // Claude Code's `@AGENTS.md` import: the file it names was read first.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@"), text.count < 200 { continue }
            rules = QuickCaptureContext.issueRules(ofGuide: text)
            break
        }
        return await QuickCaptureContext(
            readme: readme,
            issueRules: rules,
            codeHits: hits,
            openIssues: open,
            closedIssues: closed.flatMap { QuickCaptureContext.parseReferences($0, limit: QuickCaptureContext.maxClosedIssues) },
            mergedPullRequests: merged.flatMap {
                QuickCaptureContext.parseReferences($0, limit: QuickCaptureContext.maxMergedPullRequests)
            }
        )
    }

    /// The first `maxBytes` of a file, leniently decoded. Nil unless the path
    /// names a regular file: a repository's `README.md -> ~/.ssh/config` must
    /// not reach the model (#1271). `O_NOFOLLOW` and the `fstat` on the open
    /// descriptor keep the check and the read on the same file.
    package static let readPrefix: @Sendable (String, Int) -> String? = { path, maxBytes in
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `git` and `gh` as the app's user: `gh` found as the Inbox finds it,
    /// `git` on PATH or in `/usr/bin`. 20 s each.
    ///
    /// A command that fails leaves its part of the context out, and says so
    /// through `logFailure` (#1692): the tool, its first argument and the
    /// outcome, never the rest of its arguments or its output.
    package static func processRun(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        logFailure: @escaping @Sendable (String) -> Void = { Log.backends.notice("\($0, privacy: .public)") }
    ) -> Run {
        { tool, arguments, root in
            let name = tool == .gh ? "gh" : "git"
            // `issue`, `pr`, `grep`: what was asked, without the search words.
            let command = ([name] + arguments.prefix(1)).joined(separator: " ")
            let left = "Quick capture context: `\(command)`"
            let candidates: [String]
            switch tool {
            case .gh:
                candidates = QuickCaptureDrafter.ghCandidates(environment: environment)
            case .git:
                candidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/git" } + ["/usr/bin/git"]
            }
            guard let executable = candidates.first(where: isExecutable) else {
                logFailure("\(left) not run, \(name) not found; that context is left out")
                return nil
            }
            guard let output = await BoundedProcess.run(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments,
                environment: environment,
                currentDirectory: root,
                timeoutSeconds: 20,
                maxBytes: 1_000_000,
                label: "quick capture context \(name)"
            ) else {
                logFailure("\(left) did not start; that context is left out")
                return nil
            }
            guard !output.timedOut else {
                logFailure("\(left) timed out; that context is left out")
                return nil
            }
            // git grep exits 1 when nothing matched; it printed nothing then.
            guard output.exitCode == 0 || (tool == .git && output.exitCode == 1) else {
                logFailure("\(left) exited \(output.exitCode); that context is left out")
                return nil
            }
            // A capped grep still has its first lines, which are all that is read.
            if output.capped, tool == .gh {
                logFailure("\(left) output over the cap; that context is left out")
                return nil
            }
            return output.data
        }
    }
}
