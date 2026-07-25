#if LOCALVOXTRAL_DOGFOOD

import AppKit
import Foundation
import XCTest
@testable import localvoxtral

/// The wiring that turns one polished dictation into one on-disk capture
/// record. Drives the REAL `finishStoppedSession` polish/commit path (the same
/// harness as the polish-failure diagnostics suite) and reads the record back.
@MainActor
final class DogfoodCaptureWiringTests: XCTestCase {
    // DictationViewModel owns app-lifetime services; retain test instances for
    // the process lifetime (mirrors the token-guard suite).
    private static var retainedViewModels: [DictationViewModel] = []

    /// Armed build + armed runtime flag: a polished overlay commit writes
    /// exactly one record whose text stages, session facts, join abstention,
    /// and screen decision describe the dictation that just committed.
    func testPolishedCommitWritesOneAttributableRecord() async throws {
        let harness = try makeHarness(dogfoodArmed: true)

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        let records = try recordsOnDisk(in: harness.captureDirectory)
        XCTAssertEqual(records.count, 1, "one dictation writes exactly one record")
        let record = records[0]

        XCTAssertEqual(record.schemaVersion, DogfoodCaptureRecord.currentSchemaVersion)
        XCTAssertFalse(record.flagged)

        // Text stages, in pipeline order.
        XCTAssertEqual(record.text.rawTranscript, "polish this text")
        XCTAssertEqual(record.text.workingText, "polish this text")
        XCTAssertEqual(record.text.groundedText, "polish this text")
        XCTAssertEqual(record.text.polishedOutput, "polished output text")
        XCTAssertEqual(record.text.committedText, "polished output text")
        XCTAssertFalse(record.text.userPrompts.isEmpty, "the rendered prompt is the payload")
        XCTAssertEqual(record.text.systemPrompt, "system")

        // Session facts.
        XCTAssertEqual(record.session.outputMode, DictationOutputMode.overlayBuffer.rawValue)
        XCTAssertEqual(record.session.endpointClass, "loopback")
        XCTAssertNotNil(record.session.promptProfile)
        XCTAssertNotNil(record.session.polishModel)

        // No session start ran, so no join was resolved: the record must say
        // "none" rather than omitting the block.
        XCTAssertEqual(record.join?.arm, "none")

        // No start capture: the decision is drop(no-start-capture), and the
        // record's screen block must carry that exact cause.
        XCTAssertEqual(record.screen?.decision, "drop")
        XCTAssertEqual(record.screen?.cause, "no-start-capture")

        // Nothing demanded, so no allocation rows and no sources.
        XCTAssertEqual(record.allocation, [])
        XCTAssertEqual(record.sources, [])

        // Timings: the polish duration came from the service; the capture
        // measured itself.
        XCTAssertEqual(record.timings.polishSeconds, 0.25)
        XCTAssertNotNil(record.timings.captureMilliseconds)
    }

    /// The compile flag alone must not collect: with the runtime opt-in off,
    /// the same commit writes nothing.
    func testDisarmedRuntimeFlagWritesNothing() async throws {
        let harness = try makeHarness(dogfoodArmed: false)

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: harness.captureDirectory.path),
            "a disarmed build must not even create the capture directory"
        )
    }

    /// A failing store must cost the record, never the commit: the dictation
    /// still commits and the session completes.
    func testCaptureWriteFailureDoesNotBreakTheCommit() async throws {
        // A file where the capture DIRECTORY should be: every write fails.
        let harness = try makeHarness(dogfoodArmed: true, blockCaptureDirectory: true)

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        XCTAssertFalse(harness.viewModel.isCompletingStoppedSession)
        XCTAssertEqual(
            harness.viewModel.currentDictationEventText, "polished output text",
            "the committed text must be unaffected by a capture-write failure"
        )
    }

    /// A join abstention noted at (a would-be) session start is consumed into
    /// the record; a second dictation does not inherit it.
    func testJoinAbstentionRidesTheRecordOnceAndIsConsumed() async throws {
        let harness = try makeHarness(dogfoodArmed: true)
        DogfoodCaptureTap.shared.beginSession()
        DogfoodCaptureTap.shared.noteJoinAbstention("tty: stale")
        DogfoodCaptureTap.shared.noteJoinAbstention("marker: no marker in title")

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        let first = try recordsOnDisk(in: harness.captureDirectory)
        XCTAssertEqual(
            first.last?.join?.abstentionReason,
            "tty: stale; marker: no marker in title"
        )

        // A second commit on a fresh session must not repeat the reason.
        let second = try makeHarness(dogfoodArmed: true)
        second.viewModel.finishStoppedSession(promotePendingSegment: false)
        await second.viewModel.polishAndCommitTask?.value
        let records = try recordsOnDisk(in: second.captureDirectory)
        XCTAssertNil(records.last?.join?.abstentionReason)
    }

    /// Populated sources ride the commit path into the record: a clipboard
    /// context produces its allocation row and harvested source row, and a
    /// repo-vocabulary outcome (with its tapped harvest) produces the
    /// `repoVocabulary` row AND its pre-application shows in `groundedText`.
    /// This is the end-to-end lock on the demand/grant/rendered extraction and
    /// the tap→record path, which the builder unit tests alone cannot see
    /// (review, 2026-07-25).
    func testPopulatedSourcesProduceAllocationAndSourceRows() async throws {
        let harness = try makeHarness(dogfoodArmed: true)
        harness.viewModel.settings.polishClipboardContextEnabled = true
        harness.viewModel.settings.repoVocabularyEnabled = true
        harness.viewModel.debugPolishContextPasteboardReaderOverride = {
            WiringPasteboardStub(text: "error in PolishContextBudget.swift line 40")
        }
        harness.viewModel.debugRepoVocabularyEntriesOverride = { _ in
            RepoVocabularyMatcher.GroundingOutcome(
                entries: [ReplacementEntry(replaceWith: "herdr", matches: ["herder"])],
                isFallbackOnly: false
            )
        }
        DogfoodCaptureTap.shared.beginSession()
        DogfoodCaptureTap.shared.noteRepoVocabularyHarvest(["herdr", "pane.read"])
        harness.viewModel.currentDictationEventText = "join the herder pane"

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        let record = try XCTUnwrap(recordsOnDisk(in: harness.captureDirectory).last)

        // Grounding pre-applied the repo entry before the model saw the text.
        XCTAssertEqual(record.text.groundedText, "join the herdr pane")

        // One allocation row: only the clipboard declared a render demand.
        XCTAssertEqual(record.allocation.count, 1)
        let allocation = record.allocation[0]
        XCTAssertEqual(allocation.source, "clipboard")
        XCTAssertGreaterThan(allocation.demandedCharacters, 0)
        XCTAssertEqual(allocation.grantedCharacters, allocation.demandedCharacters)
        XCTAssertEqual(allocation.renderedCharacters, allocation.demandedCharacters)
        XCTAssertFalse(allocation.excerptWasSelected)

        let sourceNames = record.sources.map(\.source)
        XCTAssertEqual(sourceNames, ["repoVocabulary", "clipboard"])

        let repoRow = record.sources[0]
        XCTAssertEqual(repoRow.harvest, ["herdr", "pane.read"])
        XCTAssertEqual(repoRow.entries, [.init(term: "herdr", heard: ["herder"])])

        let clipboardRow = record.sources[1]
        XCTAssertTrue(
            clipboardRow.harvest.contains("PolishContextBudget.swift"),
            "the clipboard's technical entities are the harvest: \(clipboardRow.harvest)"
        )
        XCTAssertEqual(
            clipboardRow.renderedExcerpt,
            "error in PolishContextBudget.swift line 40"
        )
    }

    /// The MAJOR from the 2026-07-25 review: a deadline-abandoned repo
    /// vocabulary pipeline finishing AFTER its session ended must not write its
    /// harvest into the next session's slot. Notes carry the generation they
    /// were created under; a stale one is dropped.
    func testStaleGenerationHarvestNoteIsRejected() {
        let tap = DogfoodCaptureTap.shared
        tap.beginSession()
        let staleGeneration = tap.currentGeneration
        tap.beginSession() // the next dictation began; the old pipeline is stale

        DogfoodCaptureTap.$noteGeneration.withValue(staleGeneration) {
            tap.noteRepoVocabularyHarvest(["previous-session-term"])
        }
        XCTAssertNil(
            tap.consumeRepoVocabularyHarvest(),
            "a stale pipeline's harvest must not survive into the new session"
        )

        DogfoodCaptureTap.$noteGeneration.withValue(tap.currentGeneration) {
            tap.noteRepoVocabularyHarvest(["current-session-term"])
        }
        XCTAssertEqual(tap.consumeRepoVocabularyHarvest(), ["current-session-term"])
    }

    /// A stopped-with-no-speech session writes nothing: there was no polish
    /// call and there is nothing to attribute.
    func testEmptyDictationWritesNoRecord() async throws {
        let harness = try makeHarness(dogfoodArmed: true)
        harness.viewModel.currentDictationEventText = "   "

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        XCTAssertEqual(try recordsOnDisk(in: harness.captureDirectory).count, 0)
    }

    // MARK: - Builder

    func testEndpointClassBuckets() {
        let cases: [(String, String)] = [
            ("http://127.0.0.1:8472/v1", "loopback"),
            ("http://localhost:8080/v1", "loopback"),
            ("http://[::1]:8080/v1", "loopback"),
            ("http://192.168.1.183:8080/v1", "lan"),
            ("http://10.0.0.7/v1", "lan"),
            ("http://172.20.0.2/v1", "lan"),
            ("http://mac-studio.local:8080/v1", "lan"),
            ("http://172.15.0.2/v1", "remote"),
            ("https://api.example.com/v1", "remote"),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(
                DogfoodCaptureBuilder.endpointClass(of: URL(string: url)!),
                expected, url
            )
        }
    }

    func testJoinBuilderMapsResolvedAndAbstainedJoins() {
        let unresolved = DogfoodCaptureBuilder.join(
            from: nil, abstentions: ["gate: accessibility not trusted"]
        )
        XCTAssertEqual(unresolved.arm, "none")
        XCTAssertEqual(unresolved.abstentionReason, "gate: accessibility not trusted")
        XCTAssertNil(unresolved.origin)

        let empty = DogfoodCaptureBuilder.join(from: nil, abstentions: [])
        XCTAssertEqual(empty.arm, "none")
        XCTAssertNil(empty.abstentionReason)
    }

    func testScreenBuilderRouteAndCause() {
        let vocabOnly = DogfoodCaptureBuilder.screen(
            from: .vocabularyOnly(
                startText: "screen text",
                cause: .screenChanged(stopLength: 10, differingLines: 3, firstDifferingLine: 0)
            ),
            targetBundleID: TerminalScreenAllowlist.ghosttyBundleID,
            herdrSwapApplied: false
        )
        XCTAssertEqual(vocabOnly.route, "axGrid")
        XCTAssertEqual(vocabOnly.decision, "vocabularyOnly")
        XCTAssertEqual(vocabOnly.cause, "screen-changed(stop:10ch lines:3 first:0)")
        XCTAssertEqual(vocabOnly.sanitizedText, "screen text")
        XCTAssertEqual(vocabOnly.sanitizedCharacterCount, "screen text".count)

        let appleScript = DogfoodCaptureBuilder.screen(
            from: .render(excerpt: "e", startText: "s", elidedChurnLines: 0),
            targetBundleID: TerminalScreenAllowlist.iterm2BundleID,
            herdrSwapApplied: false
        )
        XCTAssertEqual(appleScript.route, "appleScriptContents")
        XCTAssertEqual(appleScript.decision, "render")

        let herdr = DogfoodCaptureBuilder.screen(
            from: .render(excerpt: "pane", startText: "pane", elidedChurnLines: 0),
            targetBundleID: TerminalScreenAllowlist.ghosttyBundleID,
            herdrSwapApplied: true
        )
        XCTAssertEqual(herdr.route, "herdrPaneRead")

        let dropped = DogfoodCaptureBuilder.screen(
            from: .drop(reason: .targetChanged),
            targetBundleID: nil,
            herdrSwapApplied: false
        )
        XCTAssertEqual(dropped.decision, "drop")
        XCTAssertEqual(dropped.cause, "target-changed")
        XCTAssertNil(dropped.route)
        XCTAssertNil(dropped.sanitizedText)
    }

    func testAllocationsKeepZeroGrantsAndDropZeroDemands() {
        let rows = DogfoodCaptureBuilder.allocations(
            demands: [.repository: 9000, .terminal: 0, .clipboard: 200],
            grants: [.repository: 0, .clipboard: 200],
            rendered: [.clipboard: 180]
        )
        XCTAssertEqual(rows.count, 2, "zero-demand sources leave no row")

        let repo = rows[0]
        XCTAssertEqual(repo.source, "repository")
        XCTAssertEqual(repo.demandedCharacters, 9000)
        XCTAssertEqual(repo.grantedCharacters, 0)
        XCTAssertTrue(
            repo.excerptWasSelected,
            "a starved source is exactly what bucket 4 needs recorded"
        )

        let clipboard = rows[1]
        XCTAssertEqual(clipboard.source, "clipboard")
        XCTAssertFalse(clipboard.excerptWasSelected)
        XCTAssertEqual(clipboard.renderedCharacters, 180)
    }

    func testHarvestListIsCappedInTheRecordOnly() {
        let harvest = (0..<(DogfoodCaptureBuilder.harvestTermCap + 7)).map { "term\($0)" }
        let row = DogfoodCaptureBuilder.source(DogfoodCaptureBuilder.SourceInputs(
            source: .clipboard,
            harvest: harvest,
            outcome: .empty,
            renderedExcerpt: nil
        ))
        XCTAssertEqual(row.harvest.count, DogfoodCaptureBuilder.harvestTermCap)
        XCTAssertEqual(row.harvestCount, harvest.count, "the true pool size survives the cap")
        XCTAssertTrue(row.harvestTruncated)
    }

    func testTapBeginSessionClearsBothSlots() {
        DogfoodCaptureTap.shared.beginSession()
        DogfoodCaptureTap.shared.noteJoinAbstention("tty: stale")
        DogfoodCaptureTap.shared.noteRepoVocabularyHarvest(["Term"])
        DogfoodCaptureTap.shared.beginSession()
        XCTAssertEqual(DogfoodCaptureTap.shared.consumeJoinAbstentions(), [])
        XCTAssertNil(DogfoodCaptureTap.shared.consumeRepoVocabularyHarvest())
    }

    // MARK: - Harness (mirrors the polish-failure diagnostics suite)

    private struct Harness {
        let viewModel: DictationViewModel
        let captureDirectory: URL
    }

    private func makeHarness(
        dogfoodArmed: Bool,
        blockCaptureDirectory: Bool = false
    ) throws -> Harness {
        let settings = makeSettings()
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = .managedLocal
        settings.dogfoodCaptureEnabled = dogfoodArmed

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogfood-wiring-\(UUID().uuidString)", isDirectory: true)
        let captureDirectory = base.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if blockCaptureDirectory {
            // A regular FILE at the directory path: every store write fails.
            try Data("not a directory".utf8).write(
                to: captureDirectory, options: []
            )
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }

        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: WiringMockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = WiringMockAppConfigStore()
        viewModel.llmPolishingService = SucceedingPolishingService()
        viewModel.dogfoodCaptureStore = DogfoodCaptureStore(directoryURL: captureDirectory)
        viewModel.isShowingConnectionFailureAlert = true
        Self.retainedViewModels.append(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "polish this text"
        return Harness(viewModel: viewModel, captureDirectory: captureDirectory)
    }

    /// Decoded records, oldest first.
    private func recordsOnDisk(in directory: URL) throws -> [DogfoodCaptureRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path).sorted()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try names.map { name in
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            return try decoder.decode(DogfoodCaptureRecord.self, from: data)
        }
    }

    private func makeSettings() -> SettingsStore {
        let suiteName = "localvoxtral.DogfoodCaptureWiringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(defaults: defaults, environment: [:])
        settings.dictationOutputMode = .overlayBuffer
        return settings
    }
}

/// A plain-text pasteboard with no concealed/transient markers.
private final class WiringPasteboardStub: PasteboardReading {
    private let text: String
    init(text: String) { self.text = text }
    func types() -> [NSPasteboard.PasteboardType]? { [.string] }
    func string() -> String? { text }
}

/// Always polishes successfully, without networking.
private actor SucceedingPolishingService: LLMPolishingServicing {
    func polish(
        request: LLMPolishingRequest,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        LLMPolishingResult(
            rawText: request.inputText,
            polishedText: "polished output text",
            durationSeconds: 0.25
        )
    }
}

private final class WiringMockAppConfigStore: AppConfigServing {
    func configDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
    }

    func loadReplacementDictionary() -> ReplacementDictionary {
        ReplacementDictionary(entries: [])
    }

    func loadLLMPromptTemplates() -> LLMPromptTemplates {
        LLMPromptTemplates(systemContent: "system", userContent: "{{input_text}}")
    }

    func loadTerminalAppBundleIDs() -> [String] {
        []
    }
}

@MainActor
private final class WiringMockOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitTargetAppPID: pid_t? = nil

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 100, height: 24),
            source: .windowCenter
        )
    }

    func startSession(preResolvedAnchor _: OverlayAnchor?) {}
    func beginFinalizing(displayBufferText _: String, commitBufferText _: String) {}
    func refresh(displayBufferText _: String, commitBufferText _: String) {}

    func commitIfNeeded(
        using _: OverlayTextCommitting,
        autoCopyEnabled _: Bool
    ) -> OverlayBufferCommitOutcome {
        .succeeded
    }

    func dismissAfterHold(minimumVisibility _: TimeInterval) {}
    func reset() {}
    func captureLiveCommitTargetAppPID() {}
    func markPolished(_: Bool) {}
}

#endif
