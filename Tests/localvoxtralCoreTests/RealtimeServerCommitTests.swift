import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import localvoxtralTestSupport
@testable import localvoxtralCore

#if DEBUG
/// The realtime client's commits against each server's commit rules (#1135):
/// vLLM answers a final commit only when a run is going, and speechd answers
/// only the final one. The Mistral client has its own commit and is not here.
final class RealtimeServerCommitTests: XCTestCase {
    /// What crossed the wire: the server's answers not yet handed back, the
    /// commits the client sent, and the events it raised. The client's
    /// callbacks hold this, never the harness: the client's timers can fire
    /// after a test has ended.
    private final class Line: @unchecked Sendable {
        let server: RealtimeServerModel
        let lock = NSLock()
        var outbox: [[String: Any]] = []
        var sentCommits: [Bool] = []
        var heard: [RealtimeEvent] = []

        init(_ server: RealtimeServerModel) {
            self.server = server
        }

        func serverReceives(_ text: String) {
            let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            let answers = server.receive(text)
            lock.lock()
            if json?["type"] as? String == "input_audio_buffer.commit" {
                sentCommits.append(json?["final"] as? Bool ?? false)
            }
            outbox.append(contentsOf: answers)
            lock.unlock()
        }

        func hear(_ event: RealtimeEvent) {
            lock.lock()
            heard.append(event)
            lock.unlock()
        }
    }

    /// The client wired to a server model: every frame the client sends
    /// reaches the model, and `pump()` hands the model's answers back.
    private final class Harness: @unchecked Sendable {
        let client = RealtimeAPIWebSocketClient()
        let server: RealtimeServerModel
        private let line: Line
        private let session: URLSession
        private let task: URLSessionWebSocketTask
        private var lock: NSLock { line.lock }

        init(_ kind: RealtimeServerModel.Kind) {
            let model = RealtimeServerModel(kind)
            server = model
            let wire = Line(model)
            line = wire
            session = URLSession(configuration: .ephemeral)
            task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/test")!)
            client.debugObserveTransmits { _, text in wire.serverReceives(text) }
            client.setEventHandler { event, _ in wire.hear(event) }
            client.debugPrimeConnectedStateForTesting(task: task, modelName: "model")
            client.debugSetGenerationTrackingState(hasUncommittedAudio: false, isGenerationInProgress: false)
            client.debugHandleFrameForTesting(json: ["type": "session.created"])
            pump()
            lock.lock()
            line.heard.removeAll()
            lock.unlock()
        }

        deinit {
            client.debugObserveTransmits(nil)
            task.cancel()
            session.invalidateAndCancel()
        }

        /// Hands the client every frame the server has sent, in order.
        func pump() {
            while true {
                lock.lock()
                guard !line.outbox.isEmpty else {
                    lock.unlock()
                    return
                }
                let frame = line.outbox.removeFirst()
                lock.unlock()
                client.debugHandleFrameForTesting(json: frame)
            }
        }

        func deliver(_ frames: [[String: Any]]) {
            for frame in frames { client.debugHandleFrameForTesting(json: frame) }
        }

        /// Appends `count` chunks of 100 ms.
        func sendAudio(chunks count: Int) {
            for _ in 0 ..< count { client.sendAudioChunk(Data(repeating: 1, count: 3_200)) }
        }

        /// Each commit frame the client sent: true for a final one.
        var commits: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return line.sentCommits
        }

        var finalTexts: [String] {
            events.compactMap { event -> String? in
                guard case .finalTranscript(let text) = event else { return nil }
                return text
            }
        }

        var finalizedCount: Int {
            events.filter { event in
                guard case .transcriptionFinalized = event else { return false }
                return true
            }.count
        }

        var events: [RealtimeEvent] {
            lock.lock()
            defer { lock.unlock() }
            return line.heard
        }
    }

    // MARK: - vLLM

    /// A voice memo: every chunk, then the final commit, with no run going.
    func testAVLLMFinalCommitWithNoRunGoingIsAnswered() {
        let harness = Harness(.vllm)
        harness.sendAudio(chunks: 3)

        harness.client.sendCommit(final: true)
        harness.pump()

        XCTAssertEqual(harness.finalTexts, ["9600 bytes"], "vLLM never answered the final commit")
        XCTAssertEqual(harness.finalizedCount, 1)
        XCTAssertEqual(harness.commits, [false, true], "a non-final commit starts the run the final one ends")
    }

    /// A stop right after a run ended at its limit, before the next periodic
    /// commit: the tail is in no run until the stop starts one.
    func testAVLLMStopRightAfterARunEndedAtItsLimitTranscribesTheTail() {
        let harness = Harness(.vllm)
        harness.sendAudio(chunks: 2)
        harness.client.sendCommit(final: false)
        harness.pump()
        harness.deliver(harness.server.endRunAtLimit())
        harness.sendAudio(chunks: 1)

        harness.client.sendCommit(final: true)
        harness.pump()

        XCTAssertEqual(harness.finalTexts, ["6400 bytes", "3200 bytes"], "the tail was never transcribed")
        XCTAssertEqual(harness.finalizedCount, 1)
        XCTAssertEqual(harness.commits, [false, false, true])
    }

    /// A stop while the periodic commit's run is going sends the final commit
    /// alone, as before: a second non-final commit would start nothing.
    func testAVLLMStopWithARunGoingSendsOnlyTheFinalCommit() {
        let harness = Harness(.vllm)
        harness.sendAudio(chunks: 2)
        harness.client.sendCommit(final: false)
        harness.sendAudio(chunks: 1)

        harness.client.sendCommit(final: true)
        harness.pump()

        XCTAssertEqual(harness.commits, [false, true])
        XCTAssertEqual(harness.finalTexts, ["9600 bytes"])
        XCTAssertEqual(harness.finalizedCount, 1)
    }

    // MARK: - speechd

    /// The bundled helper ignores the non-final commit: one `done`, over all
    /// the audio, as on main.
    func testASpeechdFinalCommitWithNoRunGoingIsAnsweredOnceOverAllTheAudio() {
        let harness = Harness(.speechd)
        harness.sendAudio(chunks: 3)

        harness.client.sendCommit(final: true)
        harness.pump()

        XCTAssertEqual(harness.finalTexts, ["9600 bytes"])
        XCTAssertEqual(harness.finalizedCount, 1)
    }

    func testASpeechdDictationStopIsAnsweredOnceOverAllTheAudio() {
        let harness = Harness(.speechd)
        harness.sendAudio(chunks: 2)
        harness.client.sendCommit(final: false)
        harness.pump()
        harness.sendAudio(chunks: 1)

        harness.client.sendCommit(final: true)
        harness.pump()

        XCTAssertEqual(harness.commits, [false, true])
        XCTAssertEqual(harness.finalTexts, ["9600 bytes"])
        XCTAssertEqual(harness.finalizedCount, 1)
    }
}
#endif
