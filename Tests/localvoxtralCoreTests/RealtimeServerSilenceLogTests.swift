import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import localvoxtralTestSupport
@testable import localvoxtralCore

#if DEBUG
/// A speechd or External URL server that hangs with its socket open sends no
/// error and no close: the client says so in the Backends log while audio
/// still goes out, once per stall, and again when events come back (#1866).
final class RealtimeServerSilenceLogTests: XCTestCase {
    private let urlSession = URLSession(configuration: .ephemeral)

    override func tearDown() {
        urlSession.invalidateAndCancel()
        super.tearDown()
    }

    /// 250 ms of 16 kHz mono PCM16, a step the clock adds up exactly.
    private let chunk = Data(repeating: 0, count: 8_000)

    func testServerSilenceWhileAudioGoesOutIsLoggedOnceThenItsEnd() async {
        let clock = ManualSessionClock()
        let client = RealtimeAPIWebSocketClient(clock: clock.clock)
        let task = urlSession.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/v1/realtime")!)
        client.debugPrimeConnectedStateForTesting(task: task, hasReceivedSessionCreated: true)
        addTeardownBlock { client.disconnect() }

        // 4 s without an event is still speech.
        for _ in 0..<16 {
            client.sendAudioChunk(chunk)
            clock.advance(by: 0.25)
        }
        client.debugHandleFrameForTesting(json: ["type": "transcription.delta", "delta": "run"])
        XCTAssertEqual(client.debugServerSilenceLogForTesting(), [])

        // Then 8 s of audio and nothing back: one line, at 5 s.
        for _ in 0..<32 {
            client.sendAudioChunk(chunk)
            clock.advance(by: 0.25)
        }
        let silent = client.debugServerSilenceLogForTesting()
        XCTAssertEqual(silent.count, 1, "\(silent)")
        XCTAssertTrue(
            silent.first?.hasPrefix("realtime server silent: no server event for 5.0s; 5.2s of audio sent since") ?? false,
            "\(silent)")

        client.debugHandleFrameForTesting(json: ["type": "transcription.delta", "delta": " the tests"])
        XCTAssertEqual(
            client.debugServerSilenceLogForTesting().last,
            "realtime server resumed after 8.0s of silence (transcription.delta)")
        XCTAssertEqual(client.debugServerSilenceLogForTesting().count, 2)
    }

    /// The silence is measured on the clock's uptime, not its wall time: a
    /// time change mid-dictation neither hides a stall nor invents one
    /// (review of #1869; `MistralStreamHealth` wants a monotonic clock).
    func testServerSilenceIsMeasuredOnUptimeNotWallTime() async {
        let manual = ManualSessionClock()
        let wallJumpedBack = Date(timeIntervalSinceReferenceDate: 0)
        let client = RealtimeAPIWebSocketClient(
            clock: SessionClock(
                sleep: manual.clock.sleep,
                now: { wallJumpedBack },
                uptime: { manual.now.timeIntervalSinceReferenceDate }))
        let task = urlSession.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/v1/realtime")!)
        client.debugPrimeConnectedStateForTesting(task: task, hasReceivedSessionCreated: true)
        addTeardownBlock { client.disconnect() }

        for _ in 0..<32 {
            client.sendAudioChunk(chunk)
            manual.advance(by: 0.25)
        }

        let silent = client.debugServerSilenceLogForTesting()
        XCTAssertEqual(silent.count, 1, "\(silent)")
    }
}
#endif
