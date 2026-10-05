import XCTest

@testable import SpeechEngineText

final class StepBatcherTests: XCTestCase {
    func testCadenceBoundaryExactlyAtThreshold() {
        var batcher = StepBatcher(cadenceMilliseconds: 100)

        let batches = batcher.append(samples(count: 1_600, startingAt: 0)).map(\.samples)

        XCTAssertEqual(batches, [samples(count: 1_600, startingAt: 0)])
        XCTAssertEqual(batcher.bufferedSampleCount, 0)
    }

    func testCadenceBoundaryJustBelowThreshold() {
        var batcher = StepBatcher(cadenceMilliseconds: 100)

        XCTAssertTrue(batcher.append(samples(count: 1_599, startingAt: 0)).isEmpty)
        XCTAssertEqual(batcher.bufferedSampleCount, 1_599)
    }

    func testCadenceBoundaryJustAboveThresholdKeepsRemainder() {
        var batcher = StepBatcher(cadenceMilliseconds: 100)

        let batches = batcher.append(samples(count: 1_601, startingAt: 0)).map(\.samples)

        XCTAssertEqual(batches, [samples(count: 1_600, startingAt: 0)])
        XCTAssertEqual(batcher.bufferedSampleCount, 1)
        XCTAssertEqual(batcher.flushRemainder(), [1_600])
    }

    func testLargeAppendYieldsMultipleBatchesInOrder() {
        var batcher = StepBatcher(cadenceMilliseconds: 100)

        let batches = batcher.append(samples(count: 3_500, startingAt: 0)).map(\.samples)

        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0], samples(count: 1_600, startingAt: 0))
        XCTAssertEqual(batches[1], samples(count: 1_600, startingAt: 1_600))
        XCTAssertEqual(batcher.flushRemainder(), samples(count: 300, startingAt: 3_200))
    }

    func testFlushReturnsAccumulatedRemainderAndResetsBatcher() {
        var batcher = StepBatcher(cadenceMilliseconds: 100)
        XCTAssertTrue(batcher.append([1, 2]).isEmpty)
        XCTAssertTrue(batcher.append([3]).isEmpty)

        XCTAssertEqual(batcher.flushRemainder(), [1, 2, 3])
        XCTAssertEqual(batcher.bufferedSampleCount, 0)
        XCTAssertTrue(batcher.flushRemainder().isEmpty)
    }

    func testZeroLengthAppendDoesNotChangeBufferedSamples() {
        var batcher = StepBatcher(cadenceMilliseconds: 100)
        XCTAssertTrue(batcher.append([1, 2, 3]).isEmpty)

        XCTAssertTrue(batcher.append([]).isEmpty)
        XCTAssertEqual(batcher.bufferedSampleCount, 3)
        XCTAssertEqual(batcher.flushRemainder(), [1, 2, 3])
    }

    func testPhaseShiftsEveryBoundaryPastTheCadenceMultiple() {
        var batcher = StepBatcher(cadenceMilliseconds: 80, phaseMilliseconds: 10)

        let batches = batcher.append(samples(count: 4_000, startingAt: 0))

        // Boundaries at 90, 170 and 250 ms: 1,440, 2,720 and 4,000 samples.
        XCTAssertEqual(batches.map(\.samples.count), [1_440, 1_280, 1_280])
        XCTAssertEqual(batches.map(\.arrivalSample), [1_440, 2_720, 4_000])
        XCTAssertEqual(batches.last?.samples.last, 3_999)
        XCTAssertEqual(batcher.bufferedSampleCount, 0)
    }

    func testMicBufferDrainShorterThanTheMinimumWaitsForTheNextTick() {
        // 512 frames at 48 kHz: 7.5 buffers per 80 ms tick, so every other drain
        // holds 7 buffers (1,194 samples), under the 1,280-sample minimum step.
        var batcher = StepBatcher(
            cadenceMilliseconds: 80,
            micBufferMicroseconds: 10_667,
            minimumMilliseconds: 80
        )

        let batches = batcher.append(samples(count: 7_680, startingAt: 0))

        XCTAssertEqual(batches.map(\.samples.count), [2_389, 1_365, 2_560])
        XCTAssertEqual(batches.map(\.arrivalSample), [2_560, 3_840, 6_400])
        XCTAssertEqual(batcher.bufferedSampleCount, 1_366)
    }

    func testClearDropsBufferedSamples() {
        var batcher = StepBatcher(cadenceMilliseconds: 100)
        XCTAssertTrue(batcher.append([1, 2, 3]).isEmpty)

        batcher.clear()

        XCTAssertEqual(batcher.bufferedSampleCount, 0)
        XCTAssertTrue(batcher.flushRemainder().isEmpty)
    }

    private func samples(count: Int, startingAt start: Int) -> [Float] {
        (start..<(start + count)).map(Float.init)
    }
}
