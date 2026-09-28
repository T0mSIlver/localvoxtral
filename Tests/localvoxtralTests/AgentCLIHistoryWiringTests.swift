import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

/// The `localvoxtral` command against the app (#721): the commit path records
/// which session a dictation joined, and the app's data source answers from
/// the real history store and learned terms. The service's rules are
/// `AgentCLIServiceTests`' subject (Linux).
@MainActor
final class AgentCLIHistoryWiringTests: XCTestCase {
    private nonisolated static let projectDirectory = "/nonexistent-721/quillmark"

    private func makeViewModel(
        polish: Bool,
        outputMode: DictationOutputMode = .overlayBuffer,
        retention: DictationHistoryRetention = .forever
    ) throws -> (DictationViewModel, DictationSessionStore) {
        let settings = makeSettings(outputMode: outputMode)
        settings.llmPolishingEnabled = polish
        settings.agentPolishProfileEnabled = false
        settings.polishingBackendMode = .externalURL
        settings.llmPolishingEndpointURL = "http://127.0.0.1:8472/v1/chat/completions"
        settings.dictationHistoryRetention = retention
        let template = LLMPromptTemplates(
            systemContent: "system",
            userContent: "Clean this up.\n{{replacement_dictionary}}\nWorking text:\n{{input_text}}"
        )
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.dependencies.clock = ManualSessionClock().clock
        viewModel.appConfigStore = MockAppConfigStore(promptTemplates: template, agentPromptTemplates: template)
        viewModel.llmPolishingService = FakePolishingService()
        viewModel.stubCommitTarget { "com.apple.Terminal" }
        viewModel.dependencies.repoVocabularyGrounding = FakeRepoVocabularyGrounding(outcome: nil)
        let store = try XCTUnwrap(DictationSessionStore(inMemory: true))
        viewModel.sessionStore = store
        viewModel.learnedTermStore = LearnedTermStore(fileURL: nil)
        retainForTestProcessLifetime(viewModel)
        return (viewModel, store)
    }

    private func join(origin: ClaudeTransportOrigin = .localAuthenticated(peerUID: 501)) -> ClaudeSessionJoin {
        var snapshot = ClaudeSessionSnapshot(
            sessionID: "s1", origin: origin, agent: .vibe, firstSeen: Date(timeIntervalSince1970: 0)
        )
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: Self.projectDirectory, origin: origin)
        return ClaudeSessionJoin(
            target: TerminalScreenTarget(pid: 4242, bundleID: "com.apple.Terminal"),
            snapshot: snapshot,
            windowID: 101,
            mechanism: .ttyDevice
        )
    }

    private func dictate(_ viewModel: DictationViewModel, join: ClaudeSessionJoin?, text: String) async {
        viewModel.session.context.claudeSessionJoin = join
        viewModel.session.sessionOutputMode = viewModel.settings.dictationOutputMode
        viewModel.isFinalizingStop = true
        viewModel.transcript.currentDictationEventText = text
        viewModel.session.finishStoppedSession(promotePendingSegment: false)
        await awaitStoppedSessionCommit(viewModel)
    }

    /// Every commit path records the join: polished, unpolished, and Live
    /// Auto-Paste, each of which reads the join at a different moment.
    func testEachCommitPathRecordsTheJoinedProjectAndAgent() async throws {
        for (polish, mode) in [(true, DictationOutputMode.overlayBuffer), (false, .overlayBuffer), (false, .liveAutoPaste)] {
            let (viewModel, store) = try makeViewModel(polish: polish, outputMode: mode)
            await dictate(viewModel, join: join(), text: "the mac queue is stuck")
            let entry = await store.entries().first
            XCTAssertEqual(entry?.projectKey, Self.projectDirectory, "polish \(polish), \(mode)")
            XCTAssertEqual(entry?.projectName, "quillmark", "polish \(polish), \(mode)")
            XCTAssertEqual(entry?.joinedAgent, "vibe", "polish \(polish), \(mode)")
            XCTAssertEqual(
                viewModel.session.lastDictationJoin,
                AgentCLIJoin(
                    agent: "vibe",
                    project: AgentCLIProject(key: Self.projectDirectory, name: "quillmark"),
                    mechanism: "tty",
                    remote: false
                ),
                "polish \(polish), \(mode)"
            )
        }
    }

    func testARemoteJoinRecordsItsLabelAndADictationWithNoJoinRecordsNone() async throws {
        let (viewModel, store) = try makeViewModel(polish: false)
        await dictate(viewModel, join: join(origin: .remote(channel: "ssh")), text: "first")
        await dictate(viewModel, join: nil, text: "second")
        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.projectKey), [nil, "remote:quillmark"])
        XCTAssertNil(viewModel.session.lastDictationJoin)
    }

    /// The data source reads the real store: search, `history last` for a
    /// dictation that was never inserted, and nothing under "Don't keep".
    func testTheDataSourceAnswersFromTheHistoryStore() async throws {
        let (viewModel, store) = try makeViewModel(polish: false)
        store.save(DictationSessionRecord(
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_790_000_005),
            rawText: "the Mac queue is stuck", provider: "p", model: "m", outputMode: "overlay_buffer",
            targetAppBundleID: "com.mitchellh.ghostty", status: .sttCompleted, commitSucceeded: false,
            projectKey: Self.projectDirectory, projectName: "quillmark", joinedAgent: "claude"))
        let service = AgentCLIService(source: AgentCLIAppDataSource(viewModel: viewModel)) { _ in nil }

        let search = await service.respond(to: AgentCLIRequest(command: .historySearch, text: "mac QUEUE"))
        XCTAssertEqual(search.history?.dictations.map(\.rawText), ["the Mac queue is stuck"])
        let last = await service.respond(to: AgentCLIRequest(command: .historyLast))
        XCTAssertEqual(
            last.history?.dictations.first,
            AgentCLIDictation(
                id: try XCTUnwrap(last.history?.dictations.first?.id),
                startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_790_000_005),
                project: AgentCLIProject(key: Self.projectDirectory, name: "quillmark"),
                agent: "claude",
                targetApp: "com.mitchellh.ghostty",
                rawText: "the Mac queue is stuck",
                finalText: "the Mac queue is stuck",
                inserted: false,
                status: "stt_completed"
            )
        )

        viewModel.settings.dictationHistoryRetention = .off
        let off = await service.respond(to: AgentCLIRequest(command: .historySearch, text: "queue"))
        XCTAssertEqual(off.history, AgentCLIHistory(historyKept: false, dictations: []))
        XCTAssertTrue(off.ok)
    }

    /// A proposal from the command reaches the learned-term store as an
    /// unconfirmed proposal, and the review list names its agent.
    func testAProposalFromTheCommandLandsForReview() async throws {
        let (viewModel, _) = try makeViewModel(polish: false)
        viewModel.settings.polishSpeakerTerms = ["Voxtral"]
        let service = AgentCLIService(source: AgentCLIAppDataSource(viewModel: viewModel)) { _ in
            LearnedTermProjectIdentity(key: Self.projectDirectory, name: "quillmark")
        }
        let response = await service.respond(to: AgentCLIRequest(
            command: .termsPropose, project: Self.projectDirectory, terms: ["Featherline", "voxtral"], caller: .codex))
        XCTAssertEqual(response.proposal?.added, ["Featherline"])
        XCTAssertEqual(response.proposal?.skipped.map(\.reason), [.userList])

        let term = try XCTUnwrap(viewModel.learnedTermStore?.snapshot().projects.first?.terms.first)
        XCTAssertTrue(term.isUnconfirmedProposal)
        XCTAssertEqual(
            LearnedTermsSheet.detailParts(for: term).text,
            "Proposed by Codex: heard in 0 of 3 dictations"
        )
    }
}
