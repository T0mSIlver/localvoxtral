import XCTest
@testable import localvoxtralCore

final class AlignedAudioSendScheduleTests: XCTestCase {
    /// Feeds 10 ms mic buffers (160 samples) and records where each send ends.
    private func sendEnds(afterCapturing totalSamples: Int) -> [Int] {
        var schedule = AlignedAudioSendSchedule()
        var buffered = 0
        var ends: [Int] = []
        for _ in 0..<(totalSamples / 160) {
            buffered += 160
            if case .send(let byteCount) = schedule.next(bufferedBytes: buffered * 2) {
                schedule.didSend(byteCount: byteCount)
                buffered -= byteCount / 2
                ends.append(schedule.sentSamples)
            }
        }
        return ends
    }

    func testEverySendEndsTenMillisecondsPastAnEightyMillisecondBoundary() {
        // 90, 170, 250 and 330 ms: the first append carries 90 ms, the rest 80.
        XCTAssertEqual(sendEnds(afterCapturing: 5_440), [1_440, 2_720, 4_000, 5_280])
    }

    func testABacklogGoesInOneAppendUpToTheLastBoundary() {
        var schedule = AlignedAudioSendSchedule()

        // 0.4 s captured while the socket opened.
        XCTAssertEqual(schedule.next(bufferedBytes: 6_400 * 2), .send(byteCount: 5_280 * 2))
        schedule.didSend(byteCount: 5_280 * 2)

        // 1,120 samples left; the next boundary, 6,560, is 10 ms of audio away.
        XCTAssertEqual(schedule.next(bufferedBytes: 1_120 * 2), .wait(.milliseconds(10)))
    }

    func testAnEmptyBufferWaitsForTheFirstBoundary() {
        XCTAssertEqual(AlignedAudioSendSchedule().next(bufferedBytes: 0), .wait(.milliseconds(90)))
    }
}
