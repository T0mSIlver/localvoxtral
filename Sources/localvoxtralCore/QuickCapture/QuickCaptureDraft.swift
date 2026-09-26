import Foundation

/// Once a quick capture has a project (#725), the app runs that project's
/// coding agent headless in its checkout to turn the spoken idea into an
/// issue draft (#731): title, scope, constraints, proof, the repo's own
/// AGENTS.md conventions, and a word on any open issue it duplicates or
/// extends. The draft only ever lands in the Inbox; nothing here files.
///
/// The run is #609's shape (`ProjectTermProposal`): the agent's CLI, its
/// read-only tools and no others, no hooks, turn and cost caps, a timeout
/// and an output cap. The open issues come from the app's own
/// `gh issue list`, written into the prompt, so the agent needs no shell
/// and no `gh` of its own.
package enum QuickCaptureDraft {
    package static let timeoutSeconds: TimeInterval = 240
    package static let maxOutputBytes = 8_000_000
    package static let maxTurns = 20
    package static let claudeBudgetUSD = "0.50"
    package static let vibeMaxPriceUSD = "0.30"
    /// Open issues listed in the prompt, newest first, each with its body cut.
    package static let maxListedIssues = 60
    package static let maxIssueExcerptCharacters = 240
    package static let maxTitleCharacters = 120
    package static let maxBodyCharacters = 12_000

    // MARK: Open issues

    package struct OpenIssue: Equatable, Sendable {
        package let number: Int
        package let title: String
        package let body: String

        package init(number: Int, title: String, body: String) {
            self.number = number
            self.title = title
            self.body = body
        }
    }

    package static let ghIssueListArguments = [
        "issue", "list", "--state", "open", "--limit", String(maxListedIssues), "--json", "number,title,body",
    ]

    /// `gh issue list --json number,title,body`; nil when it is not that.
    package static func parseIssueList(_ data: Data) -> [OpenIssue]? {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let number = item["number"] as? Int, let title = item["title"] as? String else { return nil }
            return OpenIssue(number: number, title: title, body: item["body"] as? String ?? "")
        }
    }

    // MARK: Prompt

    /// - Parameter issues: nil when `gh` could not list them; the prompt
    ///   says so instead of implying there are none.
    package static func prompt(capture: String, projectName: String, issues: [OpenIssue]?) -> String {
        var text = """
            The owner of \(projectName) dictated this idea while doing something else. \
            It is a quick brain dump, not an issue yet, and speech recognition may have \
            misheard a few words:

            <capture>
            \(capture)
            </capture>

            Turn it into a GitHub issue for this repository. Read AGENTS.md or CLAUDE.md \
            first if the repository has one, and follow its conventions for issues. Read \
            the code the idea touches, at most ten files. Write a short title, then a body \
            with the scope, the constraints and the proof its pull request must carry. \
            Keep the owner's intent; do not add features they did not ask for. If an open \
            issue below already covers the idea, name it as a duplicate; if the idea adds \
            to one, name it as extended.

            Reply with JSON only: {"title": "...", "body": "...", "relation": \
            "none" | "duplicate" | "extends", "issue": <number or null>}
            """
        text += "\n\nOpen issues:\n"
        if let issues {
            if issues.isEmpty { text += "(none)\n" }
            for issue in issues.prefix(maxListedIssues) {
                let excerpt = oneLine(issue.body, limit: maxIssueExcerptCharacters)
                text += "#\(issue.number) \(oneLine(issue.title, limit: 200))" + (excerpt.isEmpty ? "" : ": \(excerpt)") + "\n"
            }
        } else {
            text += "(could not be listed; do not claim a duplicate)\n"
        }
        return text
    }

    package static let claudeSystemPrompt =
        "You draft GitHub issues from a developer's dictated ideas. You cannot file anything. Reply only with the requested JSON."

    package static let claudeJSONSchema =
        #"{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"},"relation":{"type":"string","enum":["none","duplicate","extends"]},"issue":{"type":["integer","null"]}},"required":["title","body","relation","issue"],"additionalProperties":false}"#

    /// Read, Glob and Grep only, as #609: no Bash, so no `gh` that could
    /// file; no MCP; no hooks.
    package static func claudeArguments(prompt: String) -> [String] {
        [
            "-p", prompt,
            "--model", "sonnet",
            "--system-prompt", claudeSystemPrompt,
            "--tools", "Read,Glob,Grep",
            "--settings", #"{"disableAllHooks":true}"#,
            "--strict-mcp-config",
            "--no-session-persistence",
            "--max-turns", String(maxTurns),
            "--max-budget-usd", claudeBudgetUSD,
            "--output-format", "json",
            "--json-schema", claudeJSONSchema,
        ]
    }

    /// The read-only tools #609 measured, and the tracked-file list its
    /// probe showed Vibe needs once bash is refused.
    package static func vibeArguments(prompt: String, trackedFiles: [String]) -> [String] {
        let files = trackedFiles.prefix(ProjectTermProposal.maxListedFiles)
        let fullPrompt = files.isEmpty
            ? prompt
            : prompt + "\n\nTracked files (read_file takes these paths):\n" + files.joined(separator: "\n")
        return [
            "--experimental-harness",
            "--auto-approve",
            "-p", fullPrompt,
            "--enabled-tools", #"re:^(read_file|grep|file_system[.](read_file|grep|glob|list_dir))$"#,
            "--max-turns", String(maxTurns),
            "--max-price", vibeMaxPriceUSD,
            "--output", "json",
        ]
    }

    package static func invocation(
        agent: ProjectTermProposal.Agent,
        workingDirectory: String,
        prompt: String,
        trackedFiles: [String]
    ) -> ProjectTermProposal.Invocation {
        ProjectTermProposal.Invocation(
            agent: agent,
            workingDirectory: workingDirectory,
            arguments: agent == .claude
                ? claudeArguments(prompt: prompt)
                : vibeArguments(prompt: prompt, trackedFiles: trackedFiles)
        )
    }

    // MARK: Answer

    package struct Draft: Codable, Equatable, Sendable {
        package enum Relation: String, Codable, Equatable, Sendable {
            case none
            case duplicate
            case extends
        }

        package let title: String
        package let body: String
        package let relation: Relation
        /// The open issue `relation` names; nil for `.none`.
        package let issue: Int?

        package init(title: String, body: String, relation: Relation, issue: Int?) {
            self.title = title
            self.body = body
            self.relation = relation
            self.issue = issue
        }
    }

    /// Why no agent ran. The capture waits in the Inbox with the user's
    /// words either way.
    package enum NotRun: String, Codable, Equatable, Sendable {
        /// The catch-all has no repository to read.
        case catchAll
        /// The checkout is on another machine; a remote label never becomes
        /// a working directory on this Mac (docs/agent/invariants.md).
        case remoteProject
        case checkoutMissing
    }

    package enum Outcome: Equatable, Sendable {
        case draft(Draft, usage: ProjectTermProposal.Usage?)
        case failed(ProjectTermProposal.Failure)
        case notRun(NotRun)
    }

    /// `claude -p --output-format json` with `--json-schema`. The failure
    /// subtypes read as #609's.
    package static func parseClaude(stdout: Data, exitCode: Int32, openIssues: [Int]) -> Outcome {
        guard let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            return .failed(exitCode == 0 ? .malformedOutput : .exit(exitCode))
        }
        if object["is_error"] as? Bool == true || exitCode != 0 {
            switch object["subtype"] as? String {
            case "error_max_budget_usd": return .failed(.budgetExceeded)
            case "error_max_turns": return .failed(.turnLimit)
            case let subtype?: return .failed(.agentError(subtype))
            case nil: return .failed(exitCode == 0 ? .agentError("unknown") : .exit(exitCode))
            }
        }
        let usage = object["usage"] as? [String: Any] ?? [:]
        let runUsage = ProjectTermProposal.Usage(
            turns: object["num_turns"] as? Int,
            costUSD: object["total_cost_usd"] as? Double,
            inputTokens: usage["input_tokens"] as? Int,
            cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int,
            outputTokens: usage["output_tokens"] as? Int
        )
        let answer = (object["structured_output"] as? [String: Any])
            ?? (object["result"] as? String).flatMap(jsonObject(in:))
        guard let answer, let draft = draft(from: answer, openIssues: openIssues) else {
            return .failed(.malformedOutput)
        }
        return .draft(draft, usage: runUsage)
    }

    /// `vibe -p --output json`: the last assistant message's text, as
    /// #609 reads it; tool calls after it mean the turn limit.
    package static func parseVibe(stdout: Data, exitCode: Int32, openIssues: [Int]) -> Outcome {
        guard exitCode == 0 else { return .failed(.exit(exitCode)) }
        guard let entries = try? JSONSerialization.jsonObject(with: stdout) as? [[String: Any]] else {
            return .failed(.malformedOutput)
        }
        guard let lastIndex = entries.lastIndex(where: {
            $0["type"] as? String == "message" && $0["role"] as? String == "assistant"
        }) else {
            return .failed(entries.contains { $0["type"] as? String == "effect" } ? .turnLimit : .malformedOutput)
        }
        if entries[(lastIndex + 1)...].contains(where: { $0["type"] as? String == "effect" }) {
            return .failed(.turnLimit)
        }
        let parts = entries[lastIndex]["content"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard let answer = jsonObject(in: text), let draft = draft(from: answer, openIssues: openIssues) else {
            return .failed(.malformedOutput)
        }
        return .draft(draft, usage: nil)
    }

    /// The answer is untrusted text repo contents can steer. The title is
    /// one line; both fields lose control characters and are capped; a
    /// related issue counts only when it is one of the open issues listed.
    static func draft(from answer: [String: Any], openIssues: [Int]) -> Draft? {
        guard let rawTitle = answer["title"] as? String, let rawBody = answer["body"] as? String else { return nil }
        let title = oneLine(rawTitle, limit: maxTitleCharacters)
        let body = String(
            String.UnicodeScalarView(rawBody.unicodeScalars.filter {
                $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control
            })
            .prefix(maxBodyCharacters)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else { return nil }
        var relation = (answer["relation"] as? String).flatMap(Draft.Relation.init(rawValue:)) ?? .none
        var issue = (answer["issue"] as? NSNumber)?.intValue
        if relation == .none || issue.map({ !openIssues.contains($0) }) ?? true {
            relation = .none
            issue = nil
        }
        return Draft(title: title, body: body, relation: relation, issue: issue)
    }

    /// `{…}` bare, fenced, or after prose.
    static func jsonObject(in text: String) -> [String: Any]? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let data = String(text[open...close]).data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = String(String.UnicodeScalarView(text.unicodeScalars.map {
            $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}" ? " " : $0
        }))
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
