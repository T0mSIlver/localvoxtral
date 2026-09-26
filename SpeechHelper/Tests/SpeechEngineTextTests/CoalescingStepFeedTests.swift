import XCTest

@testable import SpeechEngineText

final class CoalescingStepFeedTests: XCTestCase {
    private let chunk = 1_280  // 80 ms at 16 kHz

    func testStepsEachAppendWhenNothingIsQueuedBehindIt() {
        let feed = CoalescingStepFeed(minimumMilliseconds: 80)

        for index in 0..<3 {
            feed.audioQueued()
            XCTAssertEqual(
                feed.receive(samples(count: chunk, startingAt: index * chunk)),
                samples(count: chunk, startingAt: index * chunk)
            )
        }
    }

    /// A slow step: four appends arrive while it runs. Fixed-size batching would run
    /// four steps back to back and fall further behind; the feed runs one.
    func testAppendsQueuedDuringASlowStepBecomeOneStep() {
        let feed = CoalescingStepFeed(minimumMilliseconds: 80)
        for _ in 0..<4 { feed.audioQueued() }

        XCTAssertNil(feed.receive(samples(count: chunk, startingAt: 0)))
        XCTAssertNil(feed.receive(samples(count: chunk, startingAt: chunk)))
        XCTAssertNil(feed.receive(samples(count: chunk, startingAt: 2 * chunk)))
        XCTAssertEqual(
            feed.receive(samples(count: chunk, startingAt: 3 * chunk)),
            samples(count: 4 * chunk, startingAt: 0)
        )
        XCTAssertEqual(feed.takeLargestStepSamples(), 4 * chunk)
        XCTAssertEqual(feed.takeLargestStepSamples(), 0)
    }

    func testWaitsForTheMinimumStep() {
        let feed = CoalescingStepFeed(minimumMilliseconds: 80)

        feed.audioQueued()
        XCTAssertNil(feed.receive(samples(count: chunk - 1, startingAt: 0)))
        feed.audioQueued()
        XCTAssertEqual(
            feed.receive(samples(count: 1, startingAt: chunk - 1)),
            samples(count: chunk, startingAt: 0)
        )
    }

    /// Every sample received is stepped or flushed exactly once, in order, however the
    /// appends interleave with the steps.
    func testEverySampleReachesTheEngineOnceInOrder() {
        let feed = CoalescingStepFeed(minimumMilliseconds: 80)
        let sizes = [300, 1_600, 1_280, 7, 2_000, 1_279, 1, 640, 5_000, 90]
        var sent = 0
        var stepped: [Float] = []
        var index = 0
        // Queue appends in bursts of 1, 2 and 3, as a step of varying length would.
        for burst in [1, 2, 3, 1, 3] {
            for _ in 0..<burst { feed.audioQueued() }
            for _ in 0..<burst {
                let batch = feed.receive(samples(count: sizes[index], startingAt: sent))
                sent += sizes[index]
                index += 1
                if let batch { stepped += batch }
            }
        }
        stepped += feed.flushRemainder()

        XCTAssertEqual(stepped, samples(count: sent, startingAt: 0))
    }

    /// A commit dispatched between two appends flushes the first utterance's leftover
    /// while the next utterance's append is still queued; that append then starts fresh.
    func testDeferredAudioIsFlushedByTheCommitBehindIt() {
        let feed = CoalescingStepFeed(minimumMilliseconds: 80)
        feed.audioQueued()  // last append of utterance A
        feed.audioQueued()  // first append of utterance B, queued after A's commit

        XCTAssertNil(feed.receive(samples(count: chunk, startingAt: 0)))
        XCTAssertEqual(feed.flushRemainder(), samples(count: chunk, startingAt: 0))
        XCTAssertEqual(
            feed.receive(samples(count: chunk, startingAt: 10_000)),
            samples(count: chunk, startingAt: 10_000)
        )
    }

    func testClearDropsBufferedAudioButKeepsQueuedAppends() {
        let feed = CoalescingStepFeed(minimumMilliseconds: 80)
        feed.audioQueued()
        feed.audioQueued()
        XCTAssertNil(feed.receive(samples(count: 100, startingAt: 0)))

        feed.clear()

        XCTAssertTrue(feed.flushRemainder().isEmpty)
        XCTAssertEqual(
            feed.receive(samples(count: chunk, startingAt: 0)),
            samples(count: chunk, startingAt: 0)
        )
    }

    private func samples(count: Int, startingAt start: Int) -> [Float] {
        (start..<(start + count)).map(Float.init)
    }
}
