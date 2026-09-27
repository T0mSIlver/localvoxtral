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
    private func publish(_ names: [String]) throws {
        let claude = claudePID
        let publisher = ClaudeHookPublisher(
            environment: .init(
                now: { 1_790_499_330 },
                pid: { 71_250 },
                ppid: { claude },
                ttyName: { _ in nil },
                variables: [
                    ClaudeHookSocketPath.environmentKey: socketPath,
                    "CLAUDE_CODE_HOST_SESSION_ID": desktopID,
                    "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
                ]
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
            focusedDesktopSessionURL: { _ in shownURL.get() }
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

    func testTheWaitStaysUntilTheSessionMovesOnAndItsStopReplacesIt() async throws {
        let delivered = try start()
        defer { stop() }
        let (tracker, cues) = tracker(showing: Box(nil))

        try publish(["Notification-permission_prompt", "Stop"])
        await feed(tracker, delivered)

        XCTAssertEqual(cues.get().map(\.kind), [.waiting, .finished])
        XCTAssertEqual(tracker.queue.entries.map(\.kind), [.finished])
    }

    // MARK: - Bringing it forward

    private struct FocusHarness {
        let focuser: ClaudeDesktopSessionPaneFocuser
        let opened: Box<[URL]>
        let shown: Box<String?>
        let frontmost: Box<pid_t?>
        let sleeps: Box<Int>
    }

    /// `shownAfterOpen` is what Desktop's focused view names once the link
    /// has been open for `afterSleeps` read-backs.
    private func focusHarness(
        running: Bool = true,
        shownAfterOpen: String?,
        afterSleeps: Int = 2
    ) -> FocusHarness {
        let shown = Box<String?>("https://claude.ai/epitaxy/\(otherDesktopID)")
        let frontmost = Box<pid_t?>(999)
        let opened = Box<[URL]>([])
        let sleeps = Box(0)
        let pid = desktopPID
        let registry = registry!
        let focuser = ClaudeDesktopSessionPaneFocuser(
            desktopPID: { running ? pid : nil },
            frontmostPID: { frontmost.get() },
            open: { url in
                opened.mutate { $0.append(url) }
                return true
            },
            shownSessionID: { _ in
                // The join's rule: the focused view's id, resolved to one
                // live session.
                guard let address = shown.get(),
                      let id = ClaudeDesktopSessionURL.sessionID(inWebAreaURL: address),
                      case .resolved(let snapshot) = registry.resolve(desktopSessionID: id)
                else { return nil }
                return snapshot.sessionID
            },
            sleep: { _ in
                sleeps.mutate { $0 += 1 }
                if sleeps.get() == afterSleeps {
                    frontmost.set(pid)
                    shown.set(shownAfterOpen)
                }
            }
        )
        return FocusHarness(focuser: focuser, opened: opened, shown: shown, frontmost: frontmost, sleeps: sleeps)
    }

    func testTheLinkBringsTheSessionForwardAndItIsReadBack() async throws {
        _ = try start()
        defer { stop() }
        try publish(["Notification-permission_prompt"])
        let session = try XCTUnwrap(registry.snapshot(sessionID: "fdad6dd0-fdd7-4118-ba62-ef71e8bf90e7"))
        let h = focusHarness(shownAfterOpen: "https://claude.ai/epitaxy/\(desktopID)")

        let outcome = await h.focuser.focusPane(of: session)

        XCTAssertEqual(outcome, .focused(bundleID: ClaudeDesktopAllowlist.bundleID))
        XCTAssertEqual(h.opened.get().map(\.absoluteString), ["claude://code/continue?session=\(desktopID)"])
        XCTAssertEqual(h.sleeps.get(), 2, "read back until it shows, no longer")
        let still = await h.focuser.focusedPaneShows(session, bundleID: ClaudeDesktopAllowlist.bundleID)
        XCTAssertTrue(still)
    }

    func testAViewThatNeverShowsTheSessionIsUnverified() async throws {
        _ = try start()
        defer { stop() }
        try publish(["Notification-permission_prompt"])
        let session = try XCTUnwrap(registry.snapshot(sessionID: "fdad6dd0-fdd7-4118-ba62-ef71e8bf90e7"))
        let h = focusHarness(shownAfterOpen: "https://claude.ai/epitaxy/\(otherDesktopID)")

        let outcome = await h.focuser.focusPane(of: session)

        XCTAssertEqual(outcome, .unverified(bundleID: ClaudeDesktopAllowlist.bundleID))
        XCTAssertEqual(h.sleeps.get(), ClaudeDesktopSessionPaneFocuser.readBackAttempts)
    }

    /// Focus left in the sidebar, or a view the join cannot read, is no
    /// answer: the dictation would not go to the session.
    func testAnUnreadableViewIsUnverified() async throws {
        _ = try start()
        defer { stop() }
        try publish(["Notification-permission_prompt"])
        let session = try XCTUnwrap(registry.snapshot(sessionID: "fdad6dd0-fdd7-4118-ba62-ef71e8bf90e7"))
        let h = focusHarness(shownAfterOpen: nil)

        let outcome = await h.focuser.focusPane(of: session)
        XCTAssertEqual(outcome, .unverified(bundleID: ClaudeDesktopAllowlist.bundleID))
    }

    func testTheSessionShownWhileDesktopIsNotFrontmostIsUnverified() async throws {
        _ = try start()
        defer { stop() }
        try publish(["Notification-permission_prompt"])
        let session = try XCTUnwrap(registry.snapshot(sessionID: "fdad6dd0-fdd7-4118-ba62-ef71e8bf90e7"))
        let h = focusHarness(shownAfterOpen: "https://claude.ai/epitaxy/\(desktopID)", afterSleeps: 0)
        h.shown.set("https://claude.ai/epitaxy/\(desktopID)")

        let outcome = await h.focuser.focusPane(of: session)
        XCTAssertEqual(outcome, .unverified(bundleID: ClaudeDesktopAllowlist.bundleID))
    }

    /// Two live sessions reporting one view (a `claude -p` inside it on a
    /// host whose plugin predates 1.14.0) make the view ambiguous: the join
    /// abstains, and so does the read-back.
    func testAViewTwoSessionsReportIsUnverified() async throws {
        _ = try start()
        defer { stop() }
        try publish(["Notification-permission_prompt", "Notification-AskUserQuestion"])
        let session = try XCTUnwrap(registry.snapshot(sessionID: "fdad6dd0-fdd7-4118-ba62-ef71e8bf90e7"))
        let h = focusHarness(shownAfterOpen: "https://claude.ai/epitaxy/\(desktopID)")

        let outcome = await h.focuser.focusPane(of: session)
        XCTAssertEqual(outcome, .unverified(bundleID: ClaudeDesktopAllowlist.bundleID))
    }

    func testWithDesktopClosedTheLinkIsNotOpened() async throws {
        _ = try start()
        defer { stop() }
        try publish(["Notification-permission_prompt"])
        let session = try XCTUnwrap(registry.snapshot(sessionID: "fdad6dd0-fdd7-4118-ba62-ef71e8bf90e7"))
        let h = focusHarness(running: false, shownAfterOpen: nil)

        let outcome = await h.focuser.focusPane(of: session)
        XCTAssertEqual(outcome, .paneNotFound)
        XCTAssertEqual(h.opened.get(), [], "opening the link would launch Desktop")
    }

    func testTheRouterSendsDesktopSessionsToDesktopAndTabsToTheTerminal() async {
        let terminal = FakeSessionPaneFocuser(outcome: .focused(bundleID: TerminalScreenAllowlist.ghosttyBundleID))
        let desktop = FakeSessionPaneFocuser(outcome: .focused(bundleID: ClaudeDesktopAllowlist.bundleID))
        let router = SessionPaneFocuserRouter(terminal: terminal, claudeDesktop: desktop)
        let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
        var tab = ClaudeSessionSnapshot(sessionID: "tab", origin: local, firstSeen: epoch)
        tab.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: "/dev/ttys004")
        var remote = ClaudeSessionSnapshot(sessionID: "ssh", origin: .remote(channel: "h"), firstSeen: epoch)
        remote.remoteEnvironment = ClaudeRemoteSessionEnvironment(desktopSessionID: desktopID)

        _ = await router.focusPane(of: tab)
        _ = await router.focusPane(of: remote)

        XCTAssertEqual(terminal.focusedSessionIDs, ["tab"])
        XCTAssertEqual(desktop.focusedSessionIDs, ["ssh"])
    }
}
