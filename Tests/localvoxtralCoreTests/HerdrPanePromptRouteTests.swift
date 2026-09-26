import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import Synchronization
import XCTest
@testable import localvoxtralCore

/// The herdr pane route (#726) from the join to the socket: which joins get
/// one, what each call sends, and where a text goes when it is refused. A
/// real `HerdrSocketClient` resolves and writes against one fake herdr
/// socket. The dictation around it is `DictationPipelineTests`' job.
@MainActor
final class HerdrPanePromptRouteTests: XCTestCase {
    private nonisolated static let epoch = Date(timeIntervalSince1970: 3_000_000)
    private let ghostty = TerminalScreenTarget(pid: 4343, bundleID: TerminalScreenAllowlist.ghosttyBundleID)
    private let client = HerdrSocketClient(timeout: 2)
    private let claude: [(pid: Int32, name: String)] = [(9001, "claude")]

    /// A value tests change between steps.
    private final class Box<Value: Sendable>: Sendable {
        private let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
        func get() -> Value { value.withLock { $0 } }
        func set(_ newValue: Value) { value.withLock { $0 = newValue } }
    }

    private typealias Processes = [(pid: Int32, name: String)]

    private func registry(herdrSocket: String, tty: String = "/dev/ttys-inner") -> ClaudeSessionRegistry {
        let registry = ClaudeSessionRegistry(now: { Self.epoch }, isProcessAlive: { _ in true })
        XCTAssertNotNil(registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart, sessionID: "s1", timestamp: 0, rawCwd: "/repo", prompt: nil, files: [],
                process: ClaudeHookProcessInfo(
                    hookPID: 777, claudePID: 9001, tty: tty,
                    herdrPaneID: "w1:p2", herdrSocketPath: herdrSocket
                )
            ),
            origin: .localAuthenticated(peerUID: 501)
        ))
        return registry
    }

    private func resolver(
        _ registry: ClaudeSessionRegistry,
        focusedTTY: String = "/dev/ttys-outer"
    ) -> ClaudeSessionJoinResolver {
        ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in focusedTTY },
            herdrClientProbe: { _ in true },
            herdrPanes: client,
            herdrPaneWriter: client
        )
    }

    /// A herdr pane join over `herdr`, and its route with `frontmost` as the
    /// frontmost app's pid.
    private func joinedRoute(
        _ herdr: FakeHerdrSocket,
        frontmost: Box<pid_t?> = Box(4343),
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (join: ClaudeSessionJoin, route: HerdrPanePromptRoute, resolver: ClaudeSessionJoinResolver) {
        let resolver = resolver(registry(herdrSocket: herdr.socketPath))
        let resolved = await resolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved, file: file, line: line)
        XCTAssertEqual(join.mechanism, .herdrPane, file: file, line: line)
        let route = try XCTUnwrap(
            resolver.herdrPromptRoute(for: join) { frontmost.get() }, file: file, line: line
        )
        return (join, route, resolver)
    }

    func testAnAppendSendsTheTextToTheJoinedPaneAndASubmitPressesEnter() async throws {
        let claude = claude
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { claude })
        defer { herdr.stop() }
        let route = try await joinedRoute(herdr).route

        let appended = await route.deliver(.append("run the tests"))
        let submitted = await route.deliver(.submit)

        XCTAssertEqual(appended, .delivered)
        XCTAssertEqual(submitted, .delivered)
        XCTAssertEqual(herdr.writes, [
            .init(method: "pane.send_text", paneID: "w1:p2", text: "run the tests", keys: nil),
            .init(method: "pane.send_keys", paneID: "w1:p2", text: nil, keys: ["enter"]),
        ])
    }

    /// herdr writes the text to the pane byte for byte: a newline would press
    /// Enter and an escape would start a key sequence. Such text is never
    /// sent; with the pane in front, keystrokes type it.
    func testTextHoldingAControlCharacterIsNeverSent() async throws {
        let claude = claude
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { claude })
        defer { herdr.stop() }
        let route = try await joinedRoute(herdr).route

        for text in ["first line\nsecond", "tab\there", "esc\u{1B}[201~", "cr\r", "nul\u{0}"] {
            let appended = await route.deliver(.append(text))
            XCTAssertEqual(appended, .typeInstead, text.debugDescription)
        }
        let tooLong = await route.deliver(.append(String(repeating: "a", count: HerdrPanePromptRoute.maxAppendBytes + 1)))
        XCTAssertEqual(tooLong, .typeInstead)
        XCTAssertEqual(herdr.writes, [])
    }

    /// A refusal types the text only where keys would land in the pane: its
    /// terminal frontmost and herdr's focus on it. Otherwise it stays in
    /// History.
    func testARefusedTextIsTypedOnlyWhileThePaneIsInFront() async throws {
        let claude = claude
        let focused = Box("w1:p2")
        let herdr = try FakeHerdrSocket { request in
            if request.method == "pane.current" {
                return .result(#"{"type":"pane_current","pane":{"pane_id":"\#(focused.get())","focused":true}}"#)
            }
            if request.method == "pane.send_text" { return .error("pane_send_failed") }
            return FakeHerdrSocket.focusedPane("w1:p2") { claude }(request)
        }
        defer { herdr.stop() }
        let frontmost = Box<pid_t?>(4343)
        let route = try await joinedRoute(herdr, frontmost: frontmost).route

        let inFront = await route.deliver(.append("one"))
        frontmost.set(5151)
        let otherAppInFront = await route.deliver(.append("two"))
        frontmost.set(4343)
        focused.set("w1:p3")
        let otherPaneFocused = await route.deliver(.append("three"))

        XCTAssertEqual(inFront, .typeInstead)
        XCTAssertEqual(otherAppInFront, .keepInHistory)
        XCTAssertEqual(otherPaneFocused, .keepInHistory)
    }

    /// No answer after the request went out: it may have landed, so typing
    /// it would put it in twice.
    func testAWriteThatMayHaveLandedStaysInHistory() async throws {
        let claude = claude
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2", foreground: { claude }) { _ in .hangUp })
        defer { herdr.stop() }
        let route = try await joinedRoute(herdr).route

        let appended = await route.deliver(.append("run the tests"))

        XCTAssertEqual(appended, .keepInHistory)
    }

    /// The pane went back to its shell: an Enter would run the prompt as a
    /// command there, so none is sent.
    func testNoEnterOnceTheJoinedAgentLeftTheForeground() async throws {
        let foreground = Box<Processes>(claude)
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { foreground.get() })
        defer { herdr.stop() }
        let route = try await joinedRoute(herdr).route
        foreground.set([(8123, "zsh")])

        let submitted = await route.deliver(.submit)

        XCTAssertEqual(submitted, .keepInHistory)
        XCTAssertEqual(herdr.writes, [])
    }

    /// Through the sink: a refused append ends the route. Its text and the
    /// ones after it are typed in order, and the submit is dropped.
    func testThroughTheSinkARefusalTypesTheRestInOrderAndDropsTheSubmit() async throws {
        let claude = claude
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2", foreground: { claude }) { request in
            request.text == "two " ? .error("pane_send_failed") : .ok
        })
        defer { herdr.stop() }
        let route = try await joinedRoute(herdr).route
        var typed: [String] = []
        var kept: [String] = []
        let sink = AgentPromptSink(route: route, kept: { kept.append($0) }) { typed.append($0) }

        sink.append("one ")
        sink.append("two ")
        sink.append("three")
        sink.submit()
        await sink.waitUntilIdle()
        sink.append(" four")

        XCTAssertFalse(sink.isHealthy)
        XCTAssertEqual(typed, ["two ", "three", " four"])
        XCTAssertEqual(kept, [])
        XCTAssertEqual(herdr.writes.map(\.method), ["pane.send_text", "pane.send_text"])
        XCTAssertEqual(herdr.sentText, "one two ")
    }

    /// Only a herdr pane join yields a route: a pane joined by its TTY is
    /// written by keystrokes, never through a herdr socket its session named.
    func testAJoinByAnythingButAHerdrPaneHasNoRoute() async throws {
        let claude = claude
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { claude })
        defer { herdr.stop() }
        let resolver = resolver(registry(herdrSocket: herdr.socketPath, tty: "/dev/ttys003"), focusedTTY: "/dev/ttys003")

        let resolved = await resolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)

        XCTAssertEqual(join.mechanism, .ttyDevice)
        XCTAssertNil(resolver.herdrPromptRoute(for: join) { 4343 })
    }

    /// No writer installed, no route: the default a test that forgets to
    /// inject gets.
    func testAResolverWithoutAWriterHasNoRoute() async throws {
        let claude = claude
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { claude })
        defer { herdr.stop() }
        let resolver = ClaudeSessionJoinResolver(
            registry: registry(herdrSocket: herdr.socketPath),
            focusedTerminalTTY: { _ in "/dev/ttys-outer" },
            herdrClientProbe: { _ in true },
            herdrPanes: client
        )

        let resolved = await resolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)

        XCTAssertEqual(join.mechanism, .herdrPane)
        XCTAssertNil(resolver.herdrPromptRoute(for: join) { 4343 })
    }

    /// A remote pane's pids belong to another machine, so its Enter waits on
    /// the test the remote arm joins on: a foreground process named for the
    /// agent.
    func testARemotePaneJoinGatesEnterOnTheAgentsNameNotItsPid() async throws {
        let foreground = Box<Processes>(claude)
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { foreground.get() })
        defer { herdr.stop() }
        let (local, _, resolver) = try await joinedRoute(herdr)
        let remote = ClaudeSessionJoin(
            target: local.target,
            snapshot: local.snapshot,
            windowID: nil,
            mechanism: .remoteHerdrPane,
            herdrPane: local.herdrPane
        )
        let route = try XCTUnwrap(resolver.herdrPromptRoute(for: remote) { 4343 })

        foreground.set([(1, "claude")])
        let submittedWhileNamed = await route.deliver(.submit)
        foreground.set([(9001, "zsh")])
        let submittedAtTheShell = await route.deliver(.submit)

        XCTAssertEqual(submittedWhileNamed, .delivered)
        XCTAssertEqual(submittedAtTheShell, .keepInHistory, "the local pid means nothing for a remote pane")
        XCTAssertEqual(herdr.writes.count, 1)
    }
}
