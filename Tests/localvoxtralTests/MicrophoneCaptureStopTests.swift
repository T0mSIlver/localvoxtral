import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// The controller stops capture, then flushes the chunk buffer once. A chunk
/// the input callback queued just before the stop must reach the handler
/// before `stop()` returns: delivered later, it misses that flush (the tail
/// is lost) or lands in the next session's buffer.
final class MicrophoneCaptureStopTests: XCTestCase {
    func testStopDeliversAQueuedChunkBeforeReturning() {
        let service = MicrophoneCaptureService()
        let stopReturned = DispatchSemaphore(value: 0)
        let log = Mutex<[String]>([])
        let delivered = expectation(description: "chunk delivered")
        let stopped = expectation(description: "stop returned")

        // Holds the processing queue until stop returns, so the next chunk is
        // still queued while stop runs. A stop that waits for the queue never
        // returns on its own; the timeout releases it then, and either way
        // the order logged below is the same.
        service.deliverCapturedChunk(Data([0])) { _ in
            _ = stopReturned.wait(timeout: .now() + 0.5)
        }
        service.deliverCapturedChunk(Data([1, 2])) { chunk in
            log.withLock { $0.append("chunk \(chunk.count) bytes") }
            delivered.fulfill()
        }

        DispatchQueue.global().async {
            service.stop()
            log.withLock { $0.append("stop returned") }
            stopReturned.signal()
            stopped.fulfill()
        }
        wait(for: [delivered, stopped], timeout: 10)

        XCTAssertEqual(log.withLock { $0 }, ["chunk 2 bytes", "stop returned"])
    }
}
