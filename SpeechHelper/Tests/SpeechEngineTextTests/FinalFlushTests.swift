import Synchronization
import XCTest

@testable import SpeechEngineText

/// The final commit's flush (LVX-59, LVX-60): deltas leave after each step, and a closed
/// feed stops the remaining steps and the `done`.
final class FinalFlushTests: XCTestCase {
    /// Each step appends one word; `onStep` runs inside the step, like a disconnect
    /// arriving while the GPU works.
    private final class FakeSession: SpeechASRStreamingSession {
        private let state = Mutex((steps: 0, finished: false))
        let onStep: @Sendable (Int) -> Void
        init(onStep: @escaping @Sendable (Int) -> Void = { _ in }) { self.onStep = onStep }

        var steps: Int { state.withLock { $0.steps } }
        var finished: Bool { state.withLock { $0.finished } }
        var text: String { (1...max(1, steps)).prefix(steps).map { "w\($0)" }.joined(separator: " ") }
        var decodedTokenCount: Int { steps }
        var utteranceStop: UtteranceStop? { nil }

        func step(_ samples: [Float]) -> SpeechStreamDelta {
            let n = state.withLock { $0.steps += 1; return $0.steps }
            onStep(n)
            return SpeechStreamDelta(text: "", tokenIds: [])
        }
        func finish() -> SpeechStreamDelta {
            state.withLock { $0.finished = true }
            return SpeechStreamDelta(text: "", tokenIds: [])
        }
    }

    /// A feed holding `batches` full-size batches of unflushed audio.
    private func feed(batches: Int) -> CoalescingStepFeed {
        let feed = CoalescingStepFeed(minimumMilliseconds: 80, maximumMilliseconds: 80)
        feed.audioQueued()
        // receive() hands out one full batch at once; the rest stays buffered for the flush.
        _ = feed.receive([Float](repeating: 0, count: feed.maximumSamples * (batches + 1) - 1))
        return feed
    }

    func testEachStepSendsItsDeltaBeforeTheNextStepRuns() {
        let feed = feed(batches: 3)
        let sent = Mutex<[String]>([])
        let seenAtStep = Mutex<[Int]>([])
        let session = FakeSession(onStep: { _ in seenAtStep.withLock { $0.append(sent.withLock { $0.count }) } })
        var deltas = TranscriptDeltaEmitter()
        let done = FinalFlush.run(
            session: session, feed: feed, deltas: &deltas,
            send: { d in sent.withLock { $0.append(d) } }, beforeFinish: {})
        XCTAssertTrue(done)
        XCTAssertTrue(session.finished)
        // Step n starts after n-1 deltas went out.
        XCTAssertEqual(seenAtStep.withLock { $0 }, [0, 1, 2])
        XCTAssertEqual(sent.withLock { $0 }.joined(), deltas.emittedText)
        XCTAssertEqual(deltas.emittedText, "w1 w2 w3")
    }

    func testDisconnectDuringTheSecondOfFiveStepsRunsTwoStepsAndNoFinish() {
        let feed = feed(batches: 5)
        let session = FakeSession(onStep: { n in if n == 2 { feed.close() } })
        var deltas = TranscriptDeltaEmitter()
        let sent = Mutex<[String]>([])
        let done = FinalFlush.run(
            session: session, feed: feed, deltas: &deltas,
            send: { d in sent.withLock { $0.append(d) } }, beforeFinish: {})
        XCTAssertFalse(done)
        XCTAssertEqual(session.steps, 2)
        XCTAssertFalse(session.finished)
    }
}
