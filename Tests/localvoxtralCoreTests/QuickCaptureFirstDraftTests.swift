import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

/// #918's first stage: the polishing model's answer, sorted by kind, and the
/// context it reads.
final class QuickCaptureFirstDraftTests: XCTestCase {
    private func response(_ answer: String, finish: String = "stop") -> Data {
        let object: [String: Any] = [
            "choices": [["message": ["content": answer], "finish_reason": finish]],
            "usage": ["prompt_tokens": 7_500, "completion_tokens": 3_000],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testTheAnswerIsSortedByKindAndOnlyAnIssueRelatesToOne() throws {
        let issue = QuickCaptureFirstDraft.outcome(
            status: 200,
            body: response(###"{"kind":"issue","title":"Show drafting progress","body":"## Problem\nx","relation":"extends","issue":909}"###),
            openIssues: [909]
        )
        guard case .draft(let draft, let usage) = issue else { return XCTFail("\(issue)") }
        XCTAssertEqual(draft.kind, .issue)
        XCTAssertEqual(draft.relation, .extends)
        XCTAssertEqual(draft.issue, 909)
        XCTAssertNil(draft.filesRead, "a first draft reads no code")
        XCTAssertEqual(usage?.inputTokens, 7_500)
        XCTAssertEqual(usage?.outputTokens, 3_000)

        let question = QuickCaptureFirstDraft.outcome(
            status: 200,
            body: response(#"<think>hm</think>{"kind":"Question","title":"Why does polish eat backticks?","body":"See #563.","relation":"extends","issue":909}"#),
            openIssues: [909]
        )
        guard case .draft(let answer, _) = question else { return XCTFail("\(question)") }
        XCTAssertEqual(answer.kind, .question, "case-insensitive")
        XCTAssertEqual(answer.body, "See #563.")
        XCTAssertEqual(answer.relation, .none, "a question relates to no issue")
        XCTAssertNil(answer.issue)

        for (raw, kind) in [("task", QuickCaptureKind.task), ("note", .note), ("idea", .issue), (nil, .issue)] {
            let field = raw.map { #""kind":"\#($0)","# } ?? ""
            let outcome = QuickCaptureFirstDraft.outcome(
                status: 200, body: response(#"{\#(field)"title":"T","body":"B","relation":"none","issue":null}"#), openIssues: []
            )
            guard case .draft(let draft, _) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertEqual(draft.kind, kind, raw ?? "no kind: an issue, the kind the user reviews")
        }
    }

    func testAnHTTPErrorACutAnswerOrNoJSONFails() {
        XCTAssertEqual(
            QuickCaptureFirstDraft.outcome(status: 403, body: Data(), openIssues: []), .failed(.agentError("http 403"))
        )
        XCTAssertEqual(
            QuickCaptureFirstDraft.outcome(status: 200, body: response(#"{"kind":"issue","ti"#, finish: "length"), openIssues: []),
            .failed(.outputTooLarge), "reasoning that ate the token cap"
        )
        XCTAssertEqual(
            QuickCaptureFirstDraft.outcome(status: 200, body: response("no json"), openIssues: []), .failed(.malformedOutput)
        )
    }

    func testTheRequestQuotesTheContextAndMergesTheEffortLast() throws {
        let context = QuickCaptureContext(
            readme: "# Quill\nQuill typesets Markdown.",
            issueRules: "## Proof\nA test per fix.",
            codeHits: ["Sources/Kern.swift:3:func kern()"],
            openIssues: [.init(number: 12, title: "Kerning", body: "Te pairs")],
            closedIssues: [.init(number: 9, title: "Old kerning")],
            mergedPullRequests: [.init(number: 11, title: "Kern table")]
        )
        let data = QuickCaptureFirstDraft.requestBody(
            model: "zai-glm-5-3", capture: "italic kerning is wrong", projectName: "quill", context: context,
            extraBody: ["reasoning_effort": "low", "max_tokens": 5]
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertEqual(body["max_tokens"] as? Int, 5, "the configuration's fields win")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["content"], QuickCaptureFirstDraft.systemPrompt)
        let user = try XCTUnwrap(messages.last?["content"])
        for part in [
            "<readme>\n# Quill", "<guide>\n## Proof", "Sources/Kern.swift:3:func kern()", "#12 Kerning: Te pairs",
            "<recently-closed-issues>\n#9 Old kerning", "<recently-merged-pull-requests>\n#11 Kern table",
            "<note>\nitalic kerning is wrong\n</note>",
        ] {
            XCTAssertTrue(user.contains(part), part)
        }
        let unlisted = QuickCaptureFirstDraft.userMessage(capture: "c", projectName: "p", context: QuickCaptureContext())
        XCTAssertTrue(unlisted.contains("(could not be listed; do not claim a duplicate)"))
        XCTAssertTrue(unlisted.contains("<search-hits>\n(none)"))
    }
}

final class QuickCaptureContextTests: XCTestCase {
    func testSearchWordsAreTheLongestUncommonWordsAndNeverAnOption() {
        let words = QuickCaptureContext.searchWords(
            in: "Why does polish eat my backticks? Check the QuickCaptureDrafter --force thing tomorrow, polish again"
        )
        XCTAssertEqual(words, ["quickcapturedrafter", "backtick", "polish", "force"])
        XCTAssertTrue(words.allSatisfy(QuickCaptureContext.isSearchWord))
        XCTAssertFalse(QuickCaptureContext.isSearchWord("-e"))
        XCTAssertFalse(QuickCaptureContext.isSearchWord("--output=/tmp/x"))
        let many = QuickCaptureContext.searchWords(in: (1...20).map { "word\($0)xx" }.joined(separator: " "))
        XCTAssertEqual(many.count, QuickCaptureContext.maxSearchWords)
    }

    func testTheGuidesIssueRulesAreItsSectionsAboutIssuesProofAndTests() throws {
        let guide = """
            # Guide

            Intro.

            ## Build and test
            Run the suites.

            ## Code
            Use Mutex.

            ## Working an issue
            Claim it.
            ```
            ## Not a heading
            ```

            ## Proof
            A regression test.
            """
        let rules = try XCTUnwrap(QuickCaptureContext.issueRules(ofGuide: guide))
        XCTAssertTrue(rules.contains("## Build and test\nRun the suites."))
        XCTAssertTrue(rules.contains("## Working an issue\nClaim it."))
        XCTAssertTrue(rules.contains("## Proof\nA regression test."))
        XCTAssertFalse(rules.contains("Use Mutex."))
        XCTAssertEqual(QuickCaptureContext.issueRules(ofGuide: "Just prose."), "Just prose.", "no heading: the opening")
        let long = String(repeating: "x", count: 10_000)
        XCTAssertEqual(QuickCaptureContext.issueRules(ofGuide: long)?.count, QuickCaptureContext.maxRulesCharacters)
    }

    func testAHostsBundleIsReadSectionBySectionAndCapped() throws {
        let hits = (1...50).map { "a.swift:\($0):" + String(repeating: "y", count: 300) }.joined(separator: "\n")
        let bundle = """
            @@lvx readme
            # Quill
            Quill typesets Markdown.
            @@lvx guide
            ## Proof
            A test.
            @@lvx grep
            \(hits)
            @@lvx open
            [{"number":12,"title":"Kerning","body":"Te"}]
            @@lvx closed
            [{"number":9,"title":"Old"}]
            @@lvx merged
            not json
            @@lvx unknown
            ignored
            """
        let context = QuickCaptureContext.parse(bundle: Data(bundle.utf8))
        XCTAssertEqual(context.readme, "# Quill\nQuill typesets Markdown.")
        XCTAssertEqual(context.issueRules, "## Proof\nA test.")
        XCTAssertEqual(context.codeHits.count, QuickCaptureContext.maxSearchWords * QuickCaptureContext.hitsPerWord)
        XCTAssertTrue(context.codeHits.allSatisfy { $0.count <= QuickCaptureContext.maxHitCharacters })
        XCTAssertEqual(context.openIssues, [.init(number: 12, title: "Kerning", body: "Te")])
        XCTAssertEqual(context.closedIssues, [.init(number: 9, title: "Old")])
        XCTAssertNil(context.mergedPullRequests, "unreadable: not listed")
        XCTAssertEqual(QuickCaptureContext.parse(bundle: Data()), QuickCaptureContext(), "an empty bundle reads as nothing")
    }

    func testTheGathererGrepsEachWordAndListsTheTracker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qc-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Quill\n\nQuill typesets Markdown.".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "@AGENTS.md\n".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "## Proof\nA test per fix.".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let calls = Mutex<[[String]]>([])
        let gatherer = QuickCaptureContextGatherer(
            run: { tool, arguments, _ in
                calls.withLock { $0.append([tool == .git ? "git" : "gh"] + arguments) }
                switch (tool, arguments.first) {
                case (.git, _): return Data("Sources/Kern.swift:3:\(arguments[8])\nb:1:x\nc:1:x\nd:1:x\ne:1:x\n".utf8)
                case (.gh, "issue"): return Data(#"[{"number":9,"title":"Old"}]"#.utf8)
                case (.gh, _): return nil
                }
            },
            openIssues: { _, repository in repository == "o/quill" ? [] : nil },
            checkoutRepository: { _ in "o/quill" }
        )
        let context = await gatherer.gather(root: root.path, repository: nil, capture: "italic kerning")
        XCTAssertEqual(context.readme, "# Quill\n\nQuill typesets Markdown.")
        XCTAssertEqual(context.issueRules, "## Proof\nA test per fix.")
        XCTAssertEqual(context.codeHits.count, 2 * QuickCaptureContext.hitsPerWord, "four hits a word")
        XCTAssertEqual(context.codeHits.first, "Sources/Kern.swift:3:kerning")
        XCTAssertEqual(context.openIssues, [])
        XCTAssertEqual(context.closedIssues, [.init(number: 9, title: "Old")])
        XCTAssertNil(context.mergedPullRequests, "gh failed: not listed")
        let greps = calls.withLock { $0.filter { $0.first == "git" } }
        XCTAssertEqual(greps.map { Array($0.dropFirst()) }, [
            QuickCaptureContext.grepArguments(word: "kerning"), QuickCaptureContext.grepArguments(word: "italic"),
        ])
        XCTAssertEqual(greps.first?.suffix(3), ["-e", "kerning", "--"], "the word after -e, pathspecs closed")
        let lists = calls.withLock { $0.filter { $0.first == "gh" } }
        XCTAssertEqual(Set(lists.map { $0[1...4].joined(separator: " ") }), ["issue list --repo o/quill", "pr list --repo o/quill"],
                       "the checkout's filing repository, not gh's pick (#919)")

        let named = await gatherer.gather(root: root.path, repository: "me/fork", capture: "x")
        XCTAssertNil(named.openIssues, "the project's repository wins over the checkout's")
    }

    /// README, AGENTS.md and CLAUDE.md symlinked to a file outside the
    /// checkout stay out of the first draft's request.
    func testTheGathererReadsNoSymlinkedReadmeOrGuide() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("qc-context-link-\(UUID().uuidString)")
        let root = base.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let secret = base.appendingPathComponent("secret.md")
        try "# OUTSIDE-SENTINEL\n\nOUTSIDE-SENTINEL prose.\n\n## Proof\nOUTSIDE-SENTINEL".write(
            to: secret, atomically: true, encoding: .utf8
        )
        for name in ["README.md", "AGENTS.md", "CLAUDE.md"] {
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent(name).path, withDestinationPath: secret.path
            )
        }
        let gatherer = QuickCaptureContextGatherer(
            run: { _, _, _ in nil },
            openIssues: { _, _ in nil },
            checkoutRepository: { _ in nil }
        )
        let context = await gatherer.gather(root: root.path, repository: nil, capture: "kerning")
        XCTAssertNil(context.readme)
        XCTAssertNil(context.issueRules)
    }
}

/// #918's two stages in the drafter: the first draft, then the agent's
/// check of an issue.
final class QuickCaptureTwoStageDrafterTests: XCTestCase {
    private let projects = [QuickCaptureProject(key: "/w/reach", name: "reach", summary: nil, terms: [], userLine: nil)]
    static let first = QuickCaptureDraft.Draft(
        kind: .issue, title: "Show drafting progress", body: "## Problem\nNo progress.", relation: .none, issue: nil
    )
    static let checked = QuickCaptureDraft.Draft(
        title: "Show drafting progress in the Inbox row", body: "## Problem\nQuickCaptureDrafter.draft is silent.",
        relation: .none, issue: nil, filesRead: ["Sources/Drafter.swift", "Gone.swift"]
    )

    private func drafter(_ runner: FakeQuickCaptureCheckRunner, _ first: FakeQuickCaptureFirstDrafter?) -> QuickCaptureDrafter {
        QuickCaptureDrafter(
            runner: runner,
            openIssues: { _, _ in [] },
            context: { _, _, _ in QuickCaptureContext(codeHits: ["hit"], openIssues: []) },
            firstDrafter: first,
            trackedFiles: { _ in [] },
            directoryExists: { $0 == "/w/reach" },
            fileExists: { $0 == "/w/reach/Sources/Drafter.swift" },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    func testAnIssuesFirstDraftComesFirstThenTheAgentChecksIt() async throws {
        let runner = FakeQuickCaptureCheckRunner([.draft(Self.checked, usage: nil)])
        let first = FakeQuickCaptureFirstDrafter([.draft(Self.first, usage: nil)])
        let seen = Mutex<[QuickCaptureDraft.Outcome]>([])
        let final = await drafter(runner, first).draft(
            capture: "show drafting progress", route: .project("/w/reach"), projects: projects, agents: [.claude],
            onFirstDraft: { outcome in
                XCTAssertTrue(runner.prompts.withLock { $0.isEmpty }, "the first draft lands before the check starts")
                seen.withLock { $0.append(outcome) }
                return true
            }
        )
        XCTAssertEqual(seen.withLock { $0 }, [.draft(Self.first, usage: nil)])
        XCTAssertEqual(first.contexts.withLock { $0.first?.codeHits }, ["hit"])
        let prompt = try XCTUnwrap(runner.prompts.withLock { $0.first })
        XCTAssertTrue(prompt.contains("<first-draft>\nShow drafting progress\n\n## Problem\nNo progress.\n</first-draft>"))
        XCTAssertTrue(prompt.contains("Check it against the code."))
        guard case .draft(let draft, _)? = final else { return XCTFail("\(String(describing: final))") }
        XCTAssertEqual(draft.title, Self.checked.title)
        XCTAssertEqual(draft.filesRead, ["Sources/Drafter.swift"], "only files in the checkout count as read")
        XCTAssertEqual(draft.agent, .claude)
    }

    func testAQuestionTaskOrNoteIsNeverCheckedAndAStopSkipsTheCheck() async {
        for kind in [QuickCaptureKind.question, .task, .note] {
            let runner = FakeQuickCaptureCheckRunner([.draft(Self.checked, usage: nil)])
            let draft = QuickCaptureDraft.Draft(kind: kind, title: "T", body: "B", relation: .none, issue: nil)
            let final = await drafter(runner, FakeQuickCaptureFirstDrafter([.draft(draft, usage: nil)])).draft(
                capture: "c", route: .project("/w/reach"), projects: projects, agents: [.claude]
            )
            XCTAssertNil(final, "\(kind)")
            XCTAssertTrue(runner.prompts.withLock { $0.isEmpty }, "\(kind): no agent run")
        }
        let runner = FakeQuickCaptureCheckRunner([.draft(Self.checked, usage: nil)])
        let stopped = await drafter(runner, FakeQuickCaptureFirstDrafter([.draft(Self.first, usage: nil)])).draft(
            capture: "c", route: .project("/w/reach"), projects: projects, agents: [.claude],
            onFirstDraft: { _ in false }
        )
        XCTAssertNil(stopped)
        XCTAssertTrue(runner.prompts.withLock { $0.isEmpty }, "filed or discarded meanwhile: no check")
    }

    func testAFailedFirstDraftLeavesTheAgentToDraftFromTheCapture() async throws {
        let runner = FakeQuickCaptureCheckRunner([.draft(Self.checked, usage: nil)])
        let final = await drafter(runner, FakeQuickCaptureFirstDrafter([.failed(.agentError("http 403"))])).draft(
            capture: "c", route: .project("/w/reach"), projects: projects, agents: [.claude]
        )
        let prompt = try XCTUnwrap(runner.prompts.withLock { $0.first })
        XCTAssertFalse(prompt.contains("<first-draft>"))
        XCTAssertTrue(prompt.contains("Turn it into a GitHub issue"))
        guard case .draft? = final else { return XCTFail("\(String(describing: final))") }
    }
}

/// The Inbox with both stages (#918): what the user sees, and when.
@MainActor
final class QuickCaptureTwoStageInboxTests: XCTestCase {
    private var fileURL: URL!
    private let github = FakeQuickCaptureGitHub()

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-two-stage-\(UUID().uuidString)")
            .appendingPathComponent("quick-captures.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func model(
        runner: FakeQuickCaptureCheckRunner, first: FakeQuickCaptureFirstDrafter?,
        projects: (@MainActor () -> [QuickCaptureProject])? = nil
    ) -> QuickCaptureInboxModel {
        let github = github
        let reach = [QuickCaptureProject(key: "/w/reach", name: "reach", summary: nil, terms: [], userLine: nil)]
        return QuickCaptureInboxModel(
            fileURL: fileURL,
            makeRouter: { QuickCaptureRouter(classifiers: [FixedQuickCaptureClassifier(["reach": 0.95])]) },
            projects: projects ?? { reach },
            agents: { [.claude] },
            drafter: {
                QuickCaptureDrafter(
                    runner: runner,
                    openIssues: { _, _ in [] },
                    firstDrafter: first,
                    trackedFiles: { _ in [] },
                    directoryExists: { _ in true },
                    fileExists: { _ in true }
                )
            },
            github: github,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }

    private static let first = QuickCaptureTwoStageDrafterTests.first
    private static let checked = QuickCaptureTwoStageDrafterTests.checked

    func testTheFirstDraftCanBeFiledWhileTheCheckRunsAndTheCheckThenReplacesIt() async throws {
        let runner = FakeQuickCaptureCheckRunner([.draft(Self.checked, usage: nil)], gated: true)
        let model = model(runner: runner, first: FakeQuickCaptureFirstDrafter([.draft(Self.first, usage: nil)]))
        let task = model.capture(text: "show drafting progress", historyRecordID: nil)
        await runner.gate!.waitForSleepers(1)

        var item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.state, .ready)
        XCTAssertEqual(item.kind, .issue)
        XCTAssertEqual(item.title, Self.first.title)
        XCTAssertEqual(item.codeCheck, QuickCaptureCodeCheck(state: .checking))
        XCTAssertTrue(item.canFile, "no waiting for the check")
        XCTAssertFalse(item.canDraftAgain)
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).value?.items.first?.codeCheck?.state, .failed,
                       "a quit mid-check leaves the first draft, marked unchecked")

        runner.gate!.wakeAll()
        await task.value
        item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.title, Self.checked.title)
        XCTAssertEqual(item.body, Self.checked.body)
        XCTAssertEqual(
            item.codeCheck,
            QuickCaptureCodeCheck(state: .checked, filesRead: ["Sources/Drafter.swift", "Gone.swift"], agent: "claude")
        )
    }

    /// "File issues here" changed while the check ran (#1277): the issue
    /// the check found among the fork's is not linked to the upstream.
    func testACheckFromBeforeAFilingChangeLinksNoIssueOfTheOldRepository() async throws {
        let facts = GitHubRepositoryFacts(description: nil, topics: [], parent: "them/reach")
        func reach(filingIn issueRepository: String) -> [QuickCaptureProject] {
            [QuickCaptureProject(
                key: "/w/reach", name: "reach", summary: nil, terms: [], userLine: nil,
                repository: "me/reach", issueRepository: issueRepository, github: facts)]
        }
        let extending = QuickCaptureDraft.Draft(
            title: Self.checked.title, body: Self.checked.body, relation: .extends, issue: 7, filesRead: ["Sources/Drafter.swift"]
        )
        let runner = FakeQuickCaptureCheckRunner([.draft(extending, usage: nil)], gated: true)
        let list = Mutex(reach(filingIn: "me/reach"))
        let model = model(
            runner: runner, first: FakeQuickCaptureFirstDrafter([.draft(Self.first, usage: nil)]),
            projects: { list.withLock { $0 } })
        let task = model.capture(text: "show drafting progress", historyRecordID: nil)
        await runner.gate!.waitForSleepers(1)
        XCTAssertEqual(model.items.first?.repository, "me/reach")

        list.withLock { $0 = reach(filingIn: "them/reach") }
        model.adoptProjects()
        runner.gate!.wakeAll()
        await task.value

        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.title, Self.checked.title)
        XCTAssertEqual(item.repository, "them/reach")
        XCTAssertNil(item.relatedIssue)
        XCTAssertFalse(item.canComment)
    }

    func testEditsMadeDuringTheCheckAreKept() async throws {
        let runner = FakeQuickCaptureCheckRunner([.draft(Self.checked, usage: nil)], gated: true)
        let model = model(runner: runner, first: FakeQuickCaptureFirstDrafter([.draft(Self.first, usage: nil)]))
        let task = model.capture(text: "show drafting progress", historyRecordID: nil)
        await runner.gate!.waitForSleepers(1)
        let id = try XCTUnwrap(model.items.first?.id)
        model.setBody("My own words.", for: id)
        runner.gate!.wakeAll()
        await task.value
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.title, Self.first.title)
        XCTAssertEqual(item.body, "My own words.")
        XCTAssertEqual(item.codeCheck?.state, .checked)
        XCTAssertEqual(item.codeCheck?.keptEdits, true)
    }

    func testFilingBeforeTheCheckDropsTheCheck() async throws {
        let runner = FakeQuickCaptureCheckRunner([.draft(Self.checked, usage: nil)], gated: true)
        let model = model(runner: runner, first: FakeQuickCaptureFirstDrafter([.draft(Self.first, usage: nil)]))
        let task = model.capture(text: "show drafting progress", historyRecordID: nil)
        await runner.gate!.waitForSleepers(1)
        let id = try XCTUnwrap(model.items.first?.id)
        await model.file(id)?.value
        runner.gate!.wakeAll()
        await task.value
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.state, .filed)
        XCTAssertEqual(item.title, Self.first.title, "the filed draft stays what was filed")
        XCTAssertNil(item.codeCheck)
        XCTAssertEqual(github.created.withLock { $0.count }, 1)
    }

    func testACheckThatLandsDuringAFailedFilingCanBeDraftedAgain() async throws {
        let runner = FakeQuickCaptureCheckRunner([.draft(Self.checked, usage: nil)], gated: true)
        let filing = ManualSleeper()
        github.createGate = filing
        github.createResult = .failure(.failed(exitCode: 1))
        let model = model(runner: runner, first: FakeQuickCaptureFirstDrafter([.draft(Self.first, usage: nil)]))
        let task = model.capture(text: "show drafting progress", historyRecordID: nil)
        await runner.gate!.waitForSleepers(1)
        let id = try XCTUnwrap(model.items.first?.id)
        let file = try XCTUnwrap(model.file(id))
        await filing.waitForSleepers(1)
        runner.gate!.wakeAll()
        await task.value
        filing.wakeAll()
        await file.value
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.state, .ready)
        XCTAssertEqual(item.note, "Filing failed. Check that gh is logged in.")
        XCTAssertEqual(item.codeCheck?.state, .failed)
        XCTAssertTrue(item.canDraftAgain, "the dropped check can be run again")
    }

    func testAQuestionShowsItsAnswerAndATaskOrNoteIsNeverFiled() async throws {
        for kind in [QuickCaptureKind.question, .task, .note] {
            let runner = FakeQuickCaptureCheckRunner([.draft(Self.checked, usage: nil)], gated: true)
            let draft = QuickCaptureDraft.Draft(kind: kind, title: "Why backticks?", body: "The answer.", relation: .none, issue: nil)
            let model = model(runner: runner, first: FakeQuickCaptureFirstDrafter([.draft(draft, usage: nil)]))
            await model.capture(text: "why does polish eat my backticks", historyRecordID: nil).value
            let item = try XCTUnwrap(model.items.first)
            XCTAssertEqual(item.kind, kind)
            XCTAssertEqual(item.body, "The answer.")
            XCTAssertNil(item.codeCheck)
            XCTAssertFalse(item.canFile, "\(kind)")
            XCTAssertNil(model.file(item.id))
            XCTAssertEqual(runner.runs, 0, "\(kind): no agent")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func testAFailedDraftOrCheckCanBeDraftedAgain() async throws {
        let runner = FakeQuickCaptureCheckRunner([.failed(.timedOut), .draft(Self.checked, usage: nil)], gated: true)
        runner.gate!.wakeAll()
        let model = model(runner: runner, first: FakeQuickCaptureFirstDrafter([.failed(.agentError("http 403")), .draft(Self.first, usage: nil)]))
        let capture = model.capture(text: "show drafting progress", historyRecordID: nil)
        await runner.gate!.waitForSleepers(1)
        runner.gate!.wakeAll()
        await capture.value
        var item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.state, .ready)
        XCTAssertEqual(item.title, "")
        XCTAssertEqual(item.note, "The draft took too long.")
        XCTAssertTrue(item.canDraftAgain)

        let again = try XCTUnwrap(model.draftAgain(item.id))
        await runner.gate!.waitForSleepers(1)
        item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.title, Self.first.title, "the second try's first draft")
        XCTAssertNil(item.note)
        XCTAssertFalse(item.canDraftAgain, "not while it checks")
        runner.gate!.wakeAll()
        await again.value
        XCTAssertEqual(model.items.first?.codeCheck?.state, .checked)
        XCTAssertEqual(model.items.first?.title, Self.checked.title)
    }

    func testAFailedCheckKeepsTheFirstDraftAndOffersDraftAgain() async throws {
        let runner = FakeQuickCaptureCheckRunner([.failed(.budgetExceeded)], gated: true)
        runner.gate!.wakeAll()
        let model = model(runner: runner, first: FakeQuickCaptureFirstDrafter([.draft(Self.first, usage: nil)]))
        let task = model.capture(text: "show drafting progress", historyRecordID: nil)
        await runner.gate!.waitForSleepers(1)
        runner.gate!.wakeAll()
        await task.value
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.title, Self.first.title)
        XCTAssertEqual(item.codeCheck?.state, .failed)
        XCTAssertEqual(item.note, "Not checked against the code: the check hit its cost or turn limit.")
        XCTAssertTrue(item.canFile)
        XCTAssertTrue(item.canDraftAgain)
    }

    func testAnInboxFileFromBeforeKindsLoadsAsIssues() throws {
        let old = """
            {"version":1,"items":[{"id":"8A3F1C2E-7B4D-4E5F-9A6B-1C2D3E4F5A6B","capturedAt":"2026-09-26T10:00:00Z",
            "text":"Add a dark mode","state":"ready","title":"Dark mode","body":"All pages.","relation":"none",
            "projectKey":"/w/reach","projectName":"reach","repository":"o/reach"}]}
            """
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(old.utf8).write(to: fileURL)
        let item = try XCTUnwrap(QuickCaptureInboxFile.load(from: fileURL).value?.items.first)
        XCTAssertNil(item.kind)
        XCTAssertTrue(item.isIssue)
        XCTAssertNil(item.codeCheck)
        XCTAssertTrue(item.canFile)
    }
}
