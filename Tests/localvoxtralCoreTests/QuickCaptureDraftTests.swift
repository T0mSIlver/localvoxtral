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

    private func drafter(_ runner: Runner, issuesAsked: Asked = Asked()) -> QuickCaptureDrafter {
        QuickCaptureDrafter(
            runner: runner,
            openIssues: { root in
                issuesAsked.roots.withLock { $0.append(root) }
                return []
            },
            trackedFiles: { _ in ["README.md"] },
            directoryExists: { $0 == "/w/reach" }
        )
    }

    func testTheNextAgentRunsOnlyWhenOneIsNotInstalled() async {
        let runner = Runner([.vibe: .draft(draft, usage: nil)])
        let outcome = await drafter(runner).draft(
            capture: "c", route: .project("/w/reach"), projects: projects, agents: [.claude, .vibe]
        )
        XCTAssertEqual(outcome, .draft(draft, usage: nil))
        XCTAssertEqual(runner.invocations.withLock { $0.map(\.agent) }, [.claude, .vibe])
        XCTAssertEqual(runner.invocations.withLock { $0.map(\.workingDirectory) }, ["/w/reach", "/w/reach"])

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
