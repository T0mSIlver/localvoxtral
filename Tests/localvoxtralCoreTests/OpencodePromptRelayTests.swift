import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import Synchronization
import XCTest
@testable import localvoxtralCore

/// The opencode prompt relay (#719), up to the HTTP it speaks: where its
/// address may come from (an opencode focus declaration, fresh, from the pid
/// the session runs under) and how a dictation's writes reach it (in order,
/// and back to the keyboard on the first failure). The dictation around it
/// is `DictationPipelineTests`' job.
/// A value tests change between steps; closures capture the box, never a
/// `Mutex`, which cannot be captured by an escaping closure.
private final class Box<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
    func get() -> Value { value.withLock { $0 } }
    func set(_ newValue: Value) { value.withLock { $0 = newValue } }
}

final class OpencodePromptRelayTests: XCTestCase {
    private static let epoch = Date(timeIntervalSince1970: 3_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let tty = "/dev/ttys004"
    private let opencodePID: Int32 = 4242
    private let address = OpencodePromptRelayAddress(port: 41_000, token: String(repeating: "0f", count: 32))

    private func record(
        _ event: ClaudeHookEvent,
        session: String = "ses_a",
        agent: ClaudeHookAgent = .opencode,
        pid: Int32? = nil,
        tty: String? = nil,
        relay: OpencodePromptRelayAddress? = nil
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: event,
            agent: agent,
            sessionID: session,
            timestamp: 0,
            process: ClaudeHookProcessInfo(
                hookPID: pid ?? opencodePID, claudePID: pid ?? opencodePID, tty: tty
            ),
            promptRelay: relay
        )
    }

    private func roundTrip(_ record: ClaudeHookRecord) throws -> ClaudeHookRecord {
        try ClaudeHookWireCodec.decodeLine(try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record)))
    }

    // MARK: - Wire

    func testOnlyAnOpencodeFocusDeclarationCarriesAWellFormedRelay() throws {
        XCTAssertEqual(try roundTrip(record(.focusChanged, tty: tty, relay: address)).promptRelay, address)

        XCTAssertNil(try roundTrip(record(.sessionStart, relay: address)).promptRelay)
        XCTAssertNil(try roundTrip(record(.focusChanged, agent: .claude, tty: tty, relay: address)).promptRelay)
        for malformed in [
            OpencodePromptRelayAddress(port: 0, token: address.token),
            OpencodePromptRelayAddress(port: 70_000, token: address.token),
            OpencodePromptRelayAddress(port: 41_000, token: "short"),
            OpencodePromptRelayAddress(port: 41_000, token: String(repeating: "0F", count: 32)),
        ] {
            let decoded = try roundTrip(record(.focusChanged, tty: tty, relay: malformed))
            XCTAssertNil(decoded.promptRelay, "\(malformed)")
            XCTAssertEqual(decoded.process?.tty, tty, "the declaration stands without its relay")
        }
    }

    func testARelayThatDoesNotDecodeLosesTheFieldNotTheRecord() throws {
        let line = #"{"v":2,"event":"FocusChanged","agent":"opencode","session_id":"ses_a","ts":0,"files":[],"process":{"hook_pid":4242,"claude_pid":4242,"tty":"/dev/ttys004"},"prompt_relay":{"port":"x"}}"#
        let decoded = try ClaudeHookWireCodec.decodeLine(Data(line.utf8))
        XCTAssertEqual(decoded.event, .focusChanged)
        XCTAssertNil(decoded.promptRelay)
    }

    // MARK: - Registry

    func testTheRelayComesFromAFreshDeclarationByTheSessionsOwnPid() {
        let clock = Box(Self.epoch)
        let registry = ClaudeSessionRegistry(now: { clock.get() }, isProcessAlive: { _ in true })
        registry.ingest(record(.sessionStart), origin: local)
        XCTAssertNil(registry.opencodePromptRelay(sessionID: "opencode:ses_a"), "no declaration, no relay")
        XCTAssertFalse(registry.hasFreshOpencodePromptRelay())

        registry.ingest(record(.focusChanged, tty: tty, relay: address), origin: local)
        XCTAssertEqual(
            registry.opencodePromptRelay(sessionID: "opencode:ses_a"),
            OpencodePromptRelay(address: address, opencodeSessionID: "ses_a"),
            "the relay names opencode's own, unscoped id"
        )
        XCTAssertTrue(registry.hasFreshOpencodePromptRelay())

        // Another process declaring the same session is refused at ingest,
        // and cannot swap the relay.
        let impostor = OpencodePromptRelayAddress(port: 41_001, token: address.token)
        XCTAssertNil(registry.ingest(record(.focusChanged, pid: 999, tty: "/dev/ttys009", relay: impostor), origin: local))
        XCTAssertEqual(registry.opencodePromptRelay(sessionID: "opencode:ses_a")?.address, address)

        clock.set(Self.epoch.addingTimeInterval(ClaudeRegistryLimits.defaultFocusDeclarationTTL + 1))
        XCTAssertNil(registry.opencodePromptRelay(sessionID: "opencode:ses_a"), "a stale declaration is no address")
        XCTAssertFalse(registry.hasFreshOpencodePromptRelay())
    }

    func testARetractedFocusTakesItsRelayAlong() {
        let registry = ClaudeSessionRegistry(now: { Self.epoch }, isProcessAlive: { _ in true })
        registry.ingest(record(.sessionStart), origin: local)
        registry.ingest(record(.focusChanged, tty: tty, relay: address), origin: local)
        registry.ingest(record(.focusCleared, tty: tty), origin: local)
        XCTAssertNil(registry.opencodePromptRelay(sessionID: "opencode:ses_a"))
    }

    // MARK: - Resolver

    @MainActor
    func testOnlyAPaneWhoseTTYResolvesToADeclaringOpencodeSessionHasARelay() async {
        let registry = ClaudeSessionRegistry(now: { Self.epoch }, isProcessAlive: { _ in true })
        registry.ingest(record(.sessionStart), origin: local)
        registry.ingest(record(.focusChanged, tty: tty, relay: address), origin: local)
        let ghostty = TerminalScreenTarget(pid: 77, bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        let focusedTTY = Box<String?>(tty)
        let resolver = ClaudeSessionJoinResolver(
            registry: registry, focusedTerminalTTY: { _ in focusedTTY.get() }
        )

        let relay = await resolver.opencodePromptRelay(target: ghostty)
        XCTAssertEqual(relay?.opencodeSessionID, "ses_a")
        let editor = TerminalScreenTarget(pid: 78, bundleID: "com.apple.TextEdit")
        let editorRelay = await resolver.opencodePromptRelay(target: editor)
        XCTAssertNil(editorRelay, "not a supported terminal")
        focusedTTY.set("/dev/ttys005")
        let otherPaneRelay = await resolver.opencodePromptRelay(target: ghostty)
        XCTAssertNil(otherPaneRelay, "another pane")
    }

    // MARK: - Sink over HTTP

    @MainActor
    func testAppendsLandInOrderAndTheSubmitFollowsThem() async throws {
        let server = try FakeOpencodePromptRelay()
        addTeardownBlock { server.stop() }
        var fellBack: [String] = []
        let sink = OpencodePromptRelaySink(relay: server.relay(sessionID: "ses_a")) { fellBack.append($0) }

        sink.append("run the ")
        sink.append("tests")
        sink.submit()
        let arrived = await server.waitForCalls(3)
        XCTAssertTrue(arrived, "calls so far: \(server.calls)")
        await sink.waitUntilIdle()

        XCTAssertEqual(server.calls.map(\.path), ["/tui/append-prompt", "/tui/append-prompt", "/tui/submit-prompt"])
        XCTAssertEqual(server.calls.map(\.text), ["run the ", "tests", nil])
        XCTAssertEqual(Set(server.calls.map(\.sessionID)), ["ses_a"])
        XCTAssertEqual(Set(server.calls.map(\.authorization)), ["Bearer \(server.token)"])
        XCTAssertEqual(Set(server.calls.map(\.method)), ["POST"])
        XCTAssertTrue(sink.isHealthy)
        XCTAssertEqual(fellBack, [])
    }

    @MainActor
    func testTheFirstRefusalSendsItsTextAndEverythingAfterToTheKeyboard() async throws {
        // The relay refuses the second append (the pane switched session).
        let server = try FakeOpencodePromptRelay { call in call.text == "second " ? 409 : 200 }
        addTeardownBlock { server.stop() }
        var fellBack: [String] = []
        let sink = OpencodePromptRelaySink(relay: server.relay(sessionID: "ses_a")) { fellBack.append($0) }

        sink.append("first ")
        sink.append("second ")
        sink.append("third ")
        sink.submit()
        await sink.waitUntilIdle()
        sink.append("fourth")
        sink.submit()

        XCTAssertEqual(server.calls.compactMap(\.text), ["first ", "second "], "nothing is sent after a refusal")
        XCTAssertEqual(fellBack, ["second ", "third ", "fourth"], "in order, the refused call's text first")
        XCTAssertFalse(sink.isHealthy)
        XCTAssertFalse(server.calls.contains { $0.path == "/tui/submit-prompt" }, "no submit after a refusal")
    }

    @MainActor
    func testARefusedConnectionSendsEveryAppendToTheKeyboard() async throws {
        let port = try unusedLoopbackPort()
        let relay = OpencodePromptRelay(
            address: OpencodePromptRelayAddress(port: Int(port), token: address.token),
            opencodeSessionID: "ses_a"
        )
        var fellBack: [String] = []
        let sink = OpencodePromptRelaySink(relay: relay) { fellBack.append($0) }

        sink.append("hello ")
        sink.append("world")
        sink.submit()
        await sink.waitUntilIdle()

        XCTAssertEqual(fellBack, ["hello ", "world"])
        XCTAssertFalse(sink.isHealthy)
    }

    @MainActor
    func testARefusedTextGoesToTheFallbackNamedWhenItWasHandedOff() async throws {
        let server = try FakeOpencodePromptRelay { _ in 502 }
        addTeardownBlock { server.stop() }
        var sinkFallback: [String] = []
        var overlayTarget: [String] = []
        let sink = OpencodePromptRelaySink(relay: server.relay(sessionID: "ses_a")) { sinkFallback.append($0) }

        sink.append("committed text") { overlayTarget.append($0) }
        sink.append("later")
        await sink.waitUntilIdle()

        XCTAssertEqual(overlayTarget, ["committed text"])
        XCTAssertEqual(sinkFallback, ["later"])
    }
}
