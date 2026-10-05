import Foundation
import XCTest

import localvoxtralTestSupport
@testable import localvoxtral

/// The record store against the History store, which needs SwiftData. The
/// store's own rules run in the core suite, `DiagnosticRecordStoreTests`.
final class DiagnosticRecordHistorySweepTests: XCTestCase {
    /// Unique per test: the store's lock shared with other running copies
    /// is a file beside this folder, and test classes run in several
    /// processes at once.
    private let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("lvx-diagnostic-records-\(UUID().uuidString)", isDirectory: true)
    private var directory: URL { home.appendingPathComponent("diagnostic-records", isDirectory: true) }
    private let io = MemoryCaptureIO()
    private let clock = CaptureTestClock()

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func makeStore() -> DiagnosticRecordStore {
        let clock = self.clock
        return DiagnosticRecordStore(
            directoryURL: directory,
            io: io,
            directoryIO: io,
            now: { clock.now() }
        )
    }

    private func makeRecord() -> DiagnosticRecord {
        .storeFixture(capturedAt: clock.now())
    }

    /// The launch sweep keeps every record while the history holds no
    /// dictation: an empty store is one that lost its rows (#985).
    @MainActor
    func testTheLaunchSweepKeepsEveryRecordWhenTheHistoryIsEmpty() async throws {
        let store = makeStore()
        try store.write(makeRecord())
        try store.write(makeRecord())
        let history = try XCTUnwrap(DictationSessionStore.inMemory())
        history.diagnosticRecordStore = store
        await history.removeOrphanedAudio().value

        XCTAssertEqual(store.storedIDs().count, 2)
    }
}

/// The builder's half of withholding the prompt sent to the agent. The
/// redaction's own rules run in the core suite, `DiagnosticRecordRedactionTests`.
final class DiagnosticRecordBuilderRedactionTests: XCTestCase {
    /// The builder takes the prompt out before the record exists: nothing the
    /// store receives carries it.
    func testTheBuilderWithholdsThePromptItWasGiven() {
        let prompt = "Explain why the SIGPIPE killed the dogfood socket"
        var inputs = DiagnosticRecordInputs.minimal(context: "previous request to the agent: \(prompt)")
        inputs.withheldPrompt = prompt

        let record = DiagnosticRecordBuilder.build(id: UUID().uuidString, capturedAt: Date(), inputs: inputs)

        XCTAssertFalse(record.text.userPrompts.joined().contains("SIGPIPE killed"))
    }

    /// The unsent draft the session's mod read (#1406) leaves the record as
    /// the prior prompt does: behind its labels in the context, line by line
    /// on the screen, and out of every harvest.
    func testTheBuilderWithholdsThePromptDraft() throws {
        let draft = ClaudePromptDraft(
            sessionID: "s1", beforeCursor: "rename the QuokkaLedger table\nand then", afterCursor: " migrate it"
        )
        let context = ClaudeSessionContextText.text(
            for: ClaudeSessionSnapshot(
                sessionID: "s1", origin: .localAuthenticated(peerUID: 501), agent: .claude,
                firstSeen: Date(timeIntervalSince1970: 0)
            ),
            draft: draft
        )
        var inputs = DiagnosticRecordInputs.minimal(context: context)
        inputs.screenDecision = .render(
            excerpt: "> rename the QuokkaLedger table\nand then migrate it", startText: "", elidedChurnLines: 0
        )
        inputs.withheldDraft = draft

        let record = DiagnosticRecordBuilder.build(id: UUID().uuidString, capturedAt: Date(), inputs: inputs)

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(record), encoding: .utf8))
        XCTAssertFalse(encoded.contains("QuokkaLedger"), encoded)
        XCTAssertFalse(encoded.contains("migrate it"), encoded)
        XCTAssertTrue(encoded.contains(DiagnosticRecordRedaction.withheldDraftPlaceholder))
        XCTAssertEqual(record.text.rawTranscript, "why did it crash")
    }

    /// A source's harvest is re-derived from its text, so it would keep the
    /// prompt's identifiers while the excerpts beside it read withheld.
    /// Terms the rest of the text holds stay.
    func testTheBuilderHarvestsNoTermOnlyThePriorPromptHeld() {
        let prompt = "fix the UserProfileCache race"
        let context = "previous request to the agent: \(prompt)\n\nfiles the agent recently touched:\nSessionRouter.swift (edit)"
        var inputs = DiagnosticRecordInputs.minimal(context: context)
        inputs.screenDecision = .render(excerpt: "> \(prompt)\nDone", startText: "> \(prompt)\nDone", elidedChurnLines: 0)
        inputs.clipboardRetainedText = "\(prompt)\nSessionRouter"
        inputs.withheldPrompt = prompt

        let record = DiagnosticRecordBuilder.build(id: UUID().uuidString, capturedAt: Date(), inputs: inputs)

        XCTAssertEqual(record.sources.map(\.source), ["terminal", "claude", "clipboard"])
        for source in record.sources {
            XCTAssertFalse(source.harvest.contains { $0.contains("UserProfileCache") }, "\(source.source): \(source.harvest)")
        }
        for source in record.sources.dropFirst() {
            XCTAssertTrue(source.harvest.contains { $0.contains("SessionRouter") }, "\(source.source): \(source.harvest)")
        }
    }
}

private extension DiagnosticRecordInputs {
    /// Inputs for a dictation whose only context is the joined session's
    /// `context`, rendered into the user prompt as sent.
    static func minimal(context: String) -> DiagnosticRecordInputs {
        DiagnosticRecordInputs(
            session: .init(outputMode: "overlayBuffer"),
            join: nil,
            joinAbstentions: [],
            screenDecision: .drop(reason: .targetChanged),
            socketPaneSwapApplied: false,
            targetBundleID: nil,
            demands: [.claude: context.count],
            grants: [.claude: context.count],
            rendered: [.claude: context.count],
            repoVocabularyHarvest: nil,
            repoVocabularyOutcome: .empty,
            claudeRepoSnapshot: nil,
            claudeRepoOutcome: .empty,
            claudeRepoRenderedExcerpt: nil,
            claudeSessionText: context,
            claudeSessionOutcome: .empty,
            claudeSessionRenderedExcerpt: context,
            clipboardRetainedText: nil,
            clipboardOutcome: .empty,
            clipboardRenderedExcerpt: nil,
            screenOutcome: .empty,
            screenRenderedExcerpt: nil,
            text: .init(
                rawTranscript: "why did it crash",
                workingText: "why did it crash",
                groundedText: "why did it crash",
                systemPrompt: "system",
                userPrompts: ["Context:\n\(context)\n\nWorking text:\nwhy did it crash"],
                polishedOutput: nil,
                committedText: nil
            )
        )
    }
}
