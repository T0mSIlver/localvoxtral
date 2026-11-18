import ClaudeContextWire
import ClaudeHookPublisherCore
import Foundation
import localvoxtralTestSupport
import Synchronization
import XCTest
@testable import localvoxtralCore

/// The needs-you cue and the answer shortcut for Claude Desktop sessions
/// (#834). The records are the recorded ones (`Tests/ClaudeDesktopHookPayloads`,
/// Claude Code 2.1.281 run with Desktop's flags), published by the real
/// publisher into the real broker; the ssh path runs the real shim in
/// `ClaudeRemotePluginManifestTests`.
@MainActor
final class ClaudeDesktopAttentionTests: XCTestCase {
    private var directory: URL!
    private var registry: ClaudeSessionRegistry!
    private var broker: ClaudeContextBroker!
    private var socketPath: String { directory.appendingPathComponent("s").path }

    private let desktopID = "local_6d880b94-4414-4764-a024-c95df1af4456"
    private let otherDesktopID = "local_eeda27ee-43ae-4ab3-8e26-0fdc50fb1c7c"
    private let claudePID: Int32 = 71_203
    private let desktopPID: pid_t = 4_100
    private let epoch = Date(timeIntervalSince1970: 1_790_499_300)
    private var desktopTarget: TerminalScreenTarget {
        TerminalScreenTarget(pid: desktopPID, bundleID: ClaudeDesktopAllowlist.bundleID)
    }

    private final class Box<Value: Sendable>: Sendable {
        private let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
        func get() -> Value { value.withLock { $0 } }
        func set(_ newValue: Value) { value.withLock { $0 = newValue } }
        func mutate(_ body: (inout Value) -> Void) { value.withLock { body(&$0) } }
    }

    private typealias Delivered = (event: ClaudeHookEvent, session: ClaudeSessionSnapshot, sequence: UInt64)

    private func start() throws -> Box<[Delivered]> {
        // /tmp: `sun_path` is 104 bytes on Darwin (see ClaudeContextBrokerTests).
        directory = URL(fileURLWithPath: "/tmp/lvx-\(UUID().uuidString.prefix(8))")
        let now = epoch
        registry = ClaudeSessionRegistry(now: { now }, isProcessAlive: { _ in true })
        let delivered = Box<[Delivered]>([])
        registry.setTurnObserver { event, session, sequence in
            delivered.mutate { $0.append((event, session, sequence)) }
        }
        broker = ClaudeContextBroker(socketPath: socketPath, registry: registry)
        try broker.start()
        return delivered
    }

    private func stop() {
        broker?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func payload(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("ClaudeDesktopHookPayloads/\(name).json"))
    }

    /// A Code-tab session on this Mac: Desktop exports its view's id into
    /// the session's Claude Code, and the hook inherits it. No terminal.
    private func publish(_ names: [String], bridgeSessionID: String? = nil) throws {
        let claude = claudePID
        var variables = [
            ClaudeHookSocketPath.environmentKey: socketPath,
            "CLAUDE_CODE_HOST_SESSION_ID": desktopID,
            "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
        ]
        variables["CLAUDE_CODE_BRIDGE_SESSION_ID"] = bridgeSessionID
        let publisher = ClaudeHookPublisher(
            environment: .init(
                now: { 1_790_499_330 },
                pid: { 71_250 },
                ppid: { claude },
                ttyName: { _ in nil },
                variables: variables
            ),
            publisher: UnixSocketPublisher(timeout: 2.0)
        )
        // The broker replies after the registry took the record, so a
        // published run has been ingested.
        for name in names {
            XCTAssertEqual(publisher.run(stdin: try payload(name), fallbackEvent: nil), .published, name)
        }
    }

    /// The tracker as the app builds it: "were you looking at it" is the
    /// join's own Desktop read (`sessionShown`) of the frontmost Desktop.
    private func tracker(showing shownURL: Box<String?>) -> (AgentAttentionTracker, Box<[AgentAttentionEntry]>) {
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in nil },
            focusedDesktopSessionURL: { _ in ClaudeDesktopFocusRead(address: shownURL.get()) }
        )
        let target = desktopTarget
        let registry = registry!
        let tracker = AgentAttentionTracker(
            isEnabled: { true },
            isWatching: { session in await resolver.sessionShown(target: target) == session.sessionID },
            liveSessionIDs: { Set(registry.liveSessions().map(\.sessionID)) },
            now: { Date(timeIntervalSince1970: 1_790_499_340) }
        )
        let cues = Box<[AgentAttentionEntry]>([])
        tracker.onCue = { entry in cues.mutate { $0.append(entry) } }
        return (tracker, cues)
    }

    private func feed(_ tracker: AgentAttentionTracker, _ delivered: Box<[Delivered]>) async {
        for item in delivered.get() {
            await tracker.receive(item.event, session: item.session, sequence: item.sequence)?.value
        }
        delivered.set([])
    }

    // MARK: - The cue

    func testADesktopPermissionPromptOnThisMacCuesAndNamesTheSession() async throws {
        let delivered = try start()
        defer { stop() }
        let (tracker, cues) = tracker(showing: Box("https://claude.ai/epitaxy/\(desktopID)"))

        try publish(["Notification-permission_prompt"])
        await feed(tracker, delivered)

        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "fdad6dd0-fdd7-4118-ba62-ef71e8bf90e7"))
        XCTAssertEqual(snapshot.desktopSessionID, desktopID)
        XCTAssertEqual(cues.get().map { AgentAttentionText.sentence($0) }, ["payments needs you"])
        XCTAssertEqual(cues.get().map(\.agent), [.claude])
        XCTAssertEqual(tracker.next()?.sessionID, snapshot.sessionID)
    }

    func testAnAskUserQuestionInDesktopArrivesAsAWaitToo() async throws {
        let delivered = try start()
        defer { stop() }
        let (tracker, cues) = tracker(showing: Box(nil))

        try publish(["Notification-AskUserQuestion"])
        await feed(tracker, delivered)

        XCTAssertEqual(cues.get().map(\.kind), [.waiting])
    }

    func testATurnEndCuesOnlyWhenDesktopShowsAnotherSession() async throws {
        let delivered = try start()
        defer { stop() }
        let shown = Box<String?>("https://claude.ai/epitaxy/\(desktopID)")
        let (tracker, cues) = tracker(showing: shown)

        try publish(["Stop"])
        await feed(tracker, delivered)
        XCTAssertTrue(cues.get().isEmpty, "the owner was looking at that session")
        XCTAssertTrue(tracker.queue.isEmpty)

        shown.set("https://claude.ai/epitaxy/\(otherDesktopID)")
        try publish(["Stop"])
        await feed(tracker, delivered)
        XCTAssertEqual(cues.get().map { AgentAttentionText.sentence($0) }, ["payments finished"])
    }

    /// A Remote Control session in Desktop (#1065, #1191). MEASURED on Claude
    /// Desktop 2.19675.0 (2026-10-05): Desktop shows it at its `local_` view
    /// like any Code-tab session, with `?artifact=<uuid>` while an artifact
    /// is open beside it; no `/code/session_` address appeared. The bridge id
    /// plays no part in "is it shown".
    func testARemoteControlSessionShownInDesktopCountsAsShown() async throws {
        let delivered = try start()
        defer { stop() }
        let bridgeID = "session_01AbCdEfGhIjKlMnOpQrStUv"
        let shown = Box<String?>(
            "https://claude.ai/epitaxy/\(desktopID)?artifact=6c278aef-0cd7-4797-a0a8-5b2ee8254765"
        )
        let (tracker, cues) = tracker(showing: shown)

        try publish(["Stop"], bridgeSessionID: bridgeID)
        await feed(tracker, delivered)
        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "fdad6dd0-fdd7-4118-ba62-ef71e8bf90e7"))
        XCTAssertEqual(snapshot.bridgeSessionID, bridgeID)
        XCTAssertTrue(cues.get().isEmpty, "the owner was looking at that session")

        // The bridge id's browser address in Desktop's web view is not a
        // Desktop session view.
        shown.set("https://claude.ai/code/\(bridgeID)")
        try publish(["Stop"], bridgeSessionID: bridgeID)
        await feed(tracker, delivered)
        XCTAssertEqual(cues.get().map { AgentAttentionText.sentence($0) }, ["payments finished"])
    }

    func testTheWaitStaysUntilTheSessionMovesOnAndItsStopReplacesIt() async throws {
        let delivered = try start()
        defer { stop() }
        let (tracker, cues) = tracker(showing: Box(nil))

        try publish(["Notification-permission_prompt", "Stop"])
        await feed(tracker, delivered)

        XCTAssertEqual(cues.get().map(\.kind), [.waiting, .finished])
        XCTAssertEqual(tracker.queue.entries.map(\.kind), [.finished])
    }

    // MARK: - Reading the pane back

    private struct ReadBackHarness {
        let focuser: ClaudeDesktopSessionPaneFocuser
        let shown: Box<String?>
        let frontmost: Box<pid_t?>
    }

    /// Desktop shows `shown`, and `frontmost` is the app in front.
    private func readBackHarness(
        running: Bool = true,
        shown shownURL: String?,
        frontmostIsDesktop: Bool = true,
        switchAppsDuringRead: Bool = false
    ) -> ReadBackHarness {
        let shown = Box<String?>(shownURL)
        let pid = desktopPID
        let frontmost = Box<pid_t?>(frontmostIsDesktop ? pid : 999)
        let registry = registry!
        let focuser = ClaudeDesktopSessionPaneFocuser(
            desktopPID: { running ? pid : nil },
            frontmostPID: { frontmost.get() },
            shownSessionID: { _ in
                // The join's rule: the focused view's id, resolved to one
                // live session.
                guard let address = shown.get(),
                      let id = ClaudeDesktopSessionURL.sessionID(inWebAreaURL: address),
                      case .resolved(let snapshot) = registry.resolve(desktopSessionID: id)
                else { return nil }
                // The user switches apps while the read is suspended.
                if switchAppsDuringRead { frontmost.set(999) }
                return snapshot.sessionID
            }
        )
        return ReadBackHarness(focuser: focuser, shown: shown, frontmost: frontmost)
    }

    private func waitingSession() throws -> ClaudeSessionSnapshot {
        try publish(["Notification-permission_prompt"])
        return try XCTUnwrap(registry.snapshot(sessionID: "fdad6dd0-fdd7-4118-ba62-ef71e8bf90e7"))
    }

    func testDesktopShowsTheSessionOnlyWhenItIsFrontmostAndShowsIt() async throws {
        _ = try start()
        defer { stop() }
        let session = try waitingSession()
        let shown = "https://claude.ai/epitaxy/\(desktopID)"
        let other = "https://claude.ai/epitaxy/\(otherDesktopID)"
        let cases: [(name: String, harness: ReadBackHarness, expected: Bool)] = [
            ("shown and frontmost", readBackHarness(shown: shown), true),
            ("another session shown", readBackHarness(shown: other), false),
            ("an unreadable view", readBackHarness(shown: nil), false),
            ("Desktop is not frontmost", readBackHarness(shown: shown, frontmostIsDesktop: false), false),
            ("a switch to another app during the read", readBackHarness(shown: shown, switchAppsDuringRead: true), false),
            ("Desktop is closed", readBackHarness(running: false, shown: shown), false),
        ]
        for c in cases {
            let shows = await c.harness.focuser.focusedPaneShows(session, bundleID: ClaudeDesktopAllowlist.bundleID)
            XCTAssertEqual(shows, c.expected, c.name)
        }
    }

    /// Two live sessions reporting one view (a `claude -p` inside it on a
    /// host whose plugin predates 1.14.0) make the view ambiguous: the join
    /// abstains, and so does the read-back.
    func testAViewTwoSessionsReportIsNotShown() async throws {
        _ = try start()
        defer { stop() }
        try publish(["Notification-permission_prompt", "Notification-AskUserQuestion"])
        let session = try XCTUnwrap(registry.snapshot(sessionID: "fdad6dd0-fdd7-4118-ba62-ef71e8bf90e7"))
        let h = readBackHarness(shown: "https://claude.ai/epitaxy/\(desktopID)")
        let shows = await h.focuser.focusedPaneShows(session, bundleID: ClaudeDesktopAllowlist.bundleID)
        XCTAssertFalse(shows)
    }

    func testTheRouterReadsDesktopSessionsFromDesktopHerdrPanesFromHerdrAndTabsFromTheTerminal() async {
        let terminal = FakeSessionPaneFocuser()
        let desktop = FakeSessionPaneFocuser()
        let herdr = FakeSessionPaneFocuser()
        let router = SessionPaneFocuserRouter(terminal: terminal, claudeDesktop: desktop, herdr: herdr)
        let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
        var tab = ClaudeSessionSnapshot(sessionID: "tab", origin: local, firstSeen: epoch)
        tab.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: "/dev/ttys004")
        var remote = ClaudeSessionSnapshot(sessionID: "ssh", origin: .remote(channel: "h"), firstSeen: epoch)
        remote.remoteEnvironment = ClaudeRemoteSessionEnvironment(desktopSessionID: desktopID)

        var pane = ClaudeSessionSnapshot(sessionID: "pane", origin: local, firstSeen: epoch)
        pane.process = ClaudeHookProcessInfo(
            hookPID: 3, claudePID: 4, tty: "/dev/ttys005", herdrPaneID: "w1:p2", herdrSocketPath: "/tmp/h.sock"
        )

        _ = await router.focusedPaneShows(tab, bundleID: "x")
        _ = await router.focusedPaneShows(remote, bundleID: "x")
        _ = await router.focusedPaneShows(pane, bundleID: "x")

        XCTAssertEqual(terminal.readBackSessionIDs, ["tab"])
        XCTAssertEqual(desktop.readBackSessionIDs, ["ssh"])
        XCTAssertEqual(herdr.readBackSessionIDs, ["pane"])
    }
}
