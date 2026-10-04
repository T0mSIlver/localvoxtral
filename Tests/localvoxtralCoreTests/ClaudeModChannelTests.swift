import ClaudeContextWire
import ClaudeHookPublisherCore
import Foundation
import XCTest
import localvoxtralTestSupport
@testable import localvoxtralCore

#if canImport(Darwin) || canImport(Glibc)

/// A reply timeout that fires only when the test says so.
private final class GateSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var onSleep: (@Sendable () -> Void)?

    var sleep: @Sendable (Duration) async -> Void {
        { [self] _ in
            await withCheckedContinuation { continuation in
                lock.withLock { waiting.append(continuation) }
                lock.withLock { onSleep }?()
            }
        }
    }

    /// Calls `body` each time something starts waiting.
    func whenSleeping(_ body: @escaping @Sendable () -> Void) {
        lock.withLock { onSleep = body }
    }

    func fire() {
        lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiting = [] }
            return waiting
        }.forEach { $0.resume() }
    }
}

/// A bool both a test and the client's thread read.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    var isSet: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// A clock the test moves by hand.
private final class ManualSeconds: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    /// Called on every read, outside the lock.
    var onRead: (@Sendable () -> Void)?

    var now: TimeInterval {
        get {
            let read = lock.withLock { value }
            onRead?()
            return read
        }
        set { lock.withLock { value = newValue } }
    }
}

/// Lines one end of a channel received, with an expectation per line.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []
    var onLine: (@Sendable () -> Void)?

    func append(_ line: Data) {
        lock.withLock { lines.append(line) }
        onLine?()
    }

    var all: [Data] { lock.withLock { lines } }
}

/// The hub alone: which channel a send uses, and what a reply may answer.
final class ClaudeModChannelHubTests: XCTestCase {
    private func channel(_ written: Received, closed: XCTestExpectation? = nil) -> ClaudeModChannelHub.Channel {
        .init(write: { written.append($0); return true }, close: { closed?.fulfill() })
    }

    func testASendToASessionWithNoChannelAnswersNilAndWritesNothing() async {
        let hub = ClaudeModChannelHub(sleep: { _ in })
        let written = Received()
        _ = hub.attach(sessionID: "other", channel: channel(written))

        let reply = await hub.send(.init(kind: .ping), to: "sess-1", timeout: .seconds(1))

        XCTAssertNil(reply)
        XCTAssertTrue(written.all.isEmpty, "a send never falls back to another session")
    }

    func testAReplyForAnotherSessionIsDroppedAndTheTimeoutAnswers() async {
        let gate = GateSleep()
        let hub = ClaudeModChannelHub(sleep: gate.sleep, makeID: { "id-1" })
        let written = Received()
        _ = hub.attach(sessionID: "sess-1", channel: channel(written))
        gate.whenSleeping {
            hub.deliver(.init(sessionID: "sess-2", id: "id-1", ok: true))
            gate.fire()
        }

        let reply = await hub.send(.init(kind: .ping), to: "sess-1", timeout: .seconds(1))

        XCTAssertNil(reply)
        XCTAssertEqual(written.all.count, 1)
    }

    func testTheMatchingReplyAnswersTheSend() async {
        // The timeout never fires before the reply, so only the reply can
        // answer. A reply that never comes fires it after the cap, so the
        // test fails instead of hanging.
        let gate = GateSleep()
        let hub = ClaudeModChannelHub(sleep: gate.sleep, makeID: { "id-1" })
        let written = Received()
        written.onLine = { hub.deliver(.init(sessionID: "sess-1", id: "id-1", ok: false, reason: "dialog")) }
        _ = hub.attach(sessionID: "sess-1", channel: channel(written))
        let answered = BoundedWait()
        let watchdog = Task { if await !answered.value(failAfter: 10) { gate.fire() } }

        let reply = await hub.send(.init(kind: .ping), to: "sess-1", timeout: .seconds(60))
        answered.resolve()
        gate.fire()
        await watchdog.value

        XCTAssertEqual(reply, .init(sessionID: "sess-1", id: "id-1", ok: false, reason: "dialog"))
        let sent = try? XCTUnwrap(written.all.first)
        XCTAssertEqual(
            sent.flatMap { ClaudeModChannelWire.decode(ClaudeModChannelWire.Message.self, from: $0.dropLast()) },
            .init(kind: .ping, id: "id-1")
        )
    }

    /// Two publishers for one session (it is open in two windows) must not
    /// take the channel from each other: the second is refused until the
    /// first is gone.
    func testASecondAttachIsRefusedWhileTheFirstIsOpen() {
        let hub = ClaudeModChannelHub(sleep: { _ in })
        let token = hub.attach(sessionID: "sess-1", channel: channel(Received()))
        XCTAssertNotNil(token)
        XCTAssertNil(hub.attach(sessionID: "sess-1", channel: channel(Received())))

        hub.detach(sessionID: "sess-1", token: token ?? 0)
        XCTAssertNotNil(hub.attach(sessionID: "sess-1", channel: channel(Received())))
    }

    func testAFullHubRefusesANewSession() {
        let hub = ClaudeModChannelHub(maxChannels: 1, sleep: { _ in })
        XCTAssertNotNil(hub.attach(sessionID: "sess-1", channel: channel(Received())))
        XCTAssertNil(hub.attach(sessionID: "sess-2", channel: channel(Received())))
    }

    func testADetachAnswersNilToTheSendStillWaiting() async {
        let gate = GateSleep()
        let hub = ClaudeModChannelHub(sleep: gate.sleep)
        let token = hub.attach(sessionID: "sess-1", channel: channel(Received()))
        gate.whenSleeping { hub.detach(sessionID: "sess-1", token: token ?? 0) }

        let reply = await hub.send(.init(kind: .ping), to: "sess-1", timeout: .seconds(1))

        XCTAssertNil(reply)
        XCTAssertFalse(hub.isAttached("sess-1"))
    }
}

/// The wire: what tells its lines from hook records, and what it refuses.
final class ClaudeModChannelWireTests: XCTestCase {
    func testAHookRecordQuotingTheKeyIsNotAnAttach() throws {
        let record = ClaudeHookRecord(
            event: .userPromptSubmit, sessionID: "sess-1", timestamp: 1, rawCwd: "/repo",
            prompt: #"why does "mod_attach" fail"#
        )
        let line = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))
        XCTAssertFalse(ClaudeModChannelWire.isAttach(line.dropLast()))
        XCTAssertFalse(ClaudeModChannelWire.isReply(line.dropLast()))
    }

    func testAnotherVersionAndAnUnknownKindDoNotDecode() {
        XCTAssertNil(ClaudeModChannelWire.decode(
            ClaudeModChannelWire.Message.self, from: Data(#"{"mod_message":2,"kind":"ping","id":"a"}"#.utf8)
        ))
        XCTAssertNil(ClaudeModChannelWire.decode(
            ClaudeModChannelWire.Message.self, from: Data(#"{"mod_message":1,"kind":"rm -rf","id":"a"}"#.utf8)
        ))
        XCTAssertEqual(
            ClaudeModChannelWire.decode(
                ClaudeModChannelWire.Message.self, from: Data(#"{"mod_message":1,"kind":"ping","id":"a"}"#.utf8)
            ),
            .init(kind: .ping, id: "a")
        )
    }
}

/// End to end over a real socket: the production `--attach` client, broker
/// and hub.
final class ClaudeModChannelSocketTests: XCTestCase {
    private var directory: URL!
    private var broker: ClaudeContextBroker!
    private var registry: ClaudeSessionRegistry!
    private var hub: ClaudeModChannelHub!

    private var socketPath: String { directory.appendingPathComponent("ctx.sock").path }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: "/tmp/lvx-\(UUID().uuidString.prefix(8))")
        registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 5_000_000) },
            isProcessAlive: { _ in true }
        )
        hub = ClaudeModChannelHub(sleep: { _ in try? await Task.sleep(for: .seconds(30)) })
        broker = ClaudeContextBroker(socketPath: socketPath, registry: registry, modChannels: hub)
        try broker.start()
    }

    override func tearDownWithError() throws {
        broker?.stop()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func announce(_ sessionID: String) throws {
        let ingested = expectation(description: "the session's first hook landed")
        broker.debugConfigureIngestHook { _ in ingested.fulfill() }
        let record = ClaudeHookRecord(event: .sessionStart, sessionID: sessionID, timestamp: 1, rawCwd: "/repo")
        XCTAssertNil(UnixSocketPublisher(timeout: 2).publish(
            line: try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record)), to: socketPath
        ))
        wait(for: [ingested], timeout: 5)
        broker.debugConfigureIngestHook(nil)
    }

    private func client(
        _ sessionID: String, output: Received, parentAlive: Flag? = nil, clock: ManualSeconds = ManualSeconds()
    ) -> ClaudeModAttachClient {
        ClaudeModAttachClient(
            socketPath: socketPath,
            sessionID: sessionID,
            claudePID: getpid(),
            output: { output.append($0) },
            isParentAlive: { parentAlive?.isSet ?? true },
            sleep: { _ in },
            parentCheckInterval: 0.05,
            attachReplyTimeout: 5,
            now: { clock.now }
        )
    }

    func testASessionNoHookHasNamedCannotAttach() {
        XCTAssertEqual(client("never-seen", output: Received()).attachOnce(), ClaudeModAttachClient.Outcome.refused)
        XCTAssertFalse(hub.isAttached("never-seen"))
    }

    func testAPingCrossesTheChannelAndItsReplyComesBack() async throws {
        try announce("sess-1")
        let attached = expectation(description: "attached")
        hub.debugConfigureAttachHook { if $0 { attached.fulfill() } }
        let output = Received()
        let alive = Flag(true)
        let attach = client("sess-1", output: output, parentAlive: alive)
        let outcome = Task.detached { attach.attachOnce() }
        await fulfillment(of: [attached], timeout: 5)

        // The mod: answer each message it reads with `--mod-reply`.
        let socketPath = socketPath
        output.onLine = {
            guard let line = output.all.last,
                  let message = ClaudeModChannelWire.decode(ClaudeModChannelWire.Message.self, from: line.dropLast()),
                  let reply = ClaudeModChannelWire.encodeLine(
                      ClaudeModChannelWire.Reply(sessionID: "sess-1", id: message.id, ok: true)
                  )
            else { return }
            ClaudeModAttachClient.sendReply(reply, to: socketPath, publisher: UnixSocketPublisher(timeout: 2))
        }
        let reply = await hub.send(.init(kind: .ping), to: "sess-1", timeout: .seconds(30))

        XCTAssertEqual(reply?.ok, true)
        XCTAssertEqual(reply?.sessionID, "sess-1")

        let detached = expectation(description: "detached")
        hub.debugConfigureAttachHook { if !$0 { detached.fulfill() } }
        alive.isSet = false
        let ended = await outcome.value
        await fulfillment(of: [detached], timeout: 5)
        XCTAssertEqual(ended, ClaudeModAttachClient.Outcome.parentGone)
        XCTAssertFalse(hub.isAttached("sess-1"))
    }

    func testASecondPublisherForTheSameSessionIsRefusedNotSwapped() async throws {
        try announce("sess-1")
        let attached = expectation(description: "attached")
        hub.debugConfigureAttachHook { if $0 { attached.fulfill() } }
        let alive = Flag(true)
        let first = client("sess-1", output: Received(), parentAlive: alive)
        let outcome = Task.detached { first.attachOnce() }
        await fulfillment(of: [attached], timeout: 5)
        hub.debugConfigureAttachHook(nil)

        XCTAssertEqual(client("sess-1", output: Received()).attachOnce(), ClaudeModAttachClient.Outcome.refused)
        XCTAssertTrue(hub.isAttached("sess-1"), "the first channel is still the session's")

        alive.isSet = false
        _ = await outcome.value
    }

    func testStoppingTheAppEndsTheChannelSoTheClientAttachesAgain() async throws {
        try announce("sess-1")
        let attached = expectation(description: "attached")
        hub.debugConfigureAttachHook { if $0 { attached.fulfill() } }
        let attach = client("sess-1", output: Received())
        let outcome = Task.detached { attach.attachOnce() }
        await fulfillment(of: [attached], timeout: 5)

        broker.stop()

        let ended = await outcome.value
        XCTAssertEqual(ended, ClaudeModAttachClient.Outcome.closed)
    }

    /// The mod's `bye` on `session.end` (#1646): the app answers it down the
    /// channel, closes it, and the session is gone from the registry.
    func testAByeClosesTheChannelAndEndsTheSession() async throws {
        try announce("sess-1")
        let attached = expectation(description: "attached")
        hub.debugConfigureAttachHook { if $0 { attached.fulfill() } }
        let output = Received()
        let attach = client("sess-1", output: output)
        let outcome = Task.detached { attach.attachOnce() }
        await fulfillment(of: [attached], timeout: 5)
        let detached = expectation(description: "detached")
        hub.debugConfigureAttachHook { if !$0 { detached.fulfill() } }

        let bye = try XCTUnwrap(ClaudeModChannelWire.encodeLine(ClaudeModChannelWire.Bye(sessionID: "sess-1")))
        ClaudeModAttachClient.sendReply(bye, to: socketPath, publisher: UnixSocketPublisher(timeout: 2))

        let ended = await outcome.value
        await fulfillment(of: [detached], timeout: 5)
        XCTAssertEqual(ended, ClaudeModAttachClient.Outcome.closed)
        let told = try XCTUnwrap(output.all.last)
        XCTAssertEqual(ClaudeModChannelWire.decode(ClaudeModChannelWire.Message.self, from: told.dropLast())?.kind, .bye)
        XCTAssertNil(registry.snapshot(sessionID: "sess-1"))
    }

    func testAByeForASessionWithNoChannelEndsNothing() throws {
        try announce("sess-1")
        XCTAssertFalse(hub.bye(sessionID: "sess-1"))
        XCTAssertNotNil(registry.snapshot(sessionID: "sess-1"))
    }

    /// An app that took the attach and never answered it: the attach gives
    /// up at its deadline, so `run()` retries, instead of waiting for as
    /// long as Claude Code lives.
    func testAnUnacknowledgedAttachTimesOutAndRetries() async throws {
        try announce("sess-1")
        let entered = expectation(description: "the app took the attach")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        broker.debugConfigureServeHook {
            entered.fulfill()
            release.wait()
        }
        let answered = expectation(description: "the attach gave up")
        let alive = Flag(true)
        let clock = ManualSeconds()
        // The client's first read sets its reply deadline (#1669): moving
        // the clock before it would only move the deadline.
        let deadlineRead = expectation(description: "the client read its reply deadline")
        deadlineRead.assertForOverFulfill = false
        clock.onRead = { deadlineRead.fulfill() }
        let attach = client("sess-1", output: Received(), parentAlive: alive, clock: clock)
        let outcome = Task.detached {
            let outcome = attach.attachOnce()
            answered.fulfill()
            return outcome
        }
        await fulfillment(of: [entered, deadlineRead], timeout: 5)

        clock.now = 6
        await fulfillment(of: [answered], timeout: 5)

        // Ends the attach if it is still waiting, so a failure cannot hang.
        alive.isSet = false
        let ended = await outcome.value
        XCTAssertEqual(ended, ClaudeModAttachClient.Outcome.refused)
    }

    /// A connection accepted before the stop and served after its sweep must
    /// not register: nothing would close it, and its session could not
    /// attach again after a restart.
    func testAnAttachServedAfterTheStopIsRefused() async throws {
        try announce("sess-1")
        let entered = expectation(description: "the connection is being served")
        let release = DispatchSemaphore(value: 0)
        broker.debugConfigureServeHook {
            entered.fulfill()
            release.wait()
        }
        // Fulfilled by whichever comes first: the hub taking the channel,
        // or the client hearing no.
        let settled = expectation(description: "the attach was answered")
        settled.assertForOverFulfill = false
        hub.debugConfigureAttachHook { if $0 { settled.fulfill() } }
        let alive = Flag(true)
        let attach = client("sess-1", output: Received(), parentAlive: alive)
        let outcome = Task.detached {
            let outcome = attach.attachOnce()
            settled.fulfill()
            return outcome
        }
        await fulfillment(of: [entered], timeout: 5)

        broker.stop()
        release.signal()
        await fulfillment(of: [settled], timeout: 5)

        XCTAssertFalse(hub.isAttached("sess-1"), "no channel registers after the shutdown sweep")
        alive.isSet = false
        let ended = await outcome.value
        XCTAssertEqual(ended, ClaudeModAttachClient.Outcome.refused)
    }
}

#endif
