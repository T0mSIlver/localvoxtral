import ClaudeContextWire
import Foundation

/// The first time a joined local Claude Code, Vibe or opencode session shows
/// the app a project, the app runs that agent headless in the project,
/// read-only, and asks it for the project's own names (#609, #642). The answer lands in the
/// learned terms as unconfirmed proposals (`LearnedTerms.recordProposal`).
///
/// This is the pure half: which join asks, the exact command line, the
/// prompt, and reading the answer. `ProjectTermProposalProcessRunner` runs
/// the command and `ProjectTermProposer` decides when.
package enum ProjectTermProposal {
    /// The agents that can propose. A Codex proposer is a follow-up to #716.
    package enum Agent: String, Sendable, Equatable, CaseIterable {
        case claude
        case vibe
        case opencode

        package init?(_ agent: ClaudeHookAgent) {
            switch agent {
            case .claude: self = .claude
            case .vibe: self = .vibe
            case .opencode: self = .opencode
            case .codex: return nil
            }
        }

        /// What `LearnedTerm.sources` records for a term this agent proposed.
        package var source: String { LearnedTerm.agentSourcePrefix + rawValue }

        package var displayName: String {
            switch self {
            case .claude: "Claude Code"
            case .vibe: "Mistral Vibe"
            case .opencode: "opencode"
            }
        }

        package var executableName: String {
            switch self {
            case .claude: "claude"
            case .vibe: "vibe"
            case .opencode: "opencode"
            }
        }
    }

    /// An answer holds at most this many terms; more are cut, never an error.
    package static let maxTerms = 40
    /// The whole run, from launch to exit. The measured runs took 5 to 26 s.
    package static let timeoutSeconds: TimeInterval = 120
    /// The answer is a few kilobytes. Vibe's `--output json` carries every
    /// tool call, file contents included, so the cap is generous.
    package static let maxOutputBytes = 8_000_000
    /// A failed run is tried again on the next joined dictation this long
    /// after it.
    package static let retryAfter: TimeInterval = 24 * 3600
    /// Vibe has no directory listing without bash, so its prompt names the
    /// tracked files. Capped so a monorepo's list does not become the cost.
    package static let maxListedFiles = 200

    // MARK: Trigger

    /// What a joined dictation asks for: the agent and the session's
    /// directory on this Mac.
    package struct Request: Equatable, Sendable {
        package let agent: Agent
        package let workspace: LocalWorkspacePath

        package init(agent: Agent, workspace: LocalWorkspacePath) {
            self.agent = agent
            self.workspace = workspace
        }
    }

    /// Nil unless the join is a locally authenticated session with a local
    /// directory. A remote label can never become the
    /// run's working directory: `localWorkspacePath` is nil for any session
    /// that is not local (#641 covers remote hosts).
    package static func request(for snapshot: ClaudeSessionSnapshot?) -> Request? {
        guard let snapshot,
              let agent = Agent(snapshot.agent),
              let workspace = snapshot.localWorkspacePath
        else { return nil }
        return Request(agent: agent, workspace: workspace)
    }

    // MARK: Command line

    /// One run: the agent, the directory it runs in, its arguments (without
    /// the executable), and the variables it sets on top of the app's
    /// environment.
    package struct Invocation: Equatable, Sendable {
        package let agent: Agent
        package let workingDirectory: String
        package let arguments: [String]
        package let environment: [String: String]

        package init(
            agent: Agent,
            workingDirectory: String,
            arguments: [String],
            environment: [String: String] = [:]
        ) {
            self.agent = agent
            self.workingDirectory = workingDirectory
            self.arguments = arguments
            self.environment = environment
        }
    }

    package static let prompt = """
        List the names someone dictating about this project would say that a \
        speech recognizer is likely to misspell: this project's own modules, \
        types, functions, files, commands, flags, environment variables and \
        product names. Leave out common English words and well-known names. \
        Read at most six files. Spell each name exactly as the code does. \
        Reply with JSON only: {"terms": [...]}, at most \(maxTerms) terms.
        """

    /// Replaces Claude Code's default system prompt, which costs a third more
    /// tokens and asks nothing this run needs (#609 spec measurements).
    package static let claudeSystemPrompt =
        "You list a code project's own vocabulary for a dictation app. Reply only with the requested JSON."

    package static let claudeJSONSchema =
        #"{"type":"object","properties":{"terms":{"type":"array","items":{"type":"string"},"maxItems":40}},"required":["terms"],"additionalProperties":false}"#

    /// Read, Glob and Grep only: no Bash, no MCP, no hooks. `disableAllHooks`
    /// is what keeps a project's `SessionStart` hook, and our own plugin's,
    /// from firing inside the run (`--bare` would too, but it never reads a
    /// Claude.ai login).
    package static func claudeArguments() -> [String] {
        [
            "-p", prompt,
            "--model", "sonnet",
            "--system-prompt", claudeSystemPrompt,
            "--tools", "Read,Glob,Grep",
            "--settings", #"{"disableAllHooks":true}"#,
            "--strict-mcp-config",
            "--no-session-persistence",
            "--max-turns", "12",
            "--max-budget-usd", "0.50",
            "--output-format", "json",
            "--json-schema", claudeJSONSchema,
        ]
    }

    /// The tools are the read-only ones of both harnesses; `--auto-approve`
    /// is what lets them run headless, and the list still refuses `bash`.
    /// `--experimental-harness` because the legacy one looped to the turn
    /// limit on this prompt. Hooks are kept out by the app-owned `VIBE_HOME`
    /// the runner sets, and the project's own `.vibe/hooks.toml` by never
    /// passing `--trust`.
    package static func vibeArguments(trackedFiles: [String]) -> [String] {
        [
            "--experimental-harness",
            "--auto-approve",
            "-p", vibePrompt(trackedFiles: trackedFiles),
            "--enabled-tools", #"re:^(read_file|grep|file_system[.](read_file|grep|glob|list_dir))$"#,
            "--max-turns", "12",
            "--max-price", "0.30",
            "--output", "json",
        ]
    }

    /// Vibe's unified harness has no listing tool once bash is refused, so
    /// without the list it guesses file names until the turn limit (probe,
    /// 2026-09-26).
    package static func vibePrompt(trackedFiles: [String]) -> String {
        let files = trackedFiles.prefix(maxListedFiles)
        guard !files.isEmpty else { return prompt }
        return prompt + "\n\nTracked files (read_file takes these paths):\n" + files.joined(separator: "\n")
    }

    /// The agent opencode runs as, defined for this run only by
    /// `opencodeConfig`.
    package static let opencodeAgentName = "localvoxtral-terms"

    /// `--pure` skips external plugins, ours included: without it our plugin
    /// loads into the run and publishes a phantom session (probe,
    /// 2026-09-26, opencode 1.18.31). `--dir` and the working directory are
    /// the same project. No `--model`: the run uses the user's own default,
    /// as Vibe's does.
    package static func opencodeArguments(workingDirectory: String) -> [String] {
        [
            "run",
            "--pure",
            "--format", "json",
            "--dir", workingDirectory,
            "--agent", opencodeAgentName,
            prompt,
        ]
    }

    /// What every opencode tool gets: read, glob, grep and list are allowed,
    /// everything else (bash, edit, webfetch, task, MCP tools, a directory
    /// outside the project) is denied. Denied tools are not offered to the
    /// model at all, even when the user's own config allows them (probe,
    /// 2026-09-26).
    private static let opencodePermission: [String: String] = [
        "*": "deny",
        "read": "allow",
        "glob": "allow",
        "grep": "allow",
        "list": "allow",
        "bash": "deny",
        "edit": "deny",
        "task": "deny",
        "webfetch": "deny",
        "websearch": "deny",
        "external_directory": "deny",
        "skill": "deny",
    ]

    /// The run's own agent and permissions, passed as
    /// `OPENCODE_CONFIG_CONTENT`, which opencode merges last. `steps` caps
    /// the tool turns; at the cap opencode forces a text-only answer.
    package static var opencodeConfig: String {
        let config: [String: Any] = [
            "permission": opencodePermission,
            "agent": [
                opencodeAgentName: [
                    "mode": "primary",
                    "steps": 12,
                    "prompt": claudeSystemPrompt,
                    "permission": opencodePermission,
                ] as [String: Any],
            ],
            "share": "disabled",
            "autoupdate": false,
            "snapshot": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// opencode has no price cap, so the run is bounded by 12 steps, 4096
    /// output tokens per step and `timeoutSeconds`. The rest keeps the run
    /// out of everything the user owns: an in-memory database, so the run
    /// never shows in their session list; no project config, so the repo's
    /// `opencode.json` starts no MCP server and changes no permission; no
    /// Claude Code or external skills; no update or LSP download.
    package static let opencodeEnvironment: [String: String] = [
        "OPENCODE_CONFIG_CONTENT": opencodeConfig,
        "OPENCODE_DB": ":memory:",
        "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
        "OPENCODE_DISABLE_CLAUDE_CODE": "1",
        "OPENCODE_DISABLE_EXTERNAL_SKILLS": "1",
        "OPENCODE_DISABLE_AUTOUPDATE": "1",
        "OPENCODE_DISABLE_LSP_DOWNLOAD": "1",
        "OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX": "4096",
    ]

    package static func invocation(
        agent: Agent,
        workingDirectory: String,
        trackedFiles: [String]
    ) -> Invocation {
        switch agent {
        case .claude:
            Invocation(agent: agent, workingDirectory: workingDirectory, arguments: claudeArguments())
        case .vibe:
            Invocation(
                agent: agent, workingDirectory: workingDirectory,
                arguments: vibeArguments(trackedFiles: trackedFiles)
            )
        case .opencode:
            Invocation(
                agent: agent, workingDirectory: workingDirectory,
                arguments: opencodeArguments(workingDirectory: workingDirectory),
                environment: opencodeEnvironment
            )
        }
    }

    // MARK: Answer

    package enum Failure: Equatable, Sendable {
        case agentNotFound
        case launchFailed
        case timedOut
        case outputTooLarge
        case exit(Int32)
        case budgetExceeded
        case turnLimit
        case agentError(String)
        case malformedOutput
    }

    /// What a run cost, when the agent says. Claude Code puts it in its
    /// result and opencode in each step's event; Vibe keeps it in its
    /// session log, which the app does not read.
    package struct Usage: Equatable, Sendable {
        package let turns: Int?
        package let costUSD: Double?
        package let inputTokens: Int?
        package let cacheWriteTokens: Int?
        package let cacheReadTokens: Int?
        package let outputTokens: Int?

        package init(
            turns: Int?,
            costUSD: Double?,
            inputTokens: Int?,
            cacheWriteTokens: Int?,
            cacheReadTokens: Int?,
            outputTokens: Int?
        ) {
            self.turns = turns
            self.costUSD = costUSD
            self.inputTokens = inputTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.cacheReadTokens = cacheReadTokens
            self.outputTokens = outputTokens
        }

        /// For the log: counts only.
        package var summary: String {
            func field(_ name: String, _ value: Int?) -> String? { value.map { "\(name) \($0)" } }
            return [
                field("turns", turns),
                costUSD.map { String(format: "$%.3f", $0) },
                field("input", inputTokens),
                field("cache write", cacheWriteTokens),
                field("cache read", cacheReadTokens),
                field("output", outputTokens),
            ].compactMap { $0 }.joined(separator: ", ")
        }
    }

    package enum Outcome: Equatable, Sendable {
        /// The agent's list, as it answered. `acceptedTerms` filters it.
        case terms([String], usage: Usage? = nil)
        case failed(Failure)
    }

    /// `claude -p --output-format json`: one result object. With
    /// `--json-schema` the answer is `structured_output`; `result` holds the
    /// same JSON as text and is read when the object is missing.
    package static func parseClaude(stdout: Data, exitCode: Int32) -> Outcome {
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
        let usage = claudeUsage(object)
        if let structured = object["structured_output"] as? [String: Any],
           let terms = structured["terms"] as? [Any]
        {
            return .terms(terms.compactMap { $0 as? String }, usage: usage)
        }
        if let text = object["result"] as? String, let terms = termsObject(in: text) {
            return .terms(terms, usage: usage)
        }
        return .failed(.malformedOutput)
    }

    private static func claudeUsage(_ object: [String: Any]) -> Usage {
        let usage = object["usage"] as? [String: Any] ?? [:]
        return Usage(
            turns: object["num_turns"] as? Int,
            costUSD: object["total_cost_usd"] as? Double,
            inputTokens: usage["input_tokens"] as? Int,
            cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int,
            outputTokens: usage["output_tokens"] as? Int
        )
    }

    /// `vibe -p --output json`: the session as an array of entries, the same
    /// shape on both harnesses. The answer is the last assistant message's
    /// text, sometimes in one ```json fence. A run that stopped at the turn
    /// limit exits 0 with tool calls after its last message.
    package static func parseVibe(stdout: Data, exitCode: Int32) -> Outcome {
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
        guard let terms = termsObject(in: text) else { return .failed(.malformedOutput) }
        return .terms(terms)
    }

    /// `opencode run --format json`: one JSON event per line. The answer is
    /// the text of the last message that has text; the usage is the sum of
    /// its `step_finish` events. An `error` event (a provider refusal, a
    /// quota) fails the run whatever came before it. At the step cap
    /// opencode forces a text-only answer, so there is no turn-limit case.
    package static func parseOpencode(stdout: Data, exitCode: Int32) -> Outcome {
        var events: [[String: Any]] = []
        for line in stdout.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                return .failed(exitCode == 0 ? .malformedOutput : .exit(exitCode))
            }
            events.append(event)
        }
        if let error = events.last(where: { $0["type"] as? String == "error" })?["error"] as? [String: Any] {
            return .failed(.agentError(error["name"] as? String ?? "unknown"))
        }
        guard exitCode == 0 else { return .failed(.exit(exitCode)) }
        let texts = events.compactMap { event -> (message: String, text: String)? in
            guard event["type"] as? String == "text",
                  let part = event["part"] as? [String: Any],
                  let message = part["messageID"] as? String,
                  let text = part["text"] as? String
            else { return nil }
            return (message, text)
        }
        guard let lastMessage = texts.last?.message,
              let terms = termsObject(in: texts.filter { $0.message == lastMessage }.map(\.text).joined())
        else { return .failed(.malformedOutput) }
        return .terms(terms, usage: opencodeUsage(events))
    }

    private static func opencodeUsage(_ events: [[String: Any]]) -> Usage {
        let steps = events.compactMap { event -> [String: Any]? in
            guard event["type"] as? String == "step_finish" else { return nil }
            return event["part"] as? [String: Any]
        }
        func sum(_ read: ([String: Any]) -> Int?) -> Int? {
            let values = steps.compactMap { ($0["tokens"] as? [String: Any]).flatMap(read) }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        let costs = steps.compactMap { $0["cost"] as? Double }
        return Usage(
            turns: steps.count,
            costUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            inputTokens: sum { $0["input"] as? Int },
            cacheWriteTokens: sum { ($0["cache"] as? [String: Any])?["write"] as? Int },
            cacheReadTokens: sum { ($0["cache"] as? [String: Any])?["read"] as? Int },
            outputTokens: sum { $0["output"] as? Int }
        )
    }

    /// `{"terms": [...]}`, bare or inside one Markdown code fence, or ending
    /// a text that opens with a sentence or two: a model without a schema
    /// flag sometimes says what it did first (opencode, 2026-09-26).
    static func termsObject(in text: String) -> [String]? {
        if let terms = wholeTermsObject(in: text) { return terms }
        guard let key = text.range(of: #""terms""#, options: .backwards),
              let open = text[..<key.lowerBound].lastIndex(of: "{"),
              let close = text.lastIndex(of: "}"), close > key.upperBound
        else { return nil }
        return wholeTermsObject(in: String(text[open...close]))
    }

    private static func wholeTermsObject(in text: String) -> [String]? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            guard let firstNewline = body.firstIndex(of: "\n"),
                  let closing = body.range(of: "```", options: .backwards),
                  closing.lowerBound > firstNewline
            else { return nil }
            body = String(body[body.index(after: firstNewline)..<closing.lowerBound])
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let terms = object["terms"] as? [Any]
        else { return nil }
        return terms.compactMap { $0 as? String }
    }

    /// The agent's answer is untrusted text that repo contents can steer, so
    /// only term-shaped strings survive: the `.github/dictation.md` filter
    /// (no URL or link, at most four words, 2 to 64 characters with a
    /// letter), no control character anywhere, and the learned-term length
    /// cap. One entry per case-folded spelling, first one kept, at most
    /// `maxTerms`.
    package static func acceptedTerms(_ raw: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for candidate in raw {
            guard result.count < maxTerms else { break }
            guard !candidate.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                  let shaped = DictationTermsFile.accepted(candidate)
            else { continue }
            let term = LearnedTerms.sanitized(shaped)
            guard !term.isEmpty, seen.insert(term.caseFoldedForMatching).inserted else { continue }
            result.append(term)
        }
        return result
    }
}
