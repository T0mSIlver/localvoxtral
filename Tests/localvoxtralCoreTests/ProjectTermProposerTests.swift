import ClaudeContextWire
import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore

/// When a joined dictation asks its agent for the project's terms (#609),
/// with a fake runner and store over real directories.
final class ProjectTermProposerTests: XCTestCase {
    private final class FakeRunner: ProjectTermProposalRunning, @unchecked Sendable {
        let invocations = Mutex<[ProjectTermProposal.Invocation]>([])
        let outcome: ProjectTermProposal.Outcome

        init(_ outcome: ProjectTermProposal.Outcome) { self.outcome = outcome }

        func run(_ invocation: ProjectTermProposal.Invocation) async -> ProjectTermProposal.Outcome {
            invocations.withLock { $0.append(invocation) }
            return outcome
        }

        var count: Int { invocations.withLock(\.count) }
    }

    private final class FakeStore: ProjectTermProposalStoring, @unchecked Sendable {
        let memory = Mutex(LearnedTerms())
        let now: @Sendable () -> Date

        init(now: @escaping @Sendable () -> Date) { self.now = now }

        func snapshot() -> LearnedTerms { memory.withLock { $0 } }

        func recordProposal(
            _ terms: [String], line: String?, revision: Int?,
            agent: ProjectTermProposal.Agent,
            project: LearnedTermProjectIdentity,
            excluding: [String]
        ) {
            let moment = now()
            memory.withLock { $0.recordProposal(terms, line: line, revision: revision, agent: agent, project: project, excluding: excluding, now: moment) }
        }

        func recordProposalFailure(project: LearnedTermProjectIdentity) {
            let moment = now()
            memory.withLock { $0.recordProposalFailure(project: project, now: moment) }
        }

        func recordOrigin(_ remote: ProjectRemote, projectKey: String) {
            memory.withLock {
                $0.recordOrigin(remote, projectKey: projectKey)
                $0.ignored.addCheckout(projectKey, ofEntryHolding: remote.key)
                $0.removeIgnoredProjects()
            }
        }
    }

    private final class Clock: @unchecked Sendable {
        let value = Mutex(Date(timeIntervalSince1970: 1_790_000_000))
        var now: @Sendable () -> Date { { [self] in value.withLock { $0 } } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private var root: URL!
    private let clock = Clock()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectTermProposerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A checkout at `name` with a `.git` directory and a `src` subdirectory.
    private func checkout(_ name: String) throws -> String {
        let path = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path + "/src", withIntermediateDirectories: true)
        return path
    }

    /// A linked worktree of `main`, laid out the way `git worktree add` does.
    private func worktree(of main: String, named name: String) throws -> String {
        let gitDirectory = main + "/.git/worktrees/" + name
        try FileManager.default.createDirectory(atPath: gitDirectory, withIntermediateDirectories: true)
        try "../..\n".write(toFile: gitDirectory + "/commondir", atomically: true, encoding: .utf8)
        let path = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try "gitdir: \(gitDirectory)\n".write(toFile: path + "/.git", atomically: true, encoding: .utf8)
        return path
    }

    private func join(
        _ cwd: String,
        agent: ClaudeHookAgent = .claude,
        origin: ClaudeTransportOrigin = .localAuthenticated(peerUID: 501)
    ) -> ClaudeSessionSnapshot {
        var snapshot = ClaudeSessionSnapshot(sessionID: "s", origin: origin, agent: agent, firstSeen: clock.now())
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: cwd, origin: origin)
        return snapshot
    }

    private func proposer(
        _ runner: FakeRunner,
        store: FakeStore? = nil,
        files: [String] = ["README.md", "src/PageComposer.swift"],
        origin: ProjectRemote? = nil,
        usage: UsageLedger? = nil
    ) -> (ProjectTermProposer, FakeStore) {
        let store = store ?? FakeStore(now: clock.now)
        let proposer = ProjectTermProposer(
            store: store,
            runner: runner,
            now: clock.now,
            trackedFiles: { _ in files },
            origin: { _ in origin },
            usageRecorder: usage
        )
        return (proposer, store)
    }

    private func commit(
        _ proposer: ProjectTermProposer,
        _ snapshot: ClaudeSessionSnapshot?,
        enabled: Bool = true,
        excluding: [String] = []
    ) async {
        await proposer.dictationCommitted(join: snapshot, enabled: enabled, excluding: excluding)?.value
    }

    // MARK: From the joined session's own transcript (#1410)

    /// A hub whose one channel, for session `s`, answers every message with
    /// `reply` and records what it was asked.
    private func sessionHub(
        answering reply: @escaping @Sendable (String) -> ClaudeModChannelWire.Reply
    ) -> (ClaudeModChannelHub, Asked) {
        let hub = ClaudeModChannelHub(sleep: { _ in try? await Task.sleep(for: .seconds(60)) })
        let asked = Asked()
        _ = hub.attach(sessionID: "s", channel: .init(
            write: { line in
                guard let message = ClaudeModChannelWire.decode(
                    ClaudeModChannelWire.Message.self, from: line.dropLast()
                ) else { return false }
                asked.messages.withLock { $0.append(message) }
                hub.deliver(reply(message.id))
                return true
            },
            close: {}
        ))
        return (hub, asked)
    }

    /// What a session's mod was asked.
    private final class Asked: Sendable {
        let messages = Mutex<[ClaudeModChannelWire.Message]>([])
    }

    private func warmJoin(_ cwd: String, prompts: Int = 5, idleFor idle: TimeInterval = 30) -> ClaudeSessionSnapshot {
        var snapshot = join(cwd)
        snapshot.promptsSubmitted = prompts
        snapshot.lastActivity = clock.now().addingTimeInterval(-idle)
        return snapshot
    }

    func testAWarmSessionWithAModAnswersFromItsOwnTranscriptAndNoAgentRuns() async throws {
        let repo = try checkout("quillmark")
        let runner = FakeRunner(.terms(["from the agent"]))
        let (proposer, store) = proposer(runner)
        let usage = ClaudeModChannelWire.Usage(
            inputTokens: 9, cacheCreationInputTokens: 0, cacheReadInputTokens: 52_000, outputTokens: 40
        )
        let (hub, asked) = sessionHub {
            .init(
                sessionID: "s", id: $0, ok: true,
                text: #"{"terms": ["Inkwell"], "description": "A markdown editor."}"#, usage: usage
            )
        }
        proposer.attachSessionChannels(hub)

        await commit(proposer, warmJoin(repo))

        XCTAssertEqual(runner.count, 0, "the session answered, so no agent ran")
        XCTAssertEqual(asked.messages.withLock { $0.map(\.kind) }, [.terms])
        XCTAssertEqual(asked.messages.withLock { $0.first?.text }, ProjectTermProposal.forkPrompt)
        XCTAssertEqual(store.snapshot().unconfirmedProposals(projectKey: repo), ["Inkwell"])
    }

    /// Too young a session would pin a thin answer to the project, and a
    /// session idle past the prompt cache would pay for its whole
    /// transcript: both run the agent instead.
    func testAYoungOrColdSessionRunsTheAgentAndIsNotAsked() async throws {
        for (label, snapshot) in [
            ("young", warmJoin(try checkout("young"), prompts: ProjectTermProposal.minPromptsToFork - 1)),
            ("cold", warmJoin(try checkout("cold"), idleFor: ProjectTermProposal.forkCacheWindow + 1)),
        ] {
            let runner = FakeRunner(.terms(["from the agent"]))
            let (proposer, _) = proposer(runner)
            let (hub, asked) = sessionHub { .init(sessionID: "s", id: $0, ok: true, text: "{}") }
            proposer.attachSessionChannels(hub)

            await commit(proposer, snapshot)

            XCTAssertEqual(runner.count, 1, label)
            XCTAssertEqual(asked.messages.withLock(\.count), 0, label)
        }
    }

    func testASessionThatCannotAnswerFallsBackToTheAgent() async throws {
        let replies: [@Sendable (String) -> ClaudeModChannelWire.Reply] = [
            { (id: String) in ClaudeModChannelWire.Reply(sessionID: "s", id: id, ok: false, reason: "nothing-to-fork") },
            { (id: String) in ClaudeModChannelWire.Reply(sessionID: "s", id: id, ok: true, text: "I can't tell.") },
        ]
        for reply in replies {
            let repo = try checkout("quillmark-\(UUID().uuidString.prefix(4))")
            let runner = FakeRunner(.terms(["from the agent"]))
            let (proposer, store) = proposer(runner)
            let (hub, _) = sessionHub(answering: reply)
            proposer.attachSessionChannels(hub)

            await commit(proposer, warmJoin(repo))

            XCTAssertEqual(runner.count, 1)
            XCTAssertEqual(store.snapshot().unconfirmedProposals(projectKey: repo), ["from the agent"])
        }
    }

    func testTheForkAsksTheRunsQuestionWithoutReadingFiles() {
        XCTAssertNotEqual(ProjectTermProposal.forkPrompt, ProjectTermProposal.prompt, "the replaced sentence is still in the prompt")
        XCTAssertTrue(ProjectTermProposal.forkPrompt.contains("read no file"))
        XCTAssertFalse(ProjectTermProposal.forkPrompt.contains("Read at most six files"))
    }

    // MARK: Runs once

    func testALocalClaudeJoinInANewProjectRunsOnceInTheRepositoryRoot() async throws {
        let repo = try checkout("quillmark")
        let runner = FakeRunner(.terms(["inkwell", "qmk"]))
        let (proposer, store) = proposer(runner)

        await commit(proposer, join(repo + "/src"), excluding: ["qmk"])

        XCTAssertEqual(runner.invocations.withLock { $0 }, [
            ProjectTermProposal.Invocation(
                agent: .claude,
                workingDirectory: repo,
                arguments: ProjectTermProposal.claudeArguments()
            ),
        ])
        let memory = store.snapshot()
        XCTAssertEqual(memory.projects.map(\.key), [repo])
        XCTAssertEqual(memory.unconfirmedProposals(projectKey: repo), ["inkwell"])
        XCTAssertFalse(memory.needsProposal(projectKey: repo, now: clock.now()))
    }

    /// A new clone of an ignored repository has no record to say so; its
    /// `origin` does, and its agent is never asked (#1006).
    func testANewCloneOfAnIgnoredRepositoryAsksNoAgent() async throws {
        let repo = try checkout("quillmark")
        let runner = FakeRunner(.terms(["inkwell"]))
        let quill = try XCTUnwrap(ProjectRemote("github.com/me/quillmark"))
        let store = FakeStore(now: clock.now)
        store.memory.withLock {
            $0.ignoreProject(key: quill.key, name: "quillmark", keys: [], now: clock.now())
            // The dictation that joined recorded the clone before its origin was known.
            $0.record(
                [LearnedTermObservation(term: "Inkwell", source: .repository)],
                project: .init(key: repo, name: "quillmark"), now: clock.now())
        }
        let (proposer, _) = proposer(runner, store: store, origin: quill)

        await commit(proposer, join(repo + "/src"))

        XCTAssertEqual(runner.count, 0)
        XCTAssertTrue(store.snapshot().projects.isEmpty, "what the clone learned went")
        XCTAssertTrue(store.snapshot().ignored.contains(key: repo), "and its key is known from now on")
    }

    /// A first dictation in a new clone of an ignored repo that learned
    /// nothing, so it has no record (review, 2026-10-01): its key still joins
    /// the entry, and the clone learns nothing afterwards.
    func testANewCloneWithNoRecordJoinsItsIgnoredEntry() async throws {
        let repo = try checkout("quillmark")
        let runner = FakeRunner(.terms(["inkwell"]))
        let quill = try XCTUnwrap(ProjectRemote("github.com/me/quillmark"))
        let store = LearnedTermStore(fileURL: nil, now: clock.now)
        store.ignoreProject(key: quill.key, name: "quillmark", keys: [])
        // The ignore lands on the store's queue; the proposer reads the
        // snapshot from its own task and could otherwise run first.
        store.waitForPendingWrites()
        let proposer = ProjectTermProposer(
            store: store, runner: runner, now: clock.now, trackedFiles: { _ in [] }, origin: { _ in quill },
            usageRecorder: nil)

        await commit(proposer, join(repo + "/src"))
        store.waitForPendingWrites()

        XCTAssertEqual(runner.count, 0)
        XCTAssertTrue(store.snapshot().ignored.contains(key: repo), "its key is known from now on")
        store.record(
            [LearnedTermObservation(term: "Inkwell", source: .repository)],
            project: .init(key: repo, name: "quillmark"))
        store.waitForPendingWrites()
        XCTAssertTrue(store.snapshot().projects.isEmpty, "the clone learns nothing")
    }

    /// Until the launch load lands, the store cannot tell which repos are
    /// ignored; a dictation then asks no agent (review, 2026-09-29).
    func testADictationBeforeTheLaunchLoadAsksNoAgent() async throws {
        let repo = try checkout("quillmark")
        let fileURL = root.appendingPathComponent("support/learned-terms.json")
        let seeded = LearnedTermStore(fileURL: fileURL, now: clock.now)
        seeded.ignoreProject(key: repo, name: "quillmark", keys: [])
        seeded.waitForPendingWrites()
        let launch = DispatchSemaphore(value: 0)
        let store = LearnedTermStore(fileURL: fileURL, now: clock.now, beforeLaunchLoad: { launch.wait() })
        let runner = FakeRunner(.terms(["inkwell"]))
        let proposer = ProjectTermProposer(
            store: store, runner: runner, now: clock.now, trackedFiles: { _ in [] }, origin: { _ in nil },
            usageRecorder: nil)

        await commit(proposer, join(repo))
        launch.signal()
        store.waitForPendingWrites()
        XCTAssertEqual(runner.count, 0)

        await commit(proposer, join(try checkout("inkwell")))
        XCTAssertEqual(runner.count, 1, "once loaded, a repo nobody ignored is asked")
    }

    func testASecondDictationDoesNotRunAgain() async throws {
        let repo = try checkout("quillmark")
        let runner = FakeRunner(.terms(["inkwell"]))
        let (proposer, _) = proposer(runner)

        await commit(proposer, join(repo))
        await commit(proposer, join(repo + "/src"))

        XCTAssertEqual(runner.count, 1)
    }

    /// The store's stamp lands on its own queue in the app; a dictation
    /// right behind the first must not start a second run meanwhile.
    func testADictationWhileTheFirstRunIsPendingDoesNotRunAgain() async throws {
        let repo = try checkout("quillmark")
        let runner = FakeRunner(.terms(["inkwell"]))
        let lagging = FakeStore(now: clock.now)
        let (proposer, _) = proposer(runner, store: lagging)

        let first = proposer.dictationCommitted(join: join(repo), enabled: true, excluding: [])
        let second = proposer.dictationCommitted(join: join(repo), enabled: true, excluding: [])
        await first?.value
        await second?.value

        XCTAssertEqual(runner.count, 1)
    }

    func testEveryWorktreeOfARepositoryIsOneProject() async throws {
        let main = try checkout("quillmark")
        let linked = try worktree(of: main, named: "quillmark-feature")
        let runner = FakeRunner(.terms(["inkwell"]))
        let (proposer, store) = proposer(runner)

        await commit(proposer, join(linked))
        await commit(proposer, join(main))

        XCTAssertEqual(runner.count, 1)
        XCTAssertEqual(runner.invocations.withLock { $0.first?.workingDirectory }, linked)
        XCTAssertEqual(store.snapshot().projects.map(\.key), [main])
    }

    // MARK: Vibe

    func testALocalVibeJoinRunsVibeWithTheTrackedFiles() async throws {
        let repo = try checkout("quillmark")
        let runner = FakeRunner(.terms(["inkwell"]))
        let (proposer, store) = proposer(runner, files: ["README.md", "src/PageComposer.swift"])

        await commit(proposer, join(repo, agent: .vibe))

        XCTAssertEqual(runner.invocations.withLock { $0 }, [
            ProjectTermProposal.Invocation(
                agent: .vibe,
                workingDirectory: repo,
                arguments: ProjectTermProposal.vibeArguments(trackedFiles: ["README.md", "src/PageComposer.swift"])
            ),
        ])
        XCTAssertEqual(store.snapshot().projects.first?.terms.first?.sources, ["agent:vibe"])
    }

    /// One stamp per project, whichever agent joins first.
    func testAVibeJoinDoesNotAskAgainAfterClaudeAnswered() async throws {
        let repo = try checkout("quillmark")
        let runner = FakeRunner(.terms(["inkwell"]))
        let store = FakeStore(now: clock.now)
        store.recordProposal(
            ["inkwell"], line: "Quillmark renders Markdown to PDF.", revision: ProjectTermProposal.promptRevision,
            agent: .claude,
            project: LearnedTermProjectIdentity(key: repo, name: "quillmark"), excluding: []
        )
        let (proposer, _) = proposer(runner, store: store)

        await commit(proposer, join(repo, agent: .vibe))

        XCTAssertEqual(runner.count, 0)
    }

    // MARK: opencode

    /// From a subdirectory, the run's `--dir` and working directory are both
    /// the repository root, and it needs no file list.
    func testALocalOpencodeJoinRunsOpencodeInTheRepositoryRoot() async throws {
        let repo = try checkout("quillmark")
        let runner = FakeRunner(.terms(["inkwell"]))
        let (proposer, store) = proposer(runner)

        await commit(proposer, join(repo + "/src", agent: .opencode))

        XCTAssertEqual(runner.invocations.withLock { $0 }, [
            ProjectTermProposal.Invocation(
                agent: .opencode,
                workingDirectory: repo,
                arguments: ProjectTermProposal.opencodeArguments(workingDirectory: repo),
                environment: ProjectTermProposal.opencodeEnvironment
            ),
        ])
        XCTAssertEqual(store.snapshot().projects.first?.terms.first?.sources, ["agent:opencode"])
        XCTAssertEqual(store.snapshot().projects.first?.terms.first?.isUnconfirmedProposal, true)
        XCTAssertEqual(store.snapshot().unconfirmedProposals(projectKey: repo), ["inkwell"])

        await commit(proposer, join(repo, agent: .opencode))
        await commit(proposer, join(repo, agent: .claude))
        XCTAssertEqual(runner.count, 1, "one ask per project, whichever agent joins next")
    }

    // MARK: Does not run

    func testNothingRunsWithoutALocalJoinOrWithTheSettingOff() async throws {
        let repo = try checkout("quillmark")
        let runner = FakeRunner(.terms(["inkwell"]))
        let (proposer, _) = proposer(runner)

        XCTAssertNil(proposer.dictationCommitted(join: nil, enabled: true, excluding: []))
        XCTAssertNil(proposer.dictationCommitted(
            join: join(repo, agent: .opencode, origin: .remote(channel: "ssh")), enabled: true, excluding: []
        ))
        XCTAssertNil(proposer.dictationCommitted(
            join: join(repo, origin: .remote(channel: "ssh")), enabled: true, excluding: []
        ))
        XCTAssertNil(proposer.dictationCommitted(
            join: join(repo, agent: .vibe, origin: .remote(channel: "ssh")), enabled: true, excluding: []
        ))
        XCTAssertNil(proposer.dictationCommitted(join: join(repo), enabled: false, excluding: []))
        XCTAssertEqual(runner.count, 0)
    }

    // MARK: Failure

    func testAFailureIsRetriedAfterADayNotBefore() async throws {
        let repo = try checkout("quillmark")
        let failing = FakeRunner(.failed(.timedOut))
        let store = FakeStore(now: clock.now)
        let (first, _) = proposer(failing, store: store)

        await commit(first, join(repo))
        XCTAssertEqual(failing.count, 1)
        XCTAssertEqual(store.snapshot().projects.first?.proposalAttemptedAt, clock.now())
        XCTAssertNil(store.snapshot().projects.first?.proposedAt)

        clock.advance(3600)
        await commit(first, join(repo))
        XCTAssertEqual(failing.count, 1)

        // A relaunch reads the attempt time from the store.
        let answering = FakeRunner(.terms(["inkwell"]))
        let (relaunched, _) = proposer(answering, store: store)
        await commit(relaunched, join(repo))
        XCTAssertEqual(answering.count, 0)

        clock.advance(ProjectTermProposal.retryAfter)
        await commit(relaunched, join(repo))
        XCTAssertEqual(answering.count, 1)
        XCTAssertEqual(store.snapshot().unconfirmedProposals(projectKey: repo), ["inkwell"])
    }

    // MARK: Usage

    func testEveryRunThatStartedIsChargedToProjectTermsWithWhatItReported() async throws {
        let reported = ProjectTermProposal.Usage(
            turns: 5, costUSD: 0.09, inputTokens: 12, cacheWriteTokens: 20_000,
            cacheReadTokens: 25_000, outputTokens: 900)
        let cases: [(ProjectTermProposal.Outcome, [UsageEntry])] = [
            (.terms(["inkwell"], usage: reported), [UsageEntry(
                date: clock.now(), feature: .projectTerms, backend: .claudeCode, model: "sonnet",
                promptTokens: 45_012, cachedPromptTokens: 25_000, completionTokens: 900, agentCostUSD: 0.09)]),
            (.failed(.budgetExceeded), [UsageEntry(
                date: clock.now(), feature: .projectTerms, backend: .claudeCode, model: "sonnet")]),
            (.failed(.agentNotFound), []),
            (.failed(.launchFailed), []),
        ]
        for (index, (outcome, expected)) in cases.enumerated() {
            let repo = try checkout("usage-\(index)")
            let usage = UsageLedger(fileURL: nil)
            let (proposer, _) = proposer(FakeRunner(outcome), usage: usage)

            await commit(proposer, join(repo))

            XCTAssertEqual(usage.entries(), expected, "\(outcome)")
        }
    }

    func testADirectoryOutsideARepositoryIsItsOwnProject() async throws {
        let plain = root.appendingPathComponent("notes").path
        try FileManager.default.createDirectory(atPath: plain + "/drafts", withIntermediateDirectories: true)
        for name in ["plan.md", "inkwell.txt", ".hidden"] {
            try "x".write(toFile: plain + "/" + name, atomically: true, encoding: .utf8)
        }
        let runner = FakeRunner(.terms([]))
        let (proposer, store) = proposer(runner)

        await commit(proposer, join(plain, agent: .vibe))

        // No git: the directory's visible files stand in for the tracked list.
        XCTAssertEqual(runner.invocations.withLock { $0.first }, ProjectTermProposal.Invocation(
            agent: .vibe, workingDirectory: plain,
            arguments: ProjectTermProposal.vibeArguments(trackedFiles: ["inkwell.txt", "plan.md"])
        ))
        XCTAssertEqual(store.snapshot().projects.map(\.key), [plain])
    }
}
