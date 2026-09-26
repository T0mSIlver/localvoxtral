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
            _ terms: [String],
            agent: ProjectTermProposal.Agent,
            project: LearnedTermProjectIdentity,
            excluding: [String]
        ) {
            let moment = now()
            memory.withLock { $0.recordProposal(terms, agent: agent, project: project, excluding: excluding, now: moment) }
        }

        func recordProposalFailure(project: LearnedTermProjectIdentity) {
            let moment = now()
            memory.withLock { $0.recordProposalFailure(project: project, now: moment) }
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
        files: [String] = ["README.md", "src/PageComposer.swift"]
    ) -> (ProjectTermProposer, FakeStore) {
        let store = store ?? FakeStore(now: clock.now)
        let proposer = ProjectTermProposer(
            store: store,
            runner: runner,
            now: clock.now,
            trackedFiles: { _ in files }
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
            ["inkwell"], agent: .claude,
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
