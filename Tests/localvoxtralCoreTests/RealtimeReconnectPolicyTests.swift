import Foundation
import XCTest

@testable import localvoxtralCore

/// The reconnect schedule (#380) and the audio buffer it is sized against,
/// with no session. `RealtimeReconnectTests` drives the reconnect itself.
final class RealtimeReconnectPolicyTests: XCTestCase {
    // MARK: - Policy

    func testBackoffGrowsAndIsCapped() {
        let policy = RealtimeReconnectPolicy.default
        let waits = (1...policy.maxAttempts).map { policy.backoff(beforeAttempt: $0) }

        XCTAssertEqual(waits.first, policy.initialBackoff)
        for (earlier, later) in zip(waits, waits.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later, earlier, "backoff must not shrink")
        }
        XCTAssertTrue(
            waits.allSatisfy { $0 <= policy.maxBackoff },
            "no wait may exceed the cap, got \(waits)"
        )
    }

    func testTheAudioBufferOutlastsTheWorstCaseRun() {
        // The replay promise only holds if the gap fits in the buffer: a run
        // that reconnects within its cap must never have dropped audio.
        XCTAssertGreaterThan(
            Double(AudioChunkBuffer.maxRetainedSeconds),
            RealtimeReconnectPolicy.default.worstCaseDuration
        )
    }

    // MARK: - Audio buffer retention

    func testBufferKeepsTheMostRecentAudioWhenItOverflows() {
        let buffer = AudioChunkBuffer(maxRetainedBytes: 8)
        buffer.append(Data([1, 2, 3, 4, 5, 6]))
        buffer.append(Data([7, 8, 9, 10, 11, 12]))

        XCTAssertEqual(buffer.bufferedByteCount, 8)
        XCTAssertEqual(Array(buffer.takeAll()), [5, 6, 7, 8, 9, 10, 11, 12])
    }

    func testBufferTrimsOnSampleBoundariesSoPCM16DoesNotShift() {
        // An odd retention limit must round DOWN to an even byte count, or
        // every sample after a trim is read a byte out of phase.
        let buffer = AudioChunkBuffer(maxRetainedBytes: 5)
        buffer.append(Data([1, 2, 3, 4, 5, 6, 7, 8]))

        XCTAssertEqual(buffer.bufferedByteCount, 4)
        XCTAssertEqual(Array(buffer.takeAll()), [5, 6, 7, 8])
    }
}
