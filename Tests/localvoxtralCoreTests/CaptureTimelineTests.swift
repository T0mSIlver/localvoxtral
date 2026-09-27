import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore

final class CaptureTimelineTests: XCTestCase {
    /// The first buffer lands on the capture queue, which can beat the
    /// socket; the line waits for both and is reported once.
    func testReportsOnceWhenTheSocketAndTheFirstBufferAreBothIn() {
        let pressed = Date(timeIntervalSinceReferenceDate: 0)
        let clock = Mutex(pressed)
        let lines = Mutex<[String]>([])
        let timeline = CaptureTimeline(
            pressedAt: pressed,
            now: { clock.withLock { $0 } },
            report: { line in lines.withLock { $0.append(line) } }
        )
        func at(_ ms: Double) { clock.withLock { $0 = pressed.addingTimeInterval(ms / 1000) } }

        at(12); timeline.markMicStarted()
        at(40); timeline.markFirstBuffer()
        at(41); timeline.markFirstBuffer()
        XCTAssertEqual(lines.withLock { $0 }, [], "no line before the socket opens")

        at(260); timeline.markSocketOpen()
        at(900); timeline.markFirstBuffer()
        timeline.markSocketOpen()

        XCTAssertEqual(lines.withLock { $0 }, [
            "capture timeline: socket open +260 ms, mic started +12 ms, first buffer +40 ms after the start",
        ])
    }
}
