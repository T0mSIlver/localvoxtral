import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import XCTest
@testable import localvoxtralCore

/// "… send that to <name>" (#723 step 3): the phrase, and which route a
/// named session is reached by. The dictation around it is
/// `AddressedSendWiringTests`' job.
final class AddressedSendTests: XCTestCase {
    private static let epoch = Date(timeIntervalSince1970: 3_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    // MARK: - The phrase

    func testThePhraseEndsTheDictationAndFollowsText() {
        let cases: [(String, AddressedDictation?)] = [
            ("Run the tests, send that to payments.", .init(text: "Run the tests", spokenName: "payments")),
            ("fix it  Send That To Local Voxtral!", .init(text: "fix it", spokenName: "Local Voxtral")),
            (
                "send that to the parser, then send that to cool roentgen twenty one",
                .init(text: "send that to the parser, then", spokenName: "cool roentgen twenty one")
            ),
            ("  add a test; send that to web.  ", .init(text: "add a test", spokenName: "web")),
            // Nothing to send.
            ("send that to payments", nil),
            (". send that to payments", nil),
            // A sentence, not a name.
            ("deploy it and send that to the staging server when ready", nil),
            ("run the tests and send that to", nil),
            ("run the tests and send that to ...", nil),
            ("run the tests and send it to payments", nil),
            ("send that to payments and run the tests", nil),
            ("", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SessionVoiceCommandParser.addressedDictation(in: text), expected, text)
        }
    }

    func testTheWholeTextStaysAGoToOrANaming() {
        XCTAssertEqual(SessionVoiceCommandParser.command(in: "go to payments"), .goTo("payments"))
        XCTAssertNil(SessionVoiceCommandParser.addressedDictation(in: "go to payments"))
        XCTAssertNil(SessionVoiceCommandParser.command(in: "fix it send that to payments"))
    }

    // MARK: - The route

    @MainActor
    func testAnOpencodeSessionWithAFreshRelayIsReachedThroughIt() async {
        let registry = registry()
        let address = OpencodePromptRelayAddress(port: 41_000, token: String(repeating: "0f", count: 32))
        registry.ingest(opencodeRecord(.sessionStart), origin: local)
        registry.ingest(opencodeRecord(.focusChanged, relay: address), origin: local)
        let session = try? XCTUnwrap(registry.liveSessions().first)

        guard let session, case .prompt(let route) = await resolver(registry).addressedRoute(for: session) else {
            return XCTFail("an opencode session with a relay has a prompt route")
        }
        XCTAssertEqual(route.name, "opencode prompt relay")
    }

    @MainActor
    func testAHerdrPaneIsWrittenOnlyWhileTheSessionsAgentIsItsForeground() async throws {
        // herdr's focus is on another pane: the named one need not be in front.
        let named = FakeHerdrSocket.focusedPane("w1:p2") { [(9001, "claude")] }
        let herdr = try FakeHerdrSocket { request in
            if request.method == "pane.current" {
                return .result(#"{"type":"pane_current","pane":{"pane_id":"w1:p9","focused":true}}"#)
            }
            return named(request)
        }
        defer { herdr.stop() }
        let registry = registry()
        registry.ingest(herdrRecord("s1", pid: 9001, pane: "w1:p2", socket: herdr.socketPath), origin: local)
        let session = try XCTUnwrap(registry.liveSessions().first)

        guard case .prompt(let route) = await resolver(registry).addressedRoute(for: session) else {
            return XCTFail("the pane runs the session's agent")
        }
        let appended = await route.deliver(.append("run the tests"))
        let submitted = await route.deliver(.submit)

        XCTAssertEqual(appended, .delivered)
        XCTAssertEqual(submitted, .delivered)
        XCTAssertEqual(herdr.writes, [
            .init(method: "pane.send_text", paneID: "w1:p2", text: "run the tests", keys: nil),
            .init(method: "pane.send_keys", paneID: "w1:p2", text: nil, keys: ["enter"]),
        ], "the session's own pane, not herdr's focused one")
    }

    @MainActor
    func testARefusedHerdrWriteStaysInHistoryAndIsNeverTyped() async throws {
        let herdr = try FakeHerdrSocket(
            answer: FakeHerdrSocket.focusedPane("w1:p2", foreground: { [(9001, "claude")] }) { _ in
                .error("pane_send_failed")
            }
        )
        defer { herdr.stop() }
        let registry = registry()
        registry.ingest(herdrRecord("s1", pid: 9001, pane: "w1:p2", socket: herdr.socketPath), origin: local)
        let session = try XCTUnwrap(registry.liveSessions().first)

        guard case .prompt(let route) = await resolver(registry).addressedRoute(for: session) else {
            return XCTFail("the pane runs the session's agent")
        }
        let appended = await route.deliver(.append("run the tests"))
        let unsendable = await route.deliver(.append("two\nlines"))

        XCTAssertEqual(appended, .keepInHistory, "keys would reach the focused app, not the named pane")
        XCTAssertEqual(unsendable, .keepInHistory)
    }

    @MainActor
    func testAHerdrPaneBackAtItsShellOrSharedWithAnotherHerdrIsNotWritten() async throws {
        let shell = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { [(500, "zsh")] })
        defer { shell.stop() }
        let atTheShell = registry()
        atTheShell.ingest(herdrRecord("s1", pid: 9001, pane: "w1:p2", socket: shell.socketPath), origin: local)

        let other = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { [(9001, "claude")] })
        defer { other.stop() }
        let twoHerdrs = registry()
        twoHerdrs.ingest(herdrRecord("s1", pid: 9001, pane: "w1:p2", socket: other.socketPath), origin: local)
        twoHerdrs.ingest(herdrRecord("s2", pid: 9002, pane: "w1:p3", socket: shell.socketPath), origin: local)

        for (registry, label) in [(atTheShell, "agent not foreground"), (twoHerdrs, "two live herdrs")] {
            let session = try XCTUnwrap(registry.liveSessions().first { $0.sessionID == "s1" })
            guard case .unsupported(.herdr) = await resolver(registry).addressedRoute(for: session) else {
                XCTFail(label)
                continue
            }
        }
        XCTAssertEqual(shell.writes, [])
        XCTAssertEqual(other.writes, [])
    }

    @MainActor
    func testATerminalTabIsFocusedAndEverythingElseIsUnsupported() async {
        let registry = registry()
        let resolver = resolver(registry)
        var tab = ClaudeSessionSnapshot(sessionID: "tab", origin: local, firstSeen: Self.epoch)
        tab.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: "/dev/ttys004", termProgram: "ghostty")
        var desktop = tab
        desktop.process?.desktopSessionID = "local_x"
        var cmux = tab
        cmux.process?.cmuxSurfaceID = "surface-1"
        let remote = ClaudeSessionSnapshot(
            sessionID: "far", origin: .remote(channel: "host-a"), firstSeen: Self.epoch
        )

        guard case .terminalPane = await resolver.addressedRoute(for: tab) else {
            return XCTFail("a plain terminal tab is focused, typed into, then Return")
        }
        let cases: [(ClaudeSessionSnapshot, SessionPaneFocusUnsupported)] = [
            (desktop, .claudeDesktop), (cmux, .cmux), (remote, .remote),
        ]
        for (session, expected) in cases {
            guard case .unsupported(let reason) = await resolver.addressedRoute(for: session) else {
                XCTFail("\(expected)")
                continue
            }
            XCTAssertEqual(reason, expected)
        }
    }

    // MARK: - Helpers

    private func registry() -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(now: { Self.epoch }, isProcessAlive: { _ in true })
    }

    @MainActor
    private func resolver(_ registry: ClaudeSessionRegistry) -> ClaudeSessionJoinResolver {
        let client = HerdrSocketClient(timeout: 2)
        return ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in nil },
            herdrClientProbe: { _ in true },
            herdrPanes: client,
            herdrPaneWriter: client
        )
    }

    private func herdrRecord(_ session: String, pid: Int32, pane: String, socket: String) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: .sessionStart, sessionID: session, timestamp: 0, rawCwd: "/repo", prompt: nil, files: [],
            process: ClaudeHookProcessInfo(
                hookPID: pid, claudePID: pid, tty: "/dev/ttys-\(session)",
                herdrPaneID: pane, herdrSocketPath: socket
            )
        )
    }

    private func opencodeRecord(
        _ event: ClaudeHookEvent,
        relay: OpencodePromptRelayAddress? = nil
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: event,
            agent: .opencode,
            sessionID: "ses_a",
            timestamp: 0,
            process: ClaudeHookProcessInfo(hookPID: 4242, claudePID: 4242, tty: "/dev/ttys004"),
            promptRelay: relay
        )
    }
}
