import Foundation
import localvoxtralTestSupport
import XCTest
@testable import localvoxtral

#if DEBUG
/// A Mistral realtime stall drops the speech sent during it (#1648, symptom D
/// in docs/agent/mistral-realtime-stall.md). In process: an Overlay Buffer
/// dictation in Mistral API mode, with the stop's second pass off, gets the
/// events the realtime client raises around a stall; the batch endpoint is a
/// fake, and the backfill's deadline runs on a `ManualSessionClock`.
@MainActor
final class StallBackfillPipelineTests: XCTestCase {
    private static let beforeStall = "we should ship it tonight"
    private static let afterStall = " and then start fresh"
    /// What the batch model hears in the stall's window: the end of the text
    /// before it, the dropped words, the start of the text after it.
    private static let batchText = "Ship it tonight, then archive every session. And then"
    private static let spliced = "we should ship it tonight then archive every session. and then start fresh"
    /// 7.5 s of server silence over speech at -33 dBFS, as on 2026-10-03.
    private static let stall = MistralStreamHealth.StallEnd(silentFor: 7.5, audioSeconds: 7.5, loudestDBFS: -33)
    /// 12 s of 16 kHz mono PCM16, no two adjacent seconds alike.
    private static let pcm = Data((0..<(32_000 * 12)).map { UInt8(truncatingIfNeeded: $0 / 32_000 &* 31 &+ $0) })

    func testTheStalledWordsReachTheOverlayBeforeTheStopAndTheCommitAfterIt() async {
        let transcriber = FakeBatchTranscriber(.text(Self.batchText))
        let harness = makeHarness(transcriber: transcriber)
        let session = harness.viewModel.session

        session.handle(event: .partialTranscript(Self.beforeStall))
        session.handle(event: .serverStallEnded(Self.stall))
        session.handle(event: .partialTranscript(Self.afterStall))
        await session.stallBackfillTasks.last?.value

        XCTAssertEqual(
            harness.overlay.refreshCalls.last?.displayText, Self.spliced,
            "the overlay shows the stalled words while the user still dictates")
        let window = (7.5 + StallBackfill.leadSeconds) * 32_000
        XCTAssertEqual(transcriber.calls, [FakeBatchTranscriber.Call(
            wav: DictationAudioRecording.wav(fromPCM16: Self.pcm.suffix(Int(window))),
            language: nil,
            contextBias: ["localvoxtral"],
            apiKey: "session-key",
            endpoint: URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!
        )])
        let usage = harness.ledger.entries()
        XCTAssertEqual(usage.map(\.feature), [.secondPass])
        XCTAssertEqual(usage.first?.audioSeconds ?? 0, 10.5, accuracy: 1e-9)

        // Mistral's done repeats its deltas, without the stalled words.
        harness.viewModel.isDictating = false
        harness.viewModel.isFinalizingStop = true
        session.handle(event: .finalTranscript(Self.beforeStall + Self.afterStall))
        session.finishStoppedSession(promotePendingSegment: false)
        await awaitStoppedSessionCommit(harness.viewModel)

        XCTAssertEqual(harness.overlay.committedTexts, [Self.spliced])
        XCTAssertEqual(harness.records.all.map(\.rawText), [Self.spliced])
    }

    func testAQuietStallSendsNothing() async {
        let transcriber = FakeBatchTranscriber(.text(Self.batchText))
        let harness = makeHarness(transcriber: transcriber)
        let session = harness.viewModel.session

        session.handle(event: .partialTranscript(Self.beforeStall))
        session.handle(event: .serverStallEnded(
            MistralStreamHealth.StallEnd(silentFor: 15.7, audioSeconds: 15.7, loudestDBFS: -55)))

        XCTAssertTrue(session.stallBackfillTasks.isEmpty)
        XCTAssertTrue(transcriber.calls.isEmpty)
    }

    func testALateBackfillKeepsTheHole() async {
        let clock = ManualSessionClock()
        let transcriber = FakeBatchTranscriber(.held)
        let harness = makeHarness(transcriber: transcriber, clock: clock)
        let session = harness.viewModel.session

        session.handle(event: .partialTranscript(Self.beforeStall))
        session.handle(event: .serverStallEnded(Self.stall))
        session.handle(event: .partialTranscript(Self.afterStall))
        _ = await transcriber.called.value(failAfter: 10)
        await clock.waitForSleepers(1)
        clock.advance(by: 30)
        await session.stallBackfillTasks.last?.value

        XCTAssertEqual(transcriber.cancelledCount, 1)
        XCTAssertEqual(harness.overlay.refreshCalls.last?.displayText, Self.beforeStall + Self.afterStall)
    }

    // MARK: - Harness

    private struct Harness {
        let viewModel: DictationViewModel
        let overlay: MockOverlayCoordinator
        let ledger: UsageLedger
        let records: RecordLog
    }

    private func makeHarness(
        transcriber: FakeBatchTranscriber,
        clock: ManualSessionClock = ManualSessionClock()
    ) -> Harness {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.polishSpeakerTerms = ["localvoxtral"]
        settings.llmPolishingEnabled = false
        settings.dictationBackendMode = .mistralAPI
        // As since #1678: with the second pass off, nothing else refills the hole.
        settings.mistralStopSecondPassEnabled = false
        let overlay = MockOverlayCoordinator()
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
        retainForTestProcessLifetime(viewModel)
        let ledger = UsageLedger(fileURL: nil)
        let session = viewModel.session
        session.secondPassUsageRecorder = ledger
        session.sessionOutputMode = .overlayBuffer
        session.sessionRealtimeConfiguration = RealtimeSessionConfiguration(
            endpoint: MistralRealtimeWebSocketClient.defaultEndpoint,
            apiKey: "session-key",
            model: "voxtral-mini-transcribe-realtime-2602"
        )
        session.latchSessionAudio(outputMode: .overlayBuffer)
        session.audio.sessionRecording.append(Self.pcm)
        viewModel.isDictating = true
        return Harness(viewModel: viewModel, overlay: overlay, ledger: ledger, records: records)
    }
}

/// Every record the session wrote, in order.
private final class RecordLog {
    var all: [DictationSessionRecord] = []
}
#endif
