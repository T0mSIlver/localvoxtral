import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore

final class QuickCaptureDraftTests: XCTestCase {
    // MARK: Command line

    func testTheClaudeRunHasReadOnlyToolsNoHooksAndBothCaps() {
        let arguments = QuickCaptureDraft.claudeArguments(prompt: "P")
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        XCTAssertEqual(value("-p"), "P")
        XCTAssertEqual(value("--tools"), "Read,Glob,Grep")
        XCTAssertEqual(value("--settings"), #"{"disableAllHooks":true}"#)
        XCTAssertEqual(value("--max-turns"), "20")
        XCTAssertEqual(value("--max-budget-usd"), "0.50")
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertFalse(arguments.contains { $0.contains("Bash") })
    }

    func testTheVibeRunRefusesBashAndIsCapped() {
        let arguments = QuickCaptureDraft.vibeArguments(prompt: "P", trackedFiles: ["a.swift"])
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        XCTAssertEqual(value("--enabled-tools"), #"re:^(read_file|grep|file_system[.](read_file|grep|glob|list_dir))$"#)
        XCTAssertEqual(value("--max-price"), "0.30")
        XCTAssertEqual(value("--max-turns"), "20")
        XCTAssertTrue(value("-p")?.hasSuffix("read_file takes these paths):\na.swift") == true)
        XCTAssertFalse(arguments.contains("--trust"))
    }

    func testTheOpencodeRunIsTheTermsRunWithTheDraftingPromptAndTwentySteps() throws {
        XCTAssertEqual(QuickCaptureDraft.opencodeArguments(workingDirectory: "/w/reach", prompt: "P"), [
            "run", "--pure", "--format", "json", "--dir", "/w/reach", "--agent", "localvoxtral-draft", "P",
        ])
        var environment = QuickCaptureDraft.opencodeEnvironment
        var terms = ProjectTermProposal.opencodeEnvironment
        let config = try XCTUnwrap(environment.removeValue(forKey: "OPENCODE_CONFIG_CONTENT"))
        let termsConfig = try XCTUnwrap(terms.removeValue(forKey: "OPENCODE_CONFIG_CONTENT"))
        XCTAssertEqual(environment.removeValue(forKey: "OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX"), "16384")
        terms.removeValue(forKey: "OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX")
        XCTAssertEqual(environment, terms, "the same isolation from the user's database, config and skills")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let termsObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(termsConfig.utf8)) as? [String: Any])
        let readOnly = try XCTUnwrap(termsObject["permission"] as? [String: String])
        XCTAssertEqual(object["permission"] as? [String: String], readOnly)
        XCTAssertEqual(readOnly["bash"], "deny")
        XCTAssertEqual(readOnly["*"], "deny")
        let agent = try XCTUnwrap((object["agent"] as? [String: Any])?["localvoxtral-draft"] as? [String: Any])
        XCTAssertEqual(agent["permission"] as? [String: String], readOnly)
        XCTAssertEqual(agent["steps"] as? Int, 20)
        XCTAssertEqual(agent["prompt"] as? String, QuickCaptureDraft.claudeSystemPrompt)
        XCTAssertEqual(object["share"] as? String, "disabled")

        let invocation = QuickCaptureDraft.invocation(
            agent: .opencode, workingDirectory: "/w/reach", prompt: "P", trackedFiles: ["a.swift"]
        )
        XCTAssertEqual(invocation.arguments, QuickCaptureDraft.opencodeArguments(workingDirectory: "/w/reach", prompt: "P"))
        XCTAssertEqual(invocation.environment, QuickCaptureDraft.opencodeEnvironment)
        XCTAssertEqual(
            QuickCaptureDraft.invocation(agent: .claude, workingDirectory: "/w", prompt: "P", trackedFiles: []).environment,
            [:]
        )
    }

    // MARK: Prompt

    func testThePromptListsOpenIssuesOnOneLineEachOrSaysTheyCouldNotBeListed() {
        let listed = QuickCaptureDraft.prompt(
            capture: "Add a dark mode",
            projectName: "reach",
            issues: [QuickCaptureDraft.OpenIssue(number: 7, title: "Theme\nsupport", body: "Colors.\n\nMore.")]
        )
        XCTAssertTrue(listed.contains("<capture>\nAdd a dark mode\n</capture>"))
        XCTAssertTrue(listed.hasSuffix("Open issues:\n#7 Theme support: Colors. More.\n"))
        let unlisted = QuickCaptureDraft.prompt(capture: "x", projectName: "reach", issues: nil)
        XCTAssertTrue(unlisted.hasSuffix("(could not be listed; do not claim a duplicate)\n"))
    }

    func testTheIssueListIsReadFromGhsJSON() {
        let data = Data(#"[{"number": 3, "title": "A", "body": "b"}, {"title": "no number"}]"#.utf8)
        XCTAssertEqual(QuickCaptureDraft.parseIssueList(data), [.init(number: 3, title: "A", body: "b")])
        XCTAssertNil(QuickCaptureDraft.parseIssueList(Data("not json".utf8)))
    }

    // MARK: Answer

    private func claudeResult(_ answer: [String: Any], extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = [
            "type": "result", "subtype": "success", "is_error": false,
            "num_turns": 6, "total_cost_usd": 0.12, "structured_output": answer,
        ]
        object.merge(extra) { $1 }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testAClaudeDraftIsReadWithItsUsage() {
        let outcome = QuickCaptureDraft.parseClaude(
            stdout: claudeResult(["title": "Dark mode", "body": "## Scope\nAll pages.", "relation": "extends", "issue": 7]),
            exitCode: 0,
            openIssues: [7]
        )
        guard case .draft(let draft, let usage) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(draft, .init(title: "Dark mode", body: "## Scope\nAll pages.", relation: .extends, issue: 7))
        XCTAssertEqual(usage?.turns, 6)
        XCTAssertEqual(usage?.costUSD, 0.12)
    }

    func testTheAnswerIsUntrustedText() {
        let cases: [([String: Any], QuickCaptureDraft.Draft?)] = [
            (
                ["title": "Line one\nline two\u{7}", "body": "Body\u{1B}[31m\n", "relation": "duplicate", "issue": 99],
                .init(title: "Line one line two", body: "Body[31m", relation: .none, issue: nil)
            ),
            (["title": String(repeating: "t", count: 300), "body": "b", "relation": "none", "issue": 7],
             .init(title: String(repeating: "t", count: 119) + "…", body: "b", relation: .none, issue: nil)),
            (["title": " ", "body": "b", "relation": "none", "issue": NSNull()], nil),
        ]
        for (answer, expected) in cases {
            let outcome = QuickCaptureDraft.parseClaude(stdout: claudeResult(answer), exitCode: 0, openIssues: [7])
            if let expected {
                XCTAssertEqual(outcome, .draft(expected, usage: .init(
                    turns: 6, costUSD: 0.12, inputTokens: nil, cacheWriteTokens: nil, cacheReadTokens: nil, outputTokens: nil
                )))
            } else {
                XCTAssertEqual(outcome, .failed(.malformedOutput))
            }
        }
    }

    func testCapsAndErrorsReadAsFailures() {
        for (subtype, failure) in [
            ("error_max_budget_usd", ProjectTermProposal.Failure.budgetExceeded),
            ("error_max_turns", .turnLimit),
            ("error_during_execution", .agentError("error_during_execution")),
        ] {
            let stdout = claudeResult([:], extra: ["is_error": true, "subtype": subtype])
            XCTAssertEqual(QuickCaptureDraft.parseClaude(stdout: stdout, exitCode: 1, openIssues: []), .failed(failure))
        }
    }

    func testAVibeDraftIsTheLastAssistantMessage() throws {
        let entries: [[String: Any]] = [
            ["type": "message", "role": "user", "content": [["text": "P"]]],
            ["type": "message", "role": "assistant", "content": [
                ["text": "```json\n{\"title\": \"T\", \"body\": \"B\", \"relation\": \"none\", \"issue\": null}\n```"],
            ]],
        ]
        let stdout = try JSONSerialization.data(withJSONObject: entries)
        XCTAssertEqual(
            QuickCaptureDraft.parseVibe(stdout: stdout, exitCode: 0, openIssues: []),
            .draft(.init(title: "T", body: "B", relation: .none, issue: nil), usage: nil)
        )
        let cut = try JSONSerialization.data(withJSONObject: entries + [["type": "effect"]])
        XCTAssertEqual(QuickCaptureDraft.parseVibe(stdout: cut, exitCode: 0, openIssues: []), .failed(.turnLimit))
    }
}

extension QuickCaptureDraftTests {
    /// Two steps: a read, then the answer after a sentence, in a fence.
    static let opencodeDraft = #"""
        {"type":"step_start","sessionID":"ses_1","part":{"type":"step-start","messageID":"msg_a"}}
        {"type":"text","sessionID":"ses_1","part":{"type":"text","messageID":"msg_a","text":"Reading AGENTS.md first."}}
        {"type":"tool_use","sessionID":"ses_1","part":{"type":"tool","messageID":"msg_a","tool":"read","state":{"status":"completed"}}}
        {"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","messageID":"msg_a","reason":"tool-calls","tokens":{"input":9000,"output":40,"reasoning":0,"cache":{"write":0,"read":0}},"cost":0}}
        {"type":"step_start","sessionID":"ses_1","part":{"type":"step-start","messageID":"msg_b"}}
        {"type":"text","sessionID":"ses_1","part":{"type":"text","messageID":"msg_b","text":"Here is the draft.\n\n```json\n{\"title\": \"Bluesky followers\", \"body\": \"## Scope\\nChart them.\", \"relation\": \"extends\", \"issue\": 12}\n```"}}
        {"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","messageID":"msg_b","reason":"stop","tokens":{"input":23,"output":736,"reasoning":0,"cache":{"write":0,"read":18368}},"cost":0}}
        """#

    func testAnOpencodeDraftIsTheLastMessageWithItsSummedUsage() throws {
        let outcome = QuickCaptureDraft.parseOpencode(stdout: Data(Self.opencodeDraft.utf8), exitCode: 0, openIssues: [12])
        guard case .draft(let draft, let usage) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(draft, .init(title: "Bluesky followers", body: "## Scope\nChart them.", relation: .extends, issue: 12))
        let summed = try XCTUnwrap(usage)
        XCTAssertEqual(summed.turns, 2)
        XCTAssertEqual(summed.inputTokens, 9023)
        XCTAssertEqual(summed.cacheReadTokens, 18368)
        XCTAssertEqual(summed.outputTokens, 776)
        XCTAssertEqual(summed.costUSD, 0)
    }

    func testAnOpencodeDraftIsUntrustedAndItsFailuresAreTheTermsRuns() {
        // An issue that was not listed is no relation.
        XCTAssertEqual(
            QuickCaptureDraft.parseOpencode(stdout: Data(Self.opencodeDraft.utf8), exitCode: 0, openIssues: [3]),
            .draft(.init(title: "Bluesky followers", body: "## Scope\nChart them.", relation: .none, issue: nil), usage: .init(
                turns: 2, costUSD: 0, inputTokens: 9023, cacheWriteTokens: 0, cacheReadTokens: 18368, outputTokens: 776
            ))
        )
        let quota = #"{"type":"error","sessionID":"ses_1","error":{"name":"APIError","data":{"statusCode":429}}}"#
        XCTAssertEqual(
            QuickCaptureDraft.parseOpencode(stdout: Data((Self.opencodeDraft + "\n" + quota).utf8), exitCode: 0, openIssues: []),
            .failed(.agentError("APIError"))
        )
        XCTAssertEqual(
            QuickCaptureDraft.parseOpencode(stdout: Data(Self.opencodeDraft.utf8), exitCode: 1, openIssues: []),
            .failed(.exit(1))
        )
        let prose = #"{"type":"text","sessionID":"ses_1","part":{"type":"text","messageID":"msg_c","text":"I could not finish."}}"#
        XCTAssertEqual(
            QuickCaptureDraft.parseOpencode(stdout: Data(prose.utf8), exitCode: 0, openIssues: []),
            .failed(.malformedOutput)
        )
        XCTAssertEqual(QuickCaptureDraft.parseOpencode(stdout: Data(), exitCode: 0, openIssues: []), .failed(.malformedOutput))
    }

    /// The runner hands opencode the run's own config: without it the run
    /// would get the user's permissions, bash included. The stand-in
    /// answers only when every variable and argument the run needs is there.
    func testTheRunnerGivesOpencodeItsOwnConfigAndReadsItsAnswer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-opencode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("home/.opencode/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let answer = root.appendingPathComponent("answer.jsonl")
        try Data(Self.opencodeDraft.utf8).write(to: answer)
        let script = """
            #!/bin/sh
            [ "$1" = run ] && [ "$OPENCODE_DB" = ":memory:" ] && [ "$OPENCODE_DISABLE_PROJECT_CONFIG" = 1 ] || exit 3
            case "$OPENCODE_CONFIG_CONTENT" in *'"localvoxtral-draft"'*'"steps":20'*) ;; *) exit 4 ;; esac
            cat '\(answer.path)'
            """
        let executable = bin.appendingPathComponent("opencode")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runner = QuickCaptureDraftProcessRunner(
            environment: ["HOME": root.appendingPathComponent("home").path, "PATH": "/usr/bin:/bin"],
            vibeHome: root.appendingPathComponent("vibe-home"),
            userVibeDirectory: root.appendingPathComponent("vibe")
        )
        let invocation = QuickCaptureDraft.invocation(
            agent: .opencode, workingDirectory: root.path, prompt: "P", trackedFiles: []
        )
        let outcome = await runner.run(invocation, openIssues: [12])
        guard case .draft(let draft, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(draft.title, "Bluesky followers")
    }
}

final class QuickCaptureDrafterTests: XCTestCase {
    private final class Runner: QuickCaptureDraftRunning, @unchecked Sendable {
        let answers: [ProjectTermProposal.Agent: QuickCaptureDraft.Outcome]
        let invocations = Mutex<[ProjectTermProposal.Invocation]>([])
        init(_ answers: [ProjectTermProposal.Agent: QuickCaptureDraft.Outcome]) { self.answers = answers }
        func run(_ invocation: ProjectTermProposal.Invocation, openIssues: [Int]) async -> QuickCaptureDraft.Outcome {
            invocations.withLock { $0.append(invocation) }
            return answers[invocation.agent] ?? .failed(.agentNotFound)
        }
    }

    private let projects = [
        QuickCaptureProject(key: "/w/reach", name: "reach", summary: nil, terms: [], userLine: nil),
        QuickCaptureProject(key: "remote:website", name: "website", summary: nil, terms: [], userLine: nil),
    ]
    private let draft = QuickCaptureDraft.Draft(title: "T", body: "B", relation: .none, issue: nil)

    private final class Asked: @unchecked Sendable {
        let roots = Mutex<[String]>([])
    }

    private func drafter(
        _ runner: Runner, issuesAsked: Asked = Asked(), usage: UsageLedger? = nil
    ) -> QuickCaptureDrafter {
        QuickCaptureDrafter(
            runner: runner,
            openIssues: { root, _ in
                issuesAsked.roots.withLock { $0.append(root) }
                return []
            },
            trackedFiles: { _ in ["README.md"] },
            directoryExists: { $0 == "/w/reach" },
            usageRecorder: usage,
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }

    func testEachAgentThatRanIsChargedToDraftingOnItsOwnBackend() async {
        let reported = ProjectTermProposal.Usage(
            turns: 7, costUSD: 0.1, inputTokens: 8, cacheWriteTokens: 18_000,
            cacheReadTokens: 53_000, outputTokens: 1_900)
        let moment = Date(timeIntervalSince1970: 1_790_000_000)
        let cases: [(Runner, [UsageEntry])] = [
            (Runner([.claude: .draft(draft, usage: reported)]), [UsageEntry(
                date: moment, feature: .quickCaptureDrafting, backend: .claudeCode, model: "sonnet",
                promptTokens: 71_008, cachedPromptTokens: 53_000, completionTokens: 1_900, agentCostUSD: 0.1)]),
            // Claude is missing, so only Vibe ran, and it reports no usage.
            (Runner([.vibe: .draft(draft, usage: nil)]), [UsageEntry(
                date: moment, feature: .quickCaptureDrafting, backend: .vibe, model: "default")]),
            (Runner([.claude: .failed(.timedOut)]), [UsageEntry(
                date: moment, feature: .quickCaptureDrafting, backend: .claudeCode, model: "sonnet")]),
            // Only opencode is installed (#812).
            (Runner([.opencode: .draft(draft, usage: reported)]), [UsageEntry(
                date: moment, feature: .quickCaptureDrafting, backend: .opencode, model: "default",
                promptTokens: 71_008, cachedPromptTokens: 53_000, completionTokens: 1_900, agentCostUSD: 0.1)]),
            (Runner([:]), []),
        ]
        for (runner, expected) in cases {
            let usage = UsageLedger(fileURL: nil)
            _ = await drafter(runner, usage: usage).draft(
                capture: "c", route: .project("/w/reach"), projects: projects, agents: [.claude, .vibe, .opencode]
            )
            XCTAssertEqual(usage.entries(), expected)
        }
    }

    func testTheNextAgentRunsOnlyWhenOneIsNotInstalled() async {
        let runner = Runner([.opencode: .draft(draft, usage: nil)])
        let outcome = await drafter(runner).draft(
            capture: "c", route: .project("/w/reach"), projects: projects, agents: [.claude, .vibe, .opencode]
        )
        XCTAssertEqual(outcome, .draft(draft, usage: nil))
        XCTAssertEqual(runner.invocations.withLock { $0.map(\.agent) }, [.claude, .vibe, .opencode])
        XCTAssertEqual(runner.invocations.withLock { $0.map(\.workingDirectory) }, ["/w/reach", "/w/reach", "/w/reach"])
        XCTAssertEqual(
            runner.invocations.withLock { $0.last?.environment["OPENCODE_CONFIG_CONTENT"] },
            QuickCaptureDraft.opencodeEnvironment["OPENCODE_CONFIG_CONTENT"]
        )

        let failing = Runner([.claude: .failed(.timedOut), .vibe: .draft(draft, usage: nil)])
        let failed = await drafter(failing).draft(
            capture: "c", route: .project("/w/reach"), projects: projects, agents: [.claude, .vibe]
        )
        XCTAssertEqual(failed, .failed(.timedOut), "a run that failed is not retried on another agent's plan")
    }

    func testNoAgentRunsForTheCatchAllARemoteProjectOrAMissingCheckout() async {
        let runner = Runner([.claude: .draft(draft, usage: nil)])
        let asked = Asked()
        let gone = [QuickCaptureProject(key: "/w/gone", name: "gone", summary: nil, terms: [], userLine: nil)]
        let catchAll = await drafter(runner, issuesAsked: asked).draft(capture: "c", route: .catchAll, projects: projects, agents: [.claude])
        let remote = await drafter(runner, issuesAsked: asked).draft(capture: "c", route: .project("remote:website"), projects: projects, agents: [.claude])
        let missing = await drafter(runner, issuesAsked: asked).draft(capture: "c", route: .project("/w/gone"), projects: gone, agents: [.claude])
        XCTAssertEqual([catchAll, remote, missing], [.notRun(.catchAll), .notRun(.remoteProject), .notRun(.checkoutMissing)])
        XCTAssertTrue(runner.invocations.withLock { $0.isEmpty })
        XCTAssertTrue(asked.roots.withLock { $0.isEmpty })
    }
}
