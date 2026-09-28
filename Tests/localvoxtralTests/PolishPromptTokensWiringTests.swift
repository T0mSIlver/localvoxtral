import Foundation
import Synchronization
import XCTest
import localvoxtralTestSupport
@testable import localvoxtral

/// A polished dictation keeps the prompt tokens its request sent, as the
/// backend reported them, and History's details line shows them (#1007).
@MainActor
final class PolishPromptTokensWiringTests: XCTestCase {
    private func dictate(usage: LLMTokenUsage?) async throws -> DictationHistoryEntry? {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.agentPolishProfileEnabled = false
        settings.polishingBackendMode = .externalURL
        settings.llmPolishingEndpointURL = "http://127.0.0.1:8472/v1/chat/completions"
        settings.dictationHistoryRetention = .forever
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
        viewModel.llmPolishingService = FakePolishingService(usage: usage) { _ in "The Mac queue is stuck." }
        viewModel.dependencies.repoVocabularyGrounding = FakeRepoVocabularyGrounding(outcome: nil)
        let store = try XCTUnwrap(DictationSessionStore(inMemory: true))
        viewModel.sessionStore = store
        viewModel.learnedTermStore = LearnedTermStore(fileURL: nil)
        retainForTestProcessLifetime(viewModel)

        viewModel.session.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.transcript.currentDictationEventText = "the mac queue is stuck"
        viewModel.session.finishStoppedSession(promotePendingSegment: false)
        await awaitStoppedSessionCommit(viewModel)
        return await store.entries().first
    }

    func testAPolishedDictationKeepsTheReportedPromptTokens() async throws {
        let entry = try await dictate(usage: LLMTokenUsage(model: nil, promptTokens: 1_949, completionTokens: 12))

        XCTAssertEqual(entry?.polishPromptTokens, 1_949)
        XCTAssertEqual(
            entry.map(DictationHistoryRowText.details(for:))?.hasSuffix(" · \(1_949.formatted()) prompt tokens"), true,
            entry.map(DictationHistoryRowText.details(for:)) ?? "no entry")
    }

    func testABackendThatReportsNoUsageShowsNoCount() async throws {
        let entry = try await dictate(usage: nil)

        XCTAssertNotNil(entry?.polishedText)
        XCTAssertNil(entry?.polishPromptTokens)
        XCTAssertEqual(entry.map(DictationHistoryRowText.details(for:))?.contains("tokens"), false)
    }

    // MARK: - Settings' counts

    private let ratio = PolishPromptTokenRatio(tokensPerCharacter: 0.25, basis: .assumed)
    private let helper = URL(string: "http://127.0.0.1:1/v1/tokenize")!

    func testTheBundledHelperCountsExactly() async {
        StubHTTPProtocol.reply.withLock { $0 = .http(200, #"{"tokens":1229}"#) }
        let counter = PolishPromptTokenCounter(
            ratio: ratio, helperTokenizeURL: helper, session: StubHTTPProtocol.session())

        let count = await counter.count(String(repeating: "a", count: 400))

        XCTAssertEqual(count, .exact(1_229))
    }

    /// A helper that is down, or predates the route, answers nothing usable.
    func testAHelperWithoutTheRouteFallsBackToTheEstimate() async {
        StubHTTPProtocol.reply.withLock { $0 = .http(404, #"{"error":{"message":"not found"}}"#) }
        let counter = PolishPromptTokenCounter(
            ratio: ratio, helperTokenizeURL: helper, session: StubHTTPProtocol.session())

        let prose = await counter.count(String(repeating: "a", count: 400))
        let terms = await counter.count(String(repeating: "a", count: 400), termList: true)

        XCTAssertEqual(prose, .estimated(100))
        XCTAssertEqual(terms, .estimated(160))
    }

    func testACloudBackendIsEstimatedAndShownApproximately() async {
        let counter = PolishPromptTokenCounter(ratio: ratio, helperTokenizeURL: nil)

        let count = await counter.count(String(repeating: "a", count: 4_918))

        XCTAssertEqual(count, .estimated(1_230))
        XCTAssertEqual(
            PolishPromptTokenText.instructions(standard: count!, agent: .exact(1_758)),
            "≈ \(1_230.formatted()) · agent \(1_758.formatted()) tokens")
    }
}
