import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

/// What a Claude Desktop join changes in the stop-commit's polish (#661): the
/// agent profile, and the joined local session's workspace as the repository
/// the vocabulary lookup reads.
@MainActor
final class DesktopSessionPolishTests: XCTestCase {
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let remote = ClaudeTransportOrigin.remote(channel: "ssh:host-a")
    private let desktop = TerminalScreenTarget(pid: 6060, bundleID: ClaudeDesktopAllowlist.bundleID)
    private let desktopID = "local_fb53459c-6a7b-43b1-a326-52258b970501"

    // MARK: - Profile

    func testADesktopSessionJoinSelectsTheAgentProfile() async throws {
        let join = try await desktopJoin(origin: local)
        let run = await runCommit(join: join)

        XCTAssertEqual(run.appConfigStore.requestedProfiles, [.agent])
        XCTAssertEqual(run.record?.polishProfile, "agent")
    }

    /// Claude Desktop runs the session on an ssh host: still a coding agent.
    func testARemoteDesktopSessionJoinSelectsTheAgentProfile() async throws {
        let join = try await desktopJoin(origin: remote)
        let run = await runCommit(join: join)

        XCTAssertEqual(run.appConfigStore.requestedProfiles, [.agent])
        XCTAssertEqual(run.record?.polishProfile, "agent")
    }

    /// The same app hosts plain chat: without a join, nothing says the
    /// dictation goes to a coding agent.
    func testClaudeDesktopWithoutAJoinKeepsTheStandardProfile() async {
        let run = await runCommit(join: nil)

        XCTAssertEqual(run.appConfigStore.requestedProfiles, [.standard])
        XCTAssertEqual(run.record?.polishProfile, "standard")
    }

    func testTheAgentProfileToggleStillWinsOverADesktopJoin() async throws {
        let join = try await desktopJoin(origin: local)
        let run = await runCommit(join: join, agentProfileEnabled: false)

        XCTAssertEqual(run.appConfigStore.requestedProfiles, [.standard])
        XCTAssertEqual(run.record?.polishProfile, "standard")
    }

    // MARK: - Vocabulary

    func testALocalJoinHandsItsWorkspaceToTheVocabularyLookup() async throws {
        let join = try await desktopJoin(origin: local)
        let run = await runCommit(join: join, repoVocabularyEnabled: true)

        XCTAssertEqual(run.grounding.joinedWorkspaces, ["/repo"])
    }

    /// A remote session's cwd names a directory on another machine: the
    /// lookup gets nothing to read and falls back to the target app.
    func testARemoteJoinHandsNoWorkspaceToTheVocabularyLookup() async throws {
        let join = try await desktopJoin(origin: remote)
        let run = await runCommit(join: join, repoVocabularyEnabled: true)

        XCTAssertEqual(run.grounding.joinedWorkspaces, [nil])
    }

    // MARK: - Harness

    private func desktopJoin(origin: ClaudeTransportOrigin) async throws -> ClaudeSessionJoin {
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 2_000_000) },
            isProcessAlive: { _ in true }
        )
        let isLocal = origin == local
        let record = ClaudeHookRecord(
            event: .sessionStart,
            sessionID: "s1",
            timestamp: 0,
            rawCwd: "/repo",
            prompt: nil,
            files: [],
            process: isLocal
                ? ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001, desktopSessionID: desktopID)
                : nil
        )
        if isLocal {
            XCTAssertNotNil(registry.ingest(record, origin: origin))
        } else {
            XCTAssertNotNil(registry.ingest(
                record,
                origin: origin,
                environment: ClaudeRemoteSessionEnvironment(desktopSessionID: desktopID)
            ))
        }
        let address = "https://claude.ai/epitaxy/\(desktopID)"
        let resolved = await ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in nil },
            focusedBrowserTabURL: { _ in nil },
            focusedDesktopSessionURL: { _ in address },
            focusedWindowID: { _ in nil }
        ).resolve(target: desktop)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .desktopSession, "precondition")
        return join
    }

    private struct CommitRun {
        let appConfigStore: MockAppConfigStore
        let grounding: FakeRepoVocabularyGrounding
        let record: DictationSessionRecord?
    }

    /// An Overlay Buffer stop-commit into Claude Desktop, driven through
    /// `finishStoppedSession` with the join `captureAtStart` would have left.
    private func runCommit(
        join: ClaudeSessionJoin?,
        agentProfileEnabled: Bool = true,
        repoVocabularyEnabled: Bool = false
    ) async -> CommitRun {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        // Loopback, so the vocabulary lookup's endpoint gate passes.
        settings.llmPolishingEndpointURL = "http://127.0.0.1:8080/v1/chat/completions"
        settings.agentPolishProfileEnabled = agentProfileEnabled
        settings.repoVocabularyEnabled = repoVocabularyEnabled

        let appConfigStore = MockAppConfigStore()
        let grounding = FakeRepoVocabularyGrounding(outcome: nil)
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = appConfigStore
        viewModel.llmPolishingService = FakePolishingService()
        viewModel.stubCommitTarget { ClaudeDesktopAllowlist.bundleID }
        viewModel.dependencies.repoVocabularyGrounding = grounding
        viewModel.context.claudeSessionJoin = join
        var record: DictationSessionRecord?
        viewModel.dependencies.onSessionRecord = { record = $0 }
        retainForTestProcessLifetime(viewModel)

        viewModel.session.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.transcript.currentDictationEventText = "run the tests dash dash filter auth"

        viewModel.session.finishStoppedSession(promotePendingSegment: false)
        await awaitStoppedSessionCommit(viewModel)
        return CommitRun(appConfigStore: appConfigStore, grounding: grounding, record: record)
    }
}
