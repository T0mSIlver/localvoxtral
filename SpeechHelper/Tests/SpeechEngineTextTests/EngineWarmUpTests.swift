import XCTest

@testable import SpeechEngineText

final class EngineWarmUpTests: XCTestCase {
    private final class RecordingSession: SpeechASRStreamingSession, @unchecked Sendable {
        var steps: [[Float]] = []
        var finishes = 0
        func step(_ samples: [Float]) -> SpeechStreamDelta {
            steps.append(samples)
            return SpeechStreamDelta(text: "", tokenIds: [])
        }
        func finish() -> SpeechStreamDelta {
            finishes += 1
            return SpeechStreamDelta(text: "", tokenIds: [])
        }
        var text: String { "" }
        var decodedTokenCount: Int { 0 }
        var utteranceStop: UtteranceStop? { nil }
    }

    private final class FakeEngine: SpeechASREngine, @unchecked Sendable {
        let samples: Int?
        var sessions: [RecordingSession] = []
        init(samples: Int?) { self.samples = samples }
        func makeSession(
            transcriptionDelayMs _: Int?, utteranceLimit _: UtteranceLimit, terms _: SessionTerms,
            language _: String?
        ) -> SpeechASRStreamingSession {
            let session = RecordingSession()
            sessions.append(session)
            return session
        }
        func warmUpSamples(transcriptionDelayMs: Int?) -> Int {
            samples ?? NemotronUnifiedLayout.warmUpSamples(forTranscriptionDelayMs: transcriptionDelayMs)
        }
    }

    /// Samples a live session holds when it runs its first step on a full
    /// left + chunk + right window (LVX-111: the step at 6.00 s on 70/2/2).
    private func firstFullWindow(_ frames: [Int]) -> Int {
        (frames[0] + frames[1] + frames[2]) * NemotronUnifiedLayout.frameSamples + 1
    }

    func testTheDefaultLayoutWarmsUpPastSixPointOneSeconds() {
        let samples = NemotronUnifiedLayout.warmUpSamples(forTranscriptionDelayMs: nil)
        XCTAssertGreaterThanOrEqual(samples, 97_600)  // 6.1 s
        XCTAssertGreaterThan(samples, firstFullWindow(NemotronUnifiedLayout.frames(forTranscriptionDelayMs: nil)))
    }

    func testEveryDelayWarmsUpPastTwoFullContextSteps() {
        for delay in stride(from: 160, through: 2_080, by: 80) {
            let frames = NemotronUnifiedLayout.frames(forTranscriptionDelayMs: delay)
            let samples = NemotronUnifiedLayout.warmUpSamples(forTranscriptionDelayMs: delay)
            // A second full-window step runs once the stream holds one more chunk.
            XCTAssertGreaterThanOrEqual(
                samples, firstFullWindow(frames) + frames[1] * NemotronUnifiedLayout.frameSamples,
                "delay \(delay) ms"
            )
        }
    }

    func testItFeedsSilenceInServerSizedStepsThenFinishesOnce() throws {
        let engine = FakeEngine(samples: nil)
        let steps = EngineWarmUp.run(engine, transcriptionDelayMs: nil, stepSamples: 1_280)
        let session = try XCTUnwrap(engine.sessions.only)
        XCTAssertEqual(steps, session.steps.count)
        XCTAssertEqual(session.steps.map(\.count).reduce(0, +),
                       NemotronUnifiedLayout.warmUpSamples(forTranscriptionDelayMs: nil))
        XCTAssertTrue(session.steps.dropLast().allSatisfy { $0.count == 1_280 })
        XCTAssertTrue(session.steps.allSatisfy { $0.allSatisfy { $0 == 0 } })
        XCTAssertEqual(session.finishes, 1)
    }

    func testAnUnevenTotalEndsWithAShortStep() throws {
        let engine = FakeEngine(samples: 3_000)
        XCTAssertEqual(EngineWarmUp.run(engine, transcriptionDelayMs: nil, stepSamples: 1_280), 3)
        XCTAssertEqual(try XCTUnwrap(engine.sessions.only).steps.map(\.count), [1_280, 1_280, 440])
    }

    func testAnEngineThatNeedsNoWarmUpOpensNoSession() {
        let engine = FakeEngine(samples: 0)
        XCTAssertEqual(EngineWarmUp.run(engine, transcriptionDelayMs: nil, stepSamples: 1_280), 0)
        XCTAssertTrue(engine.sessions.isEmpty)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
