import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import Synchronization
import XCTest
@testable import localvoxtralCore

/// The herdr pane route (#726) from the join to the socket: which joins get
/// one, what each call sends, and when it refuses. A real `HerdrSocketClient`
/// resolves and writes against one fake herdr socket. The dictation around
/// it is `DictationPipelineTests`' job.
@MainActor
final class HerdrPanePromptRouteTests: XCTestCase {
    private nonisolated static let epoch = Date(timeIntervalSince1970: 3_000_000)
    private let claudePID: Int32 = 9001
    private let ghostty = TerminalScreenTarget(pid: 4343, bundleID: TerminalScreenAllowlist.ghosttyBundleID)
    private let client = HerdrSocketClient(timeout: 2)

    private final class Foreground: Sendable {
        private let processes: Mutex<[(pid: Int32, name: String)]>
        init(_ processes: [(pid: Int32, name: String)]) { self.processes = Mutex(processes) }
        func get() -> [(pid: Int32, name: String)] { processes.withLock { $0 } }
        func set(_ newValue: [(pid: Int32, name: String)]) { processes.withLock { $0 = newValue } }
    }

    private func registry(herdrSocket: String, tty: String? = nil) -> ClaudeSessionRegistry {
        let registry = ClaudeSessionRegistry(now: { Self.epoch }, isProcessAlive: { _ in true })
        XCTAssertNotNil(registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart, sessionID: "s1", timestamp: 0, rawCwd: "/repo", prompt: nil, files: [],
                process: ClaudeHookProcessInfo(
                    hookPID: 777, claudePID: claudePID, tty: tty ?? "/dev/ttys-inner",
                    herdrPaneID: "w1:p2", herdrSocketPath: herdrSocket
                )
            ),
            origin: .localAuthenticated(peerUID: 501)
        ))
        return registry
    }

    private func resolver(_ registry: ClaudeSessionRegistry, focusedTTY: String = "/dev/ttys-outer") -> ClaudeSessionJoinResolver {
        ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in focusedTTY },
            herdrClientProbe: { _ in true },
            herdrPanes: client,
            herdrPaneWriter: client
        )
    }

    /// A herdr pane join and its route, over `herdr`.
    private func joinedRoute(
        _ herdr: FakeHerdrSocket, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> HerdrPanePromptRoute {
        let resolver = resolver(registry(herdrSocket: herdr.socketPath))
        let resolved = await resolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved, file: file, line: line)
        XCTAssertEqual(join.mechanism, .herdrPane, file: file, line: line)
        return try XCTUnwrap(resolver.herdrPromptRoute(for: join), file: file, line: line)
    }

    func testAnAppendSendsTheTextToTheJoinedPaneAndASubmitPressesEnter() async throws {
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { [(9001, "claude")] })
        defer { herdr.stop() }
        let route = try await joinedRoute(herdr)

        let appended = await route.deliver(.append("run the tests"))
        let submitted = await route.deliver(.submit)

        XCTAssertTrue(appended)
        XCTAssertTrue(submitted)
        XCTAssertEqual(herdr.writes, [
            .init(method: "pane.send_text", paneID: "w1:p2", text: "run the tests", keys: nil),
            .init(method: "pane.send_keys", paneID: "w1:p2", text: nil, keys: ["enter"]),
        ])
    }

    /// herdr writes the text to the pane byte for byte: a newline would press
    /// Enter and an escape would start a key sequence. Such text is refused
    /// before anything is sent, and goes by keystrokes.
    func testTextHoldingAControlCharacterIsRefusedUnsent() async throws {
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { [(9001, "claude")] })
        defer { herdr.stop() }
        let route = try await joinedRoute(herdr)

        for text in ["first line\nsecond", "tab\there", "esc\u{1B}[201~", "cr\r"] {
            let appended = await route.deliver(.append(text))
            XCTAssertFalse(appended, text.debugDescription)
        }
        let tooLong = await route.deliver(.append(String(repeating: "a", count: HerdrPanePromptRoute.maxAppendBytes + 1)))
        XCTAssertFalse(tooLong)
        XCTAssertEqual(herdr.writes, [])
    }

    /// The pane went back to its shell: an Enter would run the prompt as a
    /// command there, so none is sent.
    func testNoEnterOnceTheJoinedAgentLeftTheForeground() async throws {
        let foreground = Foreground([(9001, "claude")])
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { foreground.get() })
        defer { herdr.stop() }
        let route = try await joinedRoute(herdr)
        foreground.set([(8123, "zsh")])

        let submitted = await route.deliver(.submit)

        XCTAssertFalse(submitted)
        XCTAssertEqual(herdr.writes, [])
    }

    /// Through the sink: a refused append ends the route. Its text and the
    /// ones after it go to the fallback in order, and the submit is dropped.
    func testARefusedWriteSendsTheRestToTheFallbackAndDropsTheSubmit() async throws {
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2", foreground: { [(9001, "claude")] }) { request in
            request.text == "two " ? .error("pane_send_failed") : .ok
        })
        defer { herdr.stop() }
        let route = try await joinedRoute(herdr)
        var typed: [String] = []
        let sink = AgentPromptSink(route: route) { typed.append($0) }

        sink.append("one ")
        sink.append("two ")
        sink.append("three")
        sink.submit()
        await sink.waitUntilIdle()
        sink.append(" four")

        XCTAssertFalse(sink.isHealthy)
        XCTAssertEqual(typed, ["two ", "three", " four"])
        XCTAssertEqual(herdr.writes.map(\.method), ["pane.send_text", "pane.send_text"])
        XCTAssertEqual(herdr.sentText, "one two ")
    }

    /// Only a herdr pane join yields a route: a pane joined by its TTY is
    /// written by keystrokes, never through a herdr socket its session named.
    func testAJoinByAnythingButAHerdrPaneHasNoRoute() async throws {
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { [(9001, "claude")] })
        defer { herdr.stop() }
        let resolver = resolver(registry(herdrSocket: herdr.socketPath, tty: "/dev/ttys003"), focusedTTY: "/dev/ttys003")

        let resolved = await resolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)

        XCTAssertEqual(join.mechanism, .ttyDevice)
        XCTAssertNil(resolver.herdrPromptRoute(for: join))
    }

    /// No writer installed, no route: the default a test that forgets to
    /// inject gets.
    func testAResolverWithoutAWriterHasNoRoute() async throws {
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { [(9001, "claude")] })
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
        XCTAssertNil(resolver.herdrPromptRoute(for: join))
    }

    /// A remote pane's pids belong to another machine, so its Enter waits on
    /// the test the remote arm joins on: a foreground process named for the
    /// agent.
    func testARemotePaneJoinGatesEnterOnTheAgentsNameNotItsPid() async throws {
        let foreground = Foreground([(9001, "claude")])
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { foreground.get() })
        defer { herdr.stop() }
        let resolver = resolver(registry(herdrSocket: herdr.socketPath))
        let resolved = await resolver.resolve(target: ghostty)
        let local = try XCTUnwrap(resolved)
        // Another machine's pid that happens to differ from the registered one.
        foreground.set([(1, "claude")])
        let remote = ClaudeSessionJoin(
            target: local.target,
            snapshot: local.snapshot,
            windowID: nil,
            mechanism: .remoteHerdrPane,
            herdrPane: local.herdrPane
        )
        let route = try XCTUnwrap(resolver.herdrPromptRoute(for: remote))

        let submittedWhileNamed = await route.deliver(.submit)
        foreground.set([(9001, "zsh")])
        let submittedAtTheShell = await route.deliver(.submit)

        XCTAssertTrue(submittedWhileNamed)
        XCTAssertFalse(submittedAtTheShell, "the local pid means nothing for a remote pane")
        XCTAssertEqual(herdr.writes.count, 1)
    }
}
