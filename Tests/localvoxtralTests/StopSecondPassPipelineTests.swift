import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

#if DEBUG
/// The second pass on stop (#317), in process: an Overlay Buffer dictation
/// in Mistral API mode is sent whole to the batch endpoint, and its text
/// replaces the realtime text only when it answers before the deadline. The
/// batch endpoint is a fake; the deadline runs on a `ManualSessionClock`.
@MainActor
final class StopSecondPassPipelineTests: XCTestCase {
    private static let realtimeText = "why is local vogue's codesign identity not picked up"
    private static let batchText = "Why is localvoxtral codesign identity not picked up?"
    /// One second of 16 kHz mono PCM16.
    private static let pcm = Data((0..<32_000).map { UInt8(truncatingIfNeeded: $0) })

    func testAnAnswerInTimeReplacesTheRealtimeTextBeforePolish() async {
        let transcriber = FakeBatchTranscriber(.text(Self.batchText))
        let polisher = FakePolishingService()
        let harness = makeHarness(transcriber: transcriber, polisher: polisher)
        let ledger = MistralUsageLedger(fileURL: nil)
        harness.viewModel.session.secondPassUsageRecorder = ledger

        harness.stop()
        XCTAssertEqual(harness.viewModel.statusText, DictationViewModel.StatusStrings.transcribingAgain)
        await awaitStoppedSessionCommit(harness.viewModel)

        XCTAssertEqual(transcriber.calls, [FakeBatchTranscriber.Call(
            wav: DictationAudioRecording.wav(fromPCM16: Self.pcm),
            language: nil,
            contextBias: ["localvoxtral", "Claude_Code"],
            apiKey: "session-key",
            endpoint: URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!
        )])
        let polished = await polisher.lastRequest
        XCTAssertEqual(polished?.inputText, Self.batchText, "polish runs on the second pass's text")
        XCTAssertEqual(harness.overlay.committedTexts, [Self.batchText])
        XCTAssertEqual(harness.records.map(\.rawText), [Self.batchText])
        XCTAssertEqual(harness.records.first?.commitSucceeded, true)
        let usage = ledger.entries()
        XCTAssertEqual(usage.map(\.kind), [.retranscription])
        XCTAssertEqual(usage.first?.audioSeconds, 1)
        XCTAssertEqual(usage.first?.costEUR ?? 0, 0.0026 / 60, accuracy: 1e-12)
    }

    func testTheDeadlineKeepsTheRealtimeTextAndCancelsTheRequest() async {
        let transcriber = FakeBatchTranscriber(.held)
        let harness = makeHarness(transcriber: transcriber)

        harness.stop()
        let commit = harness.viewModel.session.polishAndCommitTask
        _ = await transcriber.called.value(failAfter: 10)
        await harness.clock.waitForSleepers(1)
        XCTAssertTrue(harness.overlay.committedTexts.isEmpty, "nothing is committed while the pass runs")
        harness.clock.advance(by: 3)
        await commit?.value

        XCTAssertEqual(transcriber.cancelledCount, 1)
        XCTAssertEqual(harness.overlay.committedTexts, [Self.realtimeText])
        XCTAssertEqual(harness.records.map(\.rawText), [Self.realtimeText])
    }

    func testAFailedPassKeepsTheRealtimeText() async {
        struct Refused: Error {}
        let harness = makeHarness(transcriber: FakeBatchTranscriber(.failure(Refused())))

        harness.stop()
        await awaitStoppedSessionCommit(harness.viewModel)

        XCTAssertEqual(harness.overlay.committedTexts, [Self.realtimeText])
        XCTAssertNil(harness.viewModel.lastError, "a failed second pass is only logged")
    }

    func testANewDictationDuringThePassSavesTheRealtimeTextAsNotInserted() async {
        let transcriber = FakeBatchTranscriber(.held)
        let harness = makeHarness(transcriber: transcriber)

        harness.stop()
        let commit = harness.viewModel.session.polishAndCommitTask
        _ = await transcriber.called.value(failAfter: 10)
        XCTAssertTrue(harness.viewModel.session.cancelPolishingForNewSessionIfNeeded())
        await commit?.value

        XCTAssertTrue(harness.overlay.committedTexts.isEmpty)
        XCTAssertEqual(harness.records.map(\.rawText), [Self.realtimeText])
        XCTAssertEqual(harness.records.first?.commitSucceeded, false)
    }

    func testASessionWithoutASecondPassCommitsAtOnce() {
        let transcriber = FakeBatchTranscriber(.text(Self.batchText))
        let harness = makeHarness(transcriber: transcriber, secondPass: false)

        harness.stop()

        XCTAssertTrue(transcriber.calls.isEmpty)
        XCTAssertNil(harness.viewModel.session.polishAndCommitTask)
        XCTAssertEqual(harness.overlay.committedTexts, [Self.realtimeText])
    }

    // MARK: - Context terms (#647)

    private static let projectDirectory = "/nonexistent-647/quillmark"

    /// The terms one dictation joined to a Claude Code session in a project
    /// whose agent proposed `inkwell` sends, polished or not.
    private func contextBias(trusted: Bool, polish: Bool) async -> [String]? {
        let transcriber = FakeBatchTranscriber(.text("Ask Claude_Code about inkwell."))
        let harness = makeHarness(
            transcriber: transcriber, polisher: polish ? FakePolishingService() : nil)
        let settings = harness.viewModel.settings
        settings.polishContextTrustedEndpointEnabled = trusted
        settings.repoVocabularyEnabled = true
        let store = LearnedTermStore(fileURL: nil, now: harness.clock.clock.now)
        let project = LearnedTermProjectIdentity(key: Self.projectDirectory, name: "quillmark")
        store.recordProposal(["inkwell"], agent: .claude, project: project, excluding: [])
        store.waitForPendingWrites()
        harness.viewModel.learnedTermStore = store
        harness.viewModel.dependencies.repoVocabularyGrounding = FakeRepoVocabularyGrounding(outcome: nil)
        let origin = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
        var snapshot = ClaudeSessionSnapshot(
            sessionID: "s1", origin: origin, agent: .claude, firstSeen: Date(timeIntervalSince1970: 0))
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: Self.projectDirectory, origin: origin)
        harness.viewModel.session.context.claudeSessionJoin = ClaudeSessionJoin(
            target: TerminalScreenTarget(pid: 4242, bundleID: "com.apple.Terminal"),
            snapshot: snapshot,
            windowID: 101,
            mechanism: .ttyDevice
        )

        harness.stop()
        await awaitStoppedSessionCommit(harness.viewModel)
        XCTAssertEqual(
            harness.records.first?.rawText, "Ask Claude Code about inkwell.",
            "a phrase the model wrote as sent gets its space back")
        return transcriber.calls.first?.contextBias
    }

    func testARepositoryTermLeavesOnlyWithTheTrustedEndpointOptIn() async {
        let untrusted = await contextBias(trusted: false, polish: false)
        XCTAssertEqual(untrusted, ["localvoxtral", "Claude_Code"])
        let trusted = await contextBias(trusted: true, polish: false)
        XCTAssertEqual(trusted, ["localvoxtral", "Claude_Code", "inkwell"])
    }

    func testThePolishCaptureCarriesTheJoinToTheSecondPass() async {
        let untrusted = await contextBias(trusted: false, polish: true)
        XCTAssertEqual(untrusted, ["localvoxtral", "Claude_Code"])
        let trusted = await contextBias(trusted: true, polish: true)
        XCTAssertEqual(trusted, ["localvoxtral", "Claude_Code", "inkwell"])
    }

    // MARK: - Latch

    func testOnlyAnOverlayDictationInMistralModeKeepsItsAudioForTheSecondPass() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.dictationAudioEnabled = false
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)
        let session = viewModel.session

        settings.dictationBackendMode = .mistralAPI
        session.latchSessionAudio(outputMode: .overlayBuffer)
        XCTAssertTrue(session.sessionHasStopSecondPass)
        XCTAssertFalse(session.sessionStoresAudio, "kept in memory, never for the audio store")
        session.audio.sessionRecording.append(Self.pcm)
        XCTAssertEqual(session.audio.sessionRecording.finish(), Self.pcm)

        session.latchSessionAudio(outputMode: .liveAutoPaste)
        XCTAssertFalse(session.sessionHasStopSecondPass, "Live Auto-Paste has typed its text already")
        session.audio.sessionRecording.append(Self.pcm)
        XCTAssertNil(session.audio.sessionRecording.finish())

        settings.dictationBackendMode = .externalURL
        session.latchSessionAudio(outputMode: .overlayBuffer)
        XCTAssertFalse(session.sessionHasStopSecondPass)
    }

    // MARK: - Harness

    private struct Harness {
        let viewModel: DictationViewModel
        let overlay: MockOverlayCoordinator
        let clock: ManualSessionClock
        let recordLog: RecordLog
        var records: [DictationSessionRecord] { recordLog.all }

        @MainActor func stop() {
            viewModel.isDictating = false
            viewModel.isFinalizingStop = true
            viewModel.session.finishStoppedSession(promotePendingSegment: false)
        }
    }

    private func makeHarness(
        transcriber: FakeBatchTranscriber,
        polisher: FakePolishingService? = nil,
        secondPass: Bool = true
    ) -> Harness {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.polishSpeakerTerms = ["localvoxtral", "Claude Code"]
        settings.polishContextTrustedEndpointEnabled = false
        if polisher != nil {
            settings.llmPolishingEnabled = true
            settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"
        } else {
            settings.llmPolishingEnabled = false
        }
        let overlay = MockOverlayCoordinator()
        let clock = ManualSessionClock()
        let records = RecordLog()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlay,
            startRuntimeServices: false,
            dependencies: DictationViewModel.Dependencies(
                onSessionRecord: { records.all.append($0) },
                clock: clock.clock,
                batchTranscriber: transcriber
            )
        )
        viewModel.appConfigStore = MockAppConfigStore()
        if let polisher {
            viewModel.llmPolishingService = polisher
        }
        retainForTestProcessLifetime(viewModel)

        let session = viewModel.session
        session.sessionOutputMode = .overlayBuffer
        session.sessionHasStopSecondPass = secondPass
        session.sessionRealtimeConfiguration = RealtimeSessionConfiguration(
            endpoint: MistralRealtimeWebSocketClient.defaultEndpoint,
            apiKey: "session-key",
            model: "voxtral-mini-transcribe-realtime-2602"
        )
        session.audio.sessionRecording.begin(enabled: true)
        session.audio.sessionRecording.append(Self.pcm)
        viewModel.transcript.currentDictationEventText = Self.realtimeText
        return Harness(viewModel: viewModel, overlay: overlay, clock: clock, recordLog: records)
    }
}

/// Every record the session wrote, in order.
private final class RecordLog {
    var all: [DictationSessionRecord] = []
}
#endif
