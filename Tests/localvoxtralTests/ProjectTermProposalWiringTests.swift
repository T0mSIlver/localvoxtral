import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// Which committed dictations ask the project's agent for its terms (#609).
/// The rules of the proposer are `ProjectTermProposerTests`' subject (Linux);
/// what is pinned here is the commit path handing it the join, once the text
/// is inserted, and only then.
@MainActor
final class ProjectTermProposalWiringTests: XCTestCase {
    /// Records each run, and how many commits had reached the overlay when
    /// it started.
    private final class FakeRunner: ProjectTermProposalRunning, @unchecked Sendable {
        struct Run: Equatable {
            let invocation: ProjectTermProposal.Invocation
            let commitsBeforeRun: Int
        }

        let runs = Mutex<[Run]>([])
        let commits: @MainActor () -> Int

        init(commits: @escaping @MainActor () -> Int) { self.commits = commits }

        func run(_ invocation: ProjectTermProposal.Invocation) async -> ProjectTermProposal.Outcome {
            let commits = await MainActor.run { self.commits() }
            runs.withLock { $0.append(Run(invocation: invocation, commitsBeforeRun: commits)) }
            return .terms(["inkwell"])
        }

        var all: [Run] { runs.withLock { $0 } }
    }

    private static let projectDirectory = "/nonexistent-609/quillmark"

    private struct Harness {
        let viewModel: DictationViewModel
        let overlay: MockOverlayCoordinator
        let runner: FakeRunner
        let store: LearnedTermStore
    }

    private func makeHarness(polish: Bool = true, enabled: Bool = true) -> Harness {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = polish
        settings.agentPolishProfileEnabled = false
        settings.polishingBackendMode = .externalURL
        settings.llmPolishingEndpointURL = "http://127.0.0.1:8472/v1/chat/completions"
        settings.projectTermProposalsEnabled = enabled

        let template = LLMPromptTemplates(
            systemContent: "system",
            userContent: "Clean this up.\n{{replacement_dictionary}}\nWorking text:\n{{input_text}}"
        )
        let overlay = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlay,
            startRuntimeServices: false
        )
        let clock = ManualSessionClock()
        viewModel.dependencies.clock = clock.clock
        viewModel.appConfigStore = MockAppConfigStore(promptTemplates: template, agentPromptTemplates: template)
        viewModel.llmPolishingService = FakePolishingService()
        viewModel.stubCommitTarget { "com.apple.Terminal" }
        viewModel.dependencies.repoVocabularyGrounding = FakeRepoVocabularyGrounding(outcome: nil)
        let store = LearnedTermStore(fileURL: nil, now: clock.clock.now)
        viewModel.learnedTermStore = store
        let runner = FakeRunner(commits: { overlay.commitCallCount })
        viewModel.session.projectTermProposer = ProjectTermProposer(
            store: store,
            runner: runner,
            now: clock.clock.now,
            trackedFiles: { _ in ["README.md"] }
        )
        retainForTestProcessLifetime(viewModel)
        return Harness(viewModel: viewModel, overlay: overlay, runner: runner, store: store)
    }

    private func join(
        agent: ClaudeHookAgent = .claude,
        origin: ClaudeTransportOrigin = .localAuthenticated(peerUID: 501)
    ) -> ClaudeSessionJoin {
        var snapshot = ClaudeSessionSnapshot(
            sessionID: "s1", origin: origin, agent: agent, firstSeen: Date(timeIntervalSince1970: 0)
        )
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: Self.projectDirectory, origin: origin)
        return ClaudeSessionJoin(
            target: TerminalScreenTarget(pid: 4242, bundleID: "com.apple.Terminal"),
            snapshot: snapshot,
            windowID: 101,
            mechanism: .ttyDevice
        )
    }

    /// One stopped Overlay Buffer dictation with `join`, awaited through its
    /// commit and the proposal it started.
    private func dictate(_ harness: Harness, join: ClaudeSessionJoin?) async {
        let viewModel = harness.viewModel
        viewModel.session.projectTermProposalTask = nil
        viewModel.session.context.claudeSessionJoin = join
        viewModel.session.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.transcript.currentDictationEventText = "rename the page composer struct"
        viewModel.session.finishStoppedSession(promotePendingSegment: false)
        await awaitStoppedSessionCommit(viewModel)
        await viewModel.session.projectTermProposalTask?.value
        harness.store.waitForPendingWrites()
    }

    func testAJoinedClaudeDictationAsksOnceAfterItsTextIsInserted() async {
        let harness = makeHarness()
        await dictate(harness, join: join())

        XCTAssertEqual(harness.runner.all, [
            FakeRunner.Run(
                invocation: ProjectTermProposal.Invocation(
                    agent: .claude,
                    workingDirectory: Self.projectDirectory,
                    arguments: ProjectTermProposal.claudeArguments()
                ),
                commitsBeforeRun: 1
            ),
        ])
        XCTAssertEqual(
            harness.store.snapshot().unconfirmedProposals(projectKey: Self.projectDirectory),
            ["inkwell"]
        )

        await dictate(harness, join: join())
        XCTAssertEqual(harness.runner.all.count, 1, "a second dictation in the project asks nothing")
    }

    func testAJoinedVibeDictationAsksVibe() async {
        let harness = makeHarness()
        await dictate(harness, join: join(agent: .vibe))
        XCTAssertEqual(harness.runner.all.map(\.invocation.agent), [.vibe])
        XCTAssertEqual(harness.runner.all.first?.invocation.arguments, ProjectTermProposal.vibeArguments(trackedFiles: []))
    }

    /// Without polish the commit takes the other path; it asks too.
    func testAnUnpolishedJoinedDictationAsks() async {
        let harness = makeHarness(polish: false)
        await dictate(harness, join: join())
        XCTAssertEqual(harness.runner.all.map(\.commitsBeforeRun), [1])
    }

    func testNothingAsksForARemoteOpencodeOrMissingJoinOrWithTheSettingOff() async {
        let harness = makeHarness()
        await dictate(harness, join: join(origin: .remote(channel: "ssh")))
        await dictate(harness, join: join(agent: .vibe, origin: .remote(channel: "ssh")))
        await dictate(harness, join: join(agent: .opencode))
        await dictate(harness, join: nil)
        XCTAssertEqual(harness.runner.all, [])

        let off = makeHarness(enabled: false)
        await dictate(off, join: join())
        XCTAssertEqual(off.runner.all, [])
    }

    func testAFailedInsertAsksNothing() async {
        let harness = makeHarness()
        harness.overlay.commitOutcome = .failed(message: "Insert failed.")
        await dictate(harness, join: join())
        XCTAssertEqual(harness.runner.all, [])
    }
}
