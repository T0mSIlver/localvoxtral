import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import ClaudeHookPublisherCore
@testable import localvoxtralCore

/// A Codex CLI session, from its recorded hook payloads
/// (`Tests/CodexHookPayloads`, Codex 0.156.0) through the real publisher and
/// broker into the registry, and from there to each local join arm.
///
/// The process shape is the measured one: Codex runs a hook as
/// `$SHELL -lc <command>` in a new session without a terminal, the login
/// shell execs the shim, so the shim's `$PPID` is Codex itself, which holds
/// the pane's tty.
@MainActor
final class CodexSessionJoinTests: XCTestCase {
    private var directory: URL!
    private var registry: ClaudeSessionRegistry!
    private var broker: ClaudeContextBroker!
    private var socketPath: String { directory.appendingPathComponent("s").path }

    private let codexPID: Int32 = 490_821
    private let codexStart: Int64 = 1_790_443_600_000_000
    private let tty = "/dev/ttys006"
    private let rawSessionID = "01a0dec1-c2ba-71b3-b640-a2568cef221b"
    private var scopedSessionID: String { "codex:" + rawSessionID }
    private let cwd = "/home/dev/work/localvoxtral/.claude/worktrees/interesting-mirzakhani-907bab/.scratch/codex-probe/proj"
    private let ghostty = TerminalScreenTarget(pid: 4242, bundleID: TerminalScreenAllowlist.ghosttyBundleID)

    /// Called first by every test, with `defer { stop() }`: an async
    /// `setUp` override on a main-actor case does not compile under strict
    /// concurrency.
    private func start() throws {
        // /tmp: `sun_path` is 104 bytes on Darwin (see ClaudeContextBrokerTests).
        directory = URL(fileURLWithPath: "/tmp/lvx-\(UUID().uuidString.prefix(8))")
        let pid = codexPID
        let start = codexStart
        registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 1_790_443_700) },
            isProcessAlive: { $0 == pid },
            processStartMicros: { $0 == pid ? start : nil }
        )
        broker = ClaudeContextBroker(socketPath: socketPath, registry: registry)
        try broker.start()
    }

    private func stop() {
        broker?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func payload(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("CodexHookPayloads/\(name).json"))
    }

    /// The pane's environment as the recorded hook saw it, plus the handles a
    /// herdr pane or cmux surface would add. The probe ran inside a Claude
    /// Desktop session, so the hook inherited `CLAUDE_CODE_HOST_SESSION_ID`:
    /// a Codex record must never carry it.
    private func publish(_ names: [String], extra: [String: String] = [:]) throws {
        var variables = [
            ClaudeHookSocketPath.environmentKey: socketPath,
            "TERM_PROGRAM": "ghostty",
            "CLAUDE_CODE_HOST_SESSION_ID": "local_6452d5fc-1a7f-4721-8178-9c5a324a2218",
        ]
        variables.merge(extra) { $1 }
        let codex = codexPID
        let start = codexStart
        let paneTTY = tty
        let publisher = ClaudeHookPublisher(
            environment: .init(
                now: { 1_790_443_650 },
                pid: { 491_401 },
                ppid: { codex },
                ttyName: { $0 == codex ? paneTTY : nil },
                variables: variables
            ),
            publisher: UnixSocketPublisher(timeout: 2.0)
        )
        let processTable = ClaudeHookPublisher.VibeEnvironment(
            ownSession: { 491_401 },
            processFacts: { pid in
                pid == codex ? .init(parent: 490_818, session: 490_821, hasTTY: true, startMicros: start) : nil
            }
        )
        let done = expectation(description: "ingested")
        done.expectedFulfillmentCount = names.count
        broker.debugConfigureIngestHook { _ in done.fulfill() }
        for name in names {
            XCTAssertEqual(publisher.runCodex(stdin: try payload(name), vibe: processTable), .published, name)
        }
        wait(for: [done], timeout: 5)
    }

    private let turn = ["SessionStart", "UserPromptSubmit", "PostToolUse-apply_patch", "Stop"]

    // MARK: - Registry

    func testARecordedTurnIsOneCodexSessionOnTheCodexProcesssTTY() throws {
        try start()
        defer { stop() }
        XCTAssertFalse(registry.hasHeard(localAgent: .codex))
        try publish(turn)

        guard case .resolved(let snapshot) = registry.resolve(tty: tty) else {
            return XCTFail("the pane Codex runs in has no session")
        }
        XCTAssertEqual(snapshot.agent, .codex)
        XCTAssertEqual(snapshot.sessionID, scopedSessionID)
        XCTAssertEqual(snapshot.process?.claudePID, codexPID)
        XCTAssertEqual(snapshot.process?.agentStartMicros, codexStart)
        XCTAssertNil(snapshot.desktopSessionID, "a Codex session must not claim the Claude view it was started from")
        XCTAssertEqual(snapshot.latestPriorUserPrompt?.hasPrefix("Read notes.txt with a shell command"), true)
        XCTAssertEqual(snapshot.recentFiles.map(\.path), ["\(cwd)/notes.txt"])
        XCTAssertEqual(snapshot.activity, .idle, "Stop ended the turn")
        XCTAssertTrue(registry.hasHeard(localAgent: .codex))
        XCTAssertFalse(registry.hasHeard(localAgent: .claude))

        registry.forgetHeard(localAgent: .codex)
        XCTAssertFalse(registry.hasHeard(localAgent: .codex))
    }

    func testSessionEndRemovesTheSession() throws {
        try start()
        defer { stop() }
        try publish(turn + ["SessionEnd"])
        guard case .unknown = registry.resolve(tty: tty) else {
            return XCTFail("an ended session must not stay joinable")
        }
    }

    // MARK: - Join arms

    func testGhosttyJoinsTheCodexSessionOnItsTTY() async throws {
        try start()
        defer { stop() }
        try publish(turn)
        let paneTTY = tty
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in paneTTY },
            focusedWindowID: { _ in 101 }
        )
        let join = await resolver.resolve(target: ghostty)
        XCTAssertEqual(join?.mechanism, .ttyDevice)
        XCTAssertEqual(join?.snapshot.sessionID, scopedSessionID)
    }

    /// herdr's own Codex integration reports the raw Codex session id as the
    /// pane's `agent_session`; the arm scopes it by the snapshot's agent.
    func testAHerdrPaneJoinsWhenHerdrsCodexClaimAgrees() async throws {
        try start()
        defer { stop() }
        try publish(turn, extra: ["HERDR_PANE_ID": "pane-a", "HERDR_SOCKET_PATH": "/tmp/herdr-a.sock"])
        let join = await herdrResolver(claim: rawSessionID).resolve(target: ghostty)
        XCTAssertEqual(join?.mechanism, .herdrPane)
        XCTAssertEqual(join?.snapshot.sessionID, scopedSessionID)
    }

    func testAHerdrPaneAbstainsWhenHerdrClaimsAnotherSession() async throws {
        try start()
        defer { stop() }
        try publish(turn, extra: ["HERDR_PANE_ID": "pane-a", "HERDR_SOCKET_PATH": "/tmp/herdr-a.sock"])
        let join = await herdrResolver(claim: "01a0dec4-3d09-7f70-a49b-97c282cc58f0").resolve(target: ghostty)
        XCTAssertNil(join)
    }

    func testACmuxSurfaceJoinsTheCodexSession() async throws {
        try start()
        defer { stop() }
        try publish(turn, extra: ["CMUX_SURFACE_ID": "surface-a", "CMUX_SOCKET_PATH": "/tmp/cmux.sock"])
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            focusedWindowID: { _ in 101 },
            cmuxSurfaces: CodexJoinCmuxSurface(surfaceID: "surface-a", tty: tty),
            cmuxJoinEnabled: { true }
        )
        let join = await resolver.resolve(
            target: TerminalScreenTarget(pid: 4243, bundleID: TerminalScreenAllowlist.cmuxBundleID)
        )
        XCTAssertEqual(join?.mechanism, .cmuxSurface)
        XCTAssertEqual(join?.snapshot.sessionID, scopedSessionID)
    }

    private func herdrResolver(claim: String) -> ClaudeSessionJoinResolver {
        let codex = codexPID
        return ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in "/dev/ttys001" },
            focusedWindowID: { _ in 101 },
            herdrClientProbe: { _ in true },
            herdrPanes: CodexJoinHerdrPanes(
                focused: HerdrFocusedPane(paneID: "pane-a", claimedClaudeSessionID: claim),
                foreground: HerdrPaneForegroundInfo(shellPID: 8000, foregroundPIDs: [codex])
            )
        )
    }
}

private struct CodexJoinHerdrPanes: HerdrPaneQuerying {
    var focused: HerdrFocusedPane?
    var foreground: HerdrPaneForegroundInfo?

    func focusedPane(socketPath _: String) async -> HerdrFocusedPane? { focused }
    func paneForegroundInfo(socketPath _: String, paneID _: String) async -> HerdrPaneForegroundInfo? { foreground }
    func paneVisibleText(socketPath _: String, paneID _: String) async -> String? { nil }
}

private struct CodexJoinCmuxSurface: CmuxSurfaceQuerying {
    var surfaceID: String
    var tty: String

    func focusedSurface(expectedPeerPID _: pid_t) async -> CmuxQueryResult<CmuxFocusedSurface> {
        .value(CmuxFocusedSurface(surfaceID: surfaceID, tty: tty, workspaceIsRemote: false))
    }

    func surfaceText(surfaceID _: String, expectedPeerPID _: pid_t) async -> CmuxQueryResult<String> {
        .unavailable
    }
}
