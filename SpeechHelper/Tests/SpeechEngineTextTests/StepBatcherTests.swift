import XCTest

@testable import SpeechEngineText

final class StepBatcherTests: XCTestCase {
    func testCadenceBoundaryExactlyAtThreshold() {
        var batcher = StepBatcher(cadenceMilliseconds: 100)

        let batches = batcher.append(samples(count: 1_600, startingAt: 0))

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

        let batches = batcher.append(samples(count: 1_601, startingAt: 0))

        XCTAssertEqual(batches, [samples(count: 1_600, startingAt: 0)])
        XCTAssertEqual(batcher.bufferedSampleCount, 1)
        XCTAssertEqual(batcher.flushRemainder(), [1_600])
    }

    func testLargeAppendYieldsMultipleBatchesInOrder() {
        var batcher = StepBatcher(cadenceMilliseconds: 100)

        let batches = batcher.append(samples(count: 3_500, startingAt: 0))

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
