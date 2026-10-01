import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import localvoxtralTestSupport
@testable import localvoxtralCore

#if DEBUG
/// A vLLM realtime session past `max_model_len` turns to garbage and can
/// kill the server (#1139). The client rolls the session over before the
/// limit: the retiring socket's final commit, its `done`, a fresh socket with
/// the audio sent meanwhile, and one dictation out of it all.
final class RealtimeContextRolloverTests: XCTestCase {
    /// 100 tokens: 8 s of audio fit, a pause rolls over from 4.8 s, the
    /// margin forces it at 6.8 s.
    private static let budget = RealtimeContextBudget(maxModelLen: 100)
    private static let chunkBytes = 3_200

    // MARK: - The server

    /// vLLM's `/v1/realtime` with a context limit, one session per socket.
    /// A non-final commit starts the run, which reads audio as it arrives; a
    /// final commit queues the end of the audio, and the run answers it with
    /// one `done` naming the bytes it transcribed. Audio past the limit is
    /// never transcribed: the real server writes garbage there, then dies.
    private final class LimitedServer: @unchecked Sendable {
        private struct Session {
            var queue: [Int?] = []
            var isRunning = false
            var runBytes = 0
            var contextBytes = 0
        }

        let limitBytes: Int
        private let lock = NSLock()
        private var sessions: [ObjectIdentifier: Session] = [:]
        private(set) var sessionOrder: [ObjectIdentifier] = []
        /// Bytes that reached a session past its limit.
        private(set) var overflowBytes = 0
        /// Audio bytes each session was sent, in session order.
        private var sessionAudio: [ObjectIdentifier: Int] = [:]

        init(limitBytes: Int) {
            self.limitBytes = limitBytes
        }

        var audioPerSession: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return sessionOrder.map { sessionAudio[$0] ?? 0 }
        }

        var overflowed: Int {
            lock.lock()
            defer { lock.unlock() }
            return overflowBytes
        }

        func receive(_ text: String, on task: URLSessionWebSocketTask) -> [[String: Any]] {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                return []
            }
            let id = ObjectIdentifier(task)
            lock.lock()
            defer { lock.unlock() }
            if sessions[id] == nil {
                sessions[id] = Session()
                sessionOrder.append(id)
            }
            var session = sessions[id]!
            defer { sessions[id] = session }
            switch json["type"] as? String {
            case "input_audio_buffer.append":
                let bytes = (json["audio"] as? String).flatMap { Data(base64Encoded: $0) }?.count ?? 0
                sessionAudio[id, default: 0] += bytes
                session.queue.append(bytes)
            case "input_audio_buffer.commit":
                if json["final"] as? Bool == true {
                    session.queue.append(nil)
                } else if !session.isRunning {
                    session.isRunning = true
                    session.runBytes = 0
                }
            default:
                return []
            }
            return drain(&session)
        }

        private func drain(_ session: inout Session) -> [[String: Any]] {
            guard session.isRunning else { return [] }
            while !session.queue.isEmpty {
                guard let bytes = session.queue.removeFirst() else {
                    session.isRunning = false
                    let text = "\(session.runBytes) bytes"
                    session.runBytes = 0
                    return [["type": "transcription.done", "text": text]]
                }
                let room = max(0, limitBytes - session.contextBytes)
                session.runBytes += min(bytes, room)
                overflowBytes += max(0, bytes - room)
                session.contextBytes += bytes
            }
            return []
        }
    }

    // MARK: - The harness

    /// The client wired to the server, and to a session that follows the
    /// handover the way `DictationSessionController.handle(event:from:)`
    /// does: it hears only the connection it is on.
    private final class Harness: @unchecked Sendable {
        let clock = ManualSessionClock()
        let client: RealtimeAPIWebSocketClient
        let server: LimitedServer
        private let urlSession = URLSession(configuration: .ephemeral)
        private let lock = NSLock()
        /// The server's answers, each with the connection it answers on.
        private var outbox: [(json: [String: Any], generation: RealtimeConnectionGeneration)] = []
        /// While set, `pump` hands back no `done`: the server is still
        /// transcribing.
        private var holdsDones = false
        /// Resolved when the session hears its first rollover.
        let rolledOver = BoundedWait()
        private var heard: [(RealtimeEvent, RealtimeConnectionGeneration)] = []
        private var sessionGeneration: RealtimeConnectionGeneration = .none
        private var accepted: [RealtimeEvent] = []
        private var commits: [Bool] = []
        private var needsHandshake = false
        private var sockets: [URLSessionWebSocketTask] = []

        init(budget: RealtimeContextBudget? = RealtimeContextRolloverTests.budget) {
            server = LimitedServer(limitBytes: (budget ?? RealtimeContextRolloverTests.budget).capacityBytes)
            client = RealtimeAPIWebSocketClient(clock: clock.clock)
            let first = urlSession.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/v1/realtime")!)
            sockets.append(first)
            client.debugObserveTransmits { [weak self] task, text in
                guard let self else { return }
                // Read outside the client's lock: the observer runs after it.
                self.serverReceives(text, on: task, generation: self.client.connectionGeneration)
            }
            client.setEventHandler { [weak self] event, generation in self?.hear(event, from: generation) }
            client.debugSetRolloverSocket { [weak self] in
                guard let self else { fatalError("harness gone") }
                return self.openSocket()
            }
            client.debugPrimeConnectedStateForTesting(task: first, modelName: "voxtral")
            client.debugSetGenerationTrackingState(hasUncommittedAudio: false, isGenerationInProgress: false)
            client.setContextBudget(budget)
            lock.lock()
            sessionGeneration = client.connectionGeneration
            lock.unlock()
            client.debugHandleFrameForTesting(json: ["type": "session.created"])
            pump()
        }

        deinit {
            client.debugObserveTransmits(nil)
            client.debugSetRolloverSocket(nil)
            sockets.forEach { $0.cancel() }
            urlSession.invalidateAndCancel()
        }

        private func openSocket() -> URLSessionWebSocketTask {
            let task = urlSession.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/v1/realtime")!)
            lock.lock()
            sockets.append(task)
            needsHandshake = true
            lock.unlock()
            return task
        }

        private func serverReceives(
            _ text: String, on task: URLSessionWebSocketTask, generation: RealtimeConnectionGeneration
        ) {
            let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            let answers = server.receive(text, on: task)
            lock.lock()
            if json?["type"] as? String == "input_audio_buffer.commit" {
                commits.append(json?["final"] as? Bool ?? false)
            }
            outbox.append(contentsOf: answers.map { ($0, generation) })
            lock.unlock()
        }

        func holdDones(_ holds: Bool) {
            lock.lock()
            holdsDones = holds
            lock.unlock()
        }

        /// The socket the client holds now.
        var currentSocket: URLSessionWebSocketTask {
            lock.lock()
            defer { lock.unlock() }
            return sockets.last!
        }

        private func hear(_ event: RealtimeEvent, from generation: RealtimeConnectionGeneration) {
            lock.lock()
            defer { lock.unlock() }
            heard.append((event, generation))
            guard generation == sessionGeneration else { return }
            if case .sessionRolledOver(let next) = event {
                sessionGeneration = next
                rolledOver.resolve()
            }
            accepted.append(event)
        }

        /// Plays the server's side: its answers, and the new socket's
        /// handshake once a rollover opened one.
        func pump() {
            while true {
                lock.lock()
                if needsHandshake {
                    needsHandshake = false
                    lock.unlock()
                    client.debugHandleFrameForTesting(json: ["type": "session.created"])
                    continue
                }
                guard let next = outbox.first,
                      !(holdsDones && next.json["type"] as? String == "transcription.done")
                else {
                    lock.unlock()
                    return
                }
                outbox.removeFirst()
                lock.unlock()
                client.debugHandleFrameForTesting(json: next.json, from: next.generation)
            }
        }

        /// `seconds` of audio in 100 ms chunks, as the send loop delivers it.
        /// While `talking`, the server streams a word for each chunk; silent,
        /// it writes nothing.
        func speak(seconds: Double, talking: Bool = true) {
            for _ in 0 ..< Int((seconds * 10).rounded()) {
                client.sendAudioChunk(Data(repeating: 1, count: RealtimeContextRolloverTests.chunkBytes))
                clock.advance(by: 0.1)
                pump()
                if talking {
                    client.debugHandleFrameForTesting(json: ["type": "transcription.delta", "delta": " word"])
                }
            }
        }

        var sentCommits: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return commits
        }

        /// What the session took in, in order.
        var events: [RealtimeEvent] {
            lock.lock()
            defer { lock.unlock() }
            return accepted
        }

        /// Everything the client raised, from any connection.
        var allEvents: [(RealtimeEvent, RealtimeConnectionGeneration)] {
            lock.lock()
            defer { lock.unlock() }
            return heard
        }

        var finals: [String] {
            events.compactMap {
                guard case .finalTranscript(let text) = $0 else { return nil }
                return text
            }
        }

        /// The bytes the session's finals say were transcribed.
        var transcribedBytes: Int {
            finals.compactMap { Int($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }
                .reduce(0, +)
        }

        var rollovers: Int {
            events.filter {
                guard case .sessionRolledOver = $0 else { return false }
                return true
            }.count
        }

        var finalizedCount: Int {
            events.filter {
                guard case .transcriptionFinalized = $0 else { return false }
                return true
            }.count
        }

        var errorsOrDrops: [RealtimeEvent] {
            events.filter {
                switch $0 {
                case .error, .disconnected: return true
                default: return false
                }
            }
        }
    }

    // MARK: - One dictation past the limit

    /// The proof #1139 asks for: a take of 20 s against a server that holds
    /// 8 s, spoken without a pause, comes out whole from one dictation, and
    /// no session ever ran past the limit.
    func testATakeLongerThanTheContextLimitIsTranscribedWhole() {
        let harness = Harness()
        harness.speak(seconds: 0.1)
        harness.client.sendCommit(final: false)
        harness.pump()
        harness.speak(seconds: 19.9)

        harness.client.sendCommit(final: true)
        harness.pump()

        let total = 200 * Self.chunkBytes
        XCTAssertEqual(harness.server.overflowed, 0, "a session ran past max_model_len")
        XCTAssertEqual(harness.transcribedBytes, total, "finals: \(harness.finals)")
        XCTAssertEqual(harness.finalizedCount, 1)
        XCTAssertGreaterThanOrEqual(harness.rollovers, 2)
        XCTAssertTrue(harness.errorsOrDrops.isEmpty, "\(harness.errorsOrDrops)")
        for audio in harness.server.audioPerSession {
            XCTAssertLessThanOrEqual(audio, Self.budget.forceBytes + Self.chunkBytes)
        }
    }

    /// Without a budget (speechd, Mistral, a server that lists no models)
    /// the session never rolls over.
    func testWithoutABudgetTheSessionNeverRollsOver() {
        let harness = Harness(budget: nil)
        harness.speak(seconds: 0.1)
        harness.client.sendCommit(final: false)
        harness.speak(seconds: 9.9)

        harness.client.sendCommit(final: true)
        harness.pump()

        XCTAssertEqual(harness.rollovers, 0)
        XCTAssertEqual(harness.server.audioPerSession.count, 1)
        XCTAssertGreaterThan(harness.server.overflowed, 0, "the limited server cuts this take short")
    }

    // MARK: - Where the seam falls

    /// Inside the window, a pause rolls the session over before the margin.
    func testAPauseInsideTheWindowRollsTheSessionOver() {
        let harness = Harness()
        harness.speak(seconds: 0.1)
        harness.client.sendCommit(final: false)
        harness.speak(seconds: 5.0)
        XCTAssertEqual(harness.rollovers, 0, "talking through the window rolls nothing over")

        harness.speak(seconds: 1.0, talking: false)

        XCTAssertEqual(harness.rollovers, 1)
        let first = harness.server.audioPerSession.first ?? 0
        XCTAssertLessThan(first, Self.budget.forceBytes, "the pause came before the margin")
        XCTAssertGreaterThanOrEqual(first, Self.budget.pauseWindowBytes)
    }

    /// A pause before the window rolls nothing over.
    func testAPauseBeforeTheWindowRollsNothingOver() {
        let harness = Harness()
        harness.speak(seconds: 0.1)
        harness.client.sendCommit(final: false)
        harness.speak(seconds: 2.0)
        harness.speak(seconds: 2.0, talking: false)

        XCTAssertEqual(harness.rollovers, 0)
    }

    /// The next socket's first word starts a word of its own: a fresh server
    /// session writes it with no leading space.
    func testTheNextSocketsFirstWordIsSpacedFromTheLast() {
        let harness = Harness()
        harness.speak(seconds: 0.1)
        harness.client.sendCommit(final: false)
        harness.speak(seconds: 5.0)
        harness.speak(seconds: 1.0, talking: false)
        XCTAssertEqual(harness.rollovers, 1)

        harness.client.debugHandleFrameForTesting(json: ["type": "transcription.delta", "delta": "Next"])
        harness.client.debugHandleFrameForTesting(json: ["type": "transcription.delta", "delta": " one"])

        let partials = harness.events.compactMap { event -> String? in
            guard case .partialTranscript(let text) = event else { return nil }
            return text
        }
        XCTAssertEqual(Array(partials.suffix(2)), [" Next", " one"])
    }

    // MARK: - The handover

    /// The rollover's final commit ends the run the periodic commit started,
    /// and the next socket's run starts with the carried audio: no final
    /// commit is ever sent with no run going (#1135).
    func testEveryFinalCommitHasARunToEnd() {
        let harness = Harness()
        harness.speak(seconds: 0.1)
        harness.client.sendCommit(final: false)
        harness.speak(seconds: 7.0)
        XCTAssertEqual(harness.rollovers, 1)

        harness.client.sendCommit(final: true)
        harness.pump()

        XCTAssertEqual(harness.sentCommits, [false, true, false, true])
        XCTAssertEqual(harness.finalizedCount, 1)
    }

    /// A stop while the retiring socket's `done` is outstanding: the audio
    /// sent since goes to the next socket with the final commit, and the
    /// dictation finalizes once, on that socket's answer.
    func testAStopDuringTheRolloverFinalizesOnTheNextSocket() {
        let harness = Harness()
        harness.holdDones(true)
        harness.speak(seconds: 0.1)
        harness.client.sendCommit(final: false)
        harness.speak(seconds: 7.0)
        harness.client.sendAudioChunk(Data(repeating: 1, count: Self.chunkBytes))

        harness.client.sendCommit(final: true)
        XCTAssertEqual(harness.finalizedCount, 0)
        harness.holdDones(false)
        harness.pump()

        XCTAssertEqual(harness.rollovers, 1)
        XCTAssertEqual(harness.finalizedCount, 1)
        XCTAssertEqual(harness.transcribedBytes, 72 * Self.chunkBytes, "finals: \(harness.finals)")
    }

    /// A stop during the rollover with nothing sent since: the retiring
    /// socket's `done` answers it, and no socket is opened.
    func testAStopDuringTheRolloverWithNothingCarriedFinalizesOnTheRetiringSocket() {
        let harness = Harness()
        harness.holdDones(true)
        harness.speak(seconds: 0.1)
        harness.client.sendCommit(final: false)
        harness.speak(seconds: 6.7)

        harness.client.sendCommit(final: true)
        harness.holdDones(false)
        harness.pump()

        XCTAssertEqual(harness.rollovers, 0)
        XCTAssertEqual(harness.finalizedCount, 1)
        XCTAssertEqual(harness.server.audioPerSession.count, 1)
        XCTAssertEqual(harness.transcribedBytes, 68 * Self.chunkBytes)
    }

    /// A retiring socket that never answers is left after the timeout, and
    /// the dictation carries on.
    func testARetiringSocketThatNeverAnswersIsLeftAfterTheTimeout() async {
        let harness = Harness()
        harness.holdDones(true)
        harness.speak(seconds: 0.1)
        harness.client.sendCommit(final: false)
        harness.speak(seconds: 6.7)
        await harness.clock.waitForSleepers(1)

        harness.clock.advance(by: 5)
        let rolledOver = await harness.rolledOver.value(failAfter: 10)

        XCTAssertTrue(rolledOver, "the watchdog never moved the session on")
        XCTAssertEqual(harness.rollovers, 1)
        XCTAssertTrue(harness.errorsOrDrops.isEmpty, "\(harness.errorsOrDrops)")
    }

    /// The retiring socket closing before its `done` (vLLM's 1012) moves the
    /// session on with the carried audio instead of through a reconnect.
    func testARetiringSocketThatClosesMovesOnWithTheCarriedAudio() {
        let harness = Harness()
        harness.holdDones(true)
        harness.speak(seconds: 0.1)
        harness.client.sendCommit(final: false)
        harness.speak(seconds: 7.0)

        harness.client.debugHandleTerminalSocketErrorForTesting(
            task: harness.currentSocket, errorMessage: "WebSocket closed (1012).")
        harness.pump()

        XCTAssertEqual(harness.rollovers, 1)
        XCTAssertTrue(harness.errorsOrDrops.isEmpty, "\(harness.errorsOrDrops)")
        XCTAssertEqual(harness.server.audioPerSession.last, 3 * Self.chunkBytes, "the carried audio")
    }

    /// A `done` the retiring socket was read for after the handover clears
    /// nothing on the next socket, and the session never hears it.
    func testTheRetiringSocketsLateDoneIsRefused() {
        let harness = Harness()
        harness.speak(seconds: 0.1)
        harness.client.sendCommit(final: false)
        harness.speak(seconds: 7.0)
        XCTAssertEqual(harness.rollovers, 1)
        let retiring = harness.allEvents.first { event, _ in
            if case .sessionRolledOver = event { return true }
            return false
        }!.1
        harness.holdDones(true)
        harness.client.sendCommit(final: true)
        let finalsBefore = harness.finals

        harness.client.debugHandleFrameForTesting(
            json: ["type": "transcription.done", "text": "late"], from: retiring)

        XCTAssertEqual(harness.finals, finalsBefore)
        XCTAssertEqual(harness.finalizedCount, 0)
        XCTAssertTrue(harness.client.debugStateSnapshot().isAwaitingFinalCommitDone)
    }

    // MARK: - The limit

    func testTheModelsURLSitsBesideTheRealtimeEndpoint() {
        XCTAssertEqual(
            RealtimeContextLimitProbe.modelsURL(forRealtimeEndpoint: URL(string: "ws://box:8000/v1/realtime")!),
            URL(string: "http://box:8000/v1/models"))
        XCTAssertEqual(
            RealtimeContextLimitProbe.modelsURL(forRealtimeEndpoint: URL(string: "wss://box/api/v1/realtime/?x=1")!),
            URL(string: "https://box/api/v1/models"))
        XCTAssertEqual(
            RealtimeContextLimitProbe.modelsURL(forRealtimeEndpoint: URL(string: "ws://box:9000/stream")!),
            URL(string: "http://box:9000/v1/models"))
    }

    func testTheLimitIsTheServedModelsMaxModelLen() {
        let body = Data("""
            {"object":"list","data":[
              {"id":"other","max_model_len":32768},
              {"id":"mistralai/Voxtral-Mini-4B-Realtime-2602","max_model_len":2048}
            ]}
            """.utf8)
        let budget = RealtimeContextLimitProbe.budget(
            fromModelsResponse: body, model: "mistralai/Voxtral-Mini-4B-Realtime-2602")
        XCTAssertEqual(budget, RealtimeContextBudget(maxModelLen: 2048, source: .reported))
        XCTAssertEqual(budget?.forceSeconds ?? 0, 139.264, accuracy: 0.001)
    }

    func testAListedModelWithoutALimitGetsTheDefault() {
        let body = Data(#"{"data":[{"id":"voxtral"}]}"#.utf8)
        XCTAssertEqual(
            RealtimeContextLimitProbe.budget(fromModelsResponse: body, model: "voxtral"),
            RealtimeContextBudget(maxModelLen: 2048, source: .defaulted))
    }

    func testAServerThatListsNoModelsGetsNoBudget() {
        XCTAssertNil(RealtimeContextLimitProbe.budget(fromModelsResponse: Data("not json".utf8), model: "m"))
        XCTAssertNil(RealtimeContextLimitProbe.budget(fromModelsResponse: Data(#"{"data":[]}"#.utf8), model: "m"))
    }

    func testTheProbeAsksTheModelsEndpointWithTheKey() async {
        let asked = LockedBox<URLRequest?>(nil)
        let configuration = RealtimeSessionConfiguration(
            endpoint: URL(string: "ws://box:8000/v1/realtime")!, apiKey: " key ", model: "voxtral")
        let budget = await RealtimeContextLimitProbe.budget(for: configuration) { request in
            asked.set(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"data":[{"id":"voxtral","max_model_len":4096}]}"#.utf8), response)
        }
        XCTAssertEqual(budget?.maxModelLen, 4096)
        XCTAssertEqual(asked.value?.url, URL(string: "http://box:8000/v1/models"))
        XCTAssertEqual(asked.value?.value(forHTTPHeaderField: "Authorization"), "Bearer key")
    }

    func testAFailedOrRefusedProbeGetsNoBudget() async {
        let configuration = RealtimeSessionConfiguration(
            endpoint: URL(string: "ws://box:8000/v1/realtime")!, apiKey: "", model: "voxtral")
        let failed = await RealtimeContextLimitProbe.budget(for: configuration) { _ in
            throw URLError(.cannotConnectToHost)
        }
        XCTAssertNil(failed)
        let refused = await RealtimeContextLimitProbe.budget(for: configuration) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"data":[{"id":"voxtral","max_model_len":4096}]}"#.utf8), response)
        }
        XCTAssertNil(refused)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
#endif
