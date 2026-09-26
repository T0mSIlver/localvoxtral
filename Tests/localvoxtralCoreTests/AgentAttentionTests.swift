import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import Synchronization
import XCTest
@testable import localvoxtralCore

/// The needs-you queue (#717): which sessions wait on the user or finished
/// while they looked elsewhere, fed by the registry from each harness's hook
/// records, and which one the answer hotkey goes to.
private final class Box<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
    func get() -> Value { value.withLock { $0 } }
    func set(_ newValue: Value) { value.withLock { $0 = newValue } }
}

final class AgentAttentionTests: XCTestCase {
    nonisolated private static let epoch = Date(timeIntervalSince1970: 3_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    // MARK: - Queue

    @MainActor
    func testTheAnswerGoesToTheOldestWaitBeforeAnyFinishedTurn() async {
        var queue = AgentAttentionQueue()
        queue.endTurn(sessionID: "a", name: "a", agent: .claude, at: Self.epoch, watched: false)
        queue.wait(sessionID: "b", name: "b", agent: .codex, at: Self.epoch.addingTimeInterval(20))
        queue.wait(sessionID: "c", name: "c", agent: .opencode, at: Self.epoch.addingTimeInterval(10))
        XCTAssertEqual(queue.next?.sessionID, "c")
        queue.remove(sessionID: "c")
        XCTAssertEqual(queue.next?.sessionID, "b")
        queue.remove(sessionID: "b")
        XCTAssertEqual(queue.next?.sessionID, "a")
        queue.remove(sessionID: "a")
        XCTAssertNil(queue.next)
    }

    @MainActor
    func testAWaitKeepsItsPlaceAndATurnEndReplacesIt() async {
        var queue = AgentAttentionQueue()
        queue.wait(sessionID: "a", name: "a", agent: .claude, at: Self.epoch)
        queue.wait(sessionID: "a", name: "a", agent: .claude, at: Self.epoch.addingTimeInterval(30))
        XCTAssertEqual(queue.entries.map(\.since), [Self.epoch], "one entry per session, first wait's time")

        XCTAssertNil(
            queue.endTurn(sessionID: "a", name: "a", agent: .claude, at: Self.epoch, watched: true),
            "a turn that ended in front of the user leaves nothing"
        )
        XCTAssertTrue(queue.isEmpty)

        queue.endTurn(sessionID: "a", name: "a", agent: .claude, at: Self.epoch, watched: false)
        queue.wait(sessionID: "a", name: "a", agent: .claude, at: Self.epoch.addingTimeInterval(5))
        XCTAssertEqual(queue.entries.map(\.kind), [.waiting])
        XCTAssertEqual(queue.entries.first?.since, Self.epoch.addingTimeInterval(5))
    }

    @MainActor
    func testSessionsTheRegistryDroppedLeaveTheQueue() async {
        var queue = AgentAttentionQueue()
        queue.wait(sessionID: "a", name: "a", agent: .claude, at: Self.epoch)
        queue.wait(sessionID: "b", name: "b", agent: .claude, at: Self.epoch)
        queue.retain(liveSessionIDs: ["b"])
        XCTAssertEqual(queue.entries.map(\.sessionID), ["b"])
    }

    // MARK: - From each harness's records, through the registry

    private struct Harness {
        let registry: ClaudeSessionRegistry
        let tracker: AgentAttentionTracker
        let watching: Box<Set<String>>
        let enabled: Box<Bool>
        let cues: Box<[AgentAttentionEntry]>
        let checks: Box<[Task<Void, Never>]>
    }

    @MainActor
    private func harness() -> Harness {
        let registry = ClaudeSessionRegistry(now: { Self.epoch }, isProcessAlive: { _ in true })
        let watching = Box<Set<String>>([])
        let enabled = Box(true)
        let cues = Box<[AgentAttentionEntry]>([])
        let checks = Box<[Task<Void, Never>]>([])
        let tracker = AgentAttentionTracker(
            isEnabled: { enabled.get() },
            isWatching: { watching.get().contains($0.sessionID) },
            liveSessionIDs: { Set(registry.liveSessions().map(\.sessionID)) },
            now: { Self.epoch }
        )
        tracker.onCue = { entry in cues.set(cues.get() + [entry]) }
        // The app hops to the main queue; the test ingests on it already.
        registry.setTurnObserver { event, session in
            MainActor.assumeIsolated {
                if let check = tracker.receive(event, session: session) {
                    checks.set(checks.get() + [check])
                }
            }
        }
        return Harness(
            registry: registry, tracker: tracker, watching: watching,
            enabled: enabled, cues: cues, checks: checks
        )
    }

    @MainActor
    private func settle(_ harness: Harness) async {
        for check in harness.checks.get() { await check.value }
        harness.checks.set([])
    }

    private func claude(_ json: String) throws -> ClaudeHookRecord {
        var record = try XCTUnwrap(ClaudeHookInputParser.parse(data: Data(json.utf8), fallbackEvent: nil, timestamp: 0))
        record.process = ClaudeHookProcessInfo(hookPID: 10, claudePID: 11, tty: "/dev/ttys004")
        return record
    }

    @MainActor
    func testAClaudeCodePermissionPromptQueuesAWaitThatANewPromptClears() async throws {
        let h = harness()
        h.registry.ingest(try claude(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/work/payments","prompt":"deploy"}"#), origin: local)
        h.registry.ingest(try claude(#"{"hook_event_name":"Notification","session_id":"s1","cwd":"/work/payments","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#), origin: local)
        XCTAssertEqual(h.tracker.queue.entries.map(\.kind), [.waiting])
        XCTAssertEqual(h.cues.get().map { AgentAttentionText.sentence($0) }, ["payments needs you"])

        h.registry.ingest(try claude(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/work/payments","prompt":"go on"}"#), origin: local)
        XCTAssertTrue(h.tracker.queue.isEmpty)
    }

    @MainActor
    func testAFinishedTurnCuesOnlyWhenTheUserWasNotLookingAtThePane() async throws {
        let h = harness()
        let stop = #"{"hook_event_name":"Stop","session_id":"s1","cwd":"/work/payments","last_assistant_message":"done"}"#
        h.watching.set(["s1"])
        h.registry.ingest(try claude(stop), origin: local)
        await settle(h)
        XCTAssertTrue(h.tracker.queue.isEmpty)
        XCTAssertTrue(h.cues.get().isEmpty)

        h.watching.set([])
        h.registry.ingest(try claude(stop), origin: local)
        await settle(h)
        XCTAssertEqual(h.tracker.queue.entries.map(\.kind), [.finished])
        XCTAssertEqual(h.cues.get().map { AgentAttentionText.sentence($0) }, ["payments finished"])
    }

    @MainActor
    func testAWaitCuesEvenWhileTheUserLooksAtThePane() async throws {
        let h = harness()
        h.watching.set(["s1"])
        h.registry.ingest(try claude(#"{"hook_event_name":"Notification","session_id":"s1","cwd":"/w/p","notification_type":"elicitation_dialog"}"#), origin: local)
        XCTAssertEqual(h.cues.get().count, 1)
    }

    @MainActor
    func testAToolRunningAgainEndsTheWait() async throws {
        let h = harness()
        h.registry.ingest(try claude(#"{"hook_event_name":"Notification","session_id":"s1","cwd":"/w/p","notification_type":"permission_prompt"}"#), origin: local)
        h.registry.ingest(try claude(#"{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"/w/p","tool_name":"Edit","tool_input":{"file_path":"/w/p/a.swift"}}"#), origin: local)
        XCTAssertTrue(h.tracker.queue.isEmpty)
    }

    @MainActor
    func testTheNextEventWinsOverATurnEndStillCheckingThePane() async throws {
        let h = harness()
        let gate = AsyncGate()
        let tracker = AgentAttentionTracker(
            isEnabled: { true },
            isWatching: { _ in await gate.wait(); return false },
            liveSessionIDs: { ["s1"] },
            now: { Self.epoch }
        )
        let session = try XCTUnwrap(h.registry.ingest(try claude(#"{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/w/p"}"#), origin: local))
        let check = try XCTUnwrap(tracker.receive(.stop, session: session))
        tracker.receive(.userPromptSubmit, session: session)
        gate.open()
        await check.value
        XCTAssertTrue(tracker.queue.isEmpty, "the prompt came after the stop, so nothing is finished")
    }

    @MainActor
    func testEveryHarnessesWaitAndTurnEndReachTheQueue() async throws {
        let h = harness()
        // Codex: PermissionRequest and Stop, as its parser maps them.
        let codexWait = try XCTUnwrap(CodexHookInputParser.parse(
            data: Data(#"{"session_id":"c1","hook_event_name":"PermissionRequest","cwd":"/w/codexrepo","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#.utf8),
            timestamp: 0
        ))
        h.registry.ingest(codexWait, origin: local)
        // opencode: the plugin's Notification line, decoded as the broker does.
        let opencodeLine = #"{"v":2,"event":"Notification","agent":"opencode","session_id":"ses_o","ts":0,"cwd":"/w/ocrepo","files":[],"notification_type":"permission_prompt","process":{"hook_pid":20,"claude_pid":20}}"#
        h.registry.ingest(try ClaudeHookWireCodec.decodeLine(Data(opencodeLine.utf8)), origin: local)
        // Vibe: post_agent is a Stop; it has no wait.
        let vibeStop = ClaudeHookRecord(
            event: .stop, agent: .vibe, sessionID: "v1", timestamp: 0, rawCwd: "/w/viberepo",
            process: ClaudeHookProcessInfo(hookPID: 30, claudePID: 30)
        )
        h.registry.ingest(vibeStop, origin: local)
        await settle(h)

        XCTAssertEqual(
            Set(h.tracker.queue.entries.map { "\($0.name) \($0.kind.rawValue) \(AgentAttentionText.agentName($0.agent))" }),
            ["codexrepo waiting Codex", "ocrepo waiting opencode", "viberepo finished Mistral Vibe"]
        )
        XCTAssertEqual(h.tracker.next()?.kind, .waiting)
    }

    @MainActor
    func testARemoteSessionQueuesUnderItsLabel() async throws {
        let h = harness()
        let remote = ClaudeTransportOrigin.remote(channel: "host-1")
        var record = try claude(#"{"hook_event_name":"Notification","session_id":"s9","cwd":"/srv/api","notification_type":"permission_prompt"}"#)
        record.sessionID = ClaudeRemoteSessionScope.scopedSessionID(hostID: "host-1", sessionID: "s9")
        record.process = nil
        h.registry.ingest(record, origin: remote)
        XCTAssertEqual(h.tracker.queue.entries.map(\.name), ["api"])
    }

    @MainActor
    func testNothingQueuesWhileTheFeatureIsOffAndTurningItOffEmptiesTheQueue() async throws {
        let h = harness()
        let wait = try claude(#"{"hook_event_name":"Notification","session_id":"s1","cwd":"/w/p","notification_type":"permission_prompt"}"#)
        h.registry.ingest(wait, origin: local)
        XCTAssertFalse(h.tracker.queue.isEmpty)
        h.enabled.set(false)
        h.registry.ingest(wait, origin: local)
        XCTAssertTrue(h.tracker.queue.isEmpty)
        XCTAssertEqual(h.cues.get().count, 1)
    }

    @MainActor
    func testAnsweringOrEndingASessionTakesItOut() async throws {
        let h = harness()
        h.registry.ingest(try claude(#"{"hook_event_name":"Notification","session_id":"s1","cwd":"/w/p","notification_type":"permission_prompt"}"#), origin: local)
        h.tracker.answered(sessionID: "s1")
        XCTAssertTrue(h.tracker.queue.isEmpty)

        h.registry.ingest(try claude(#"{"hook_event_name":"Notification","session_id":"s1","cwd":"/w/p","notification_type":"permission_prompt"}"#), origin: local)
        h.registry.ingest(try claude(#"{"hook_event_name":"SessionEnd","session_id":"s1","cwd":"/w/p"}"#), origin: local)
        XCTAssertTrue(h.tracker.queue.isEmpty)
        XCTAssertNil(h.tracker.next())
    }

    // MARK: - Words

    @MainActor
    func testThePopoverLineFitsTheMenuAndCountsTheOthers() async {
        var queue = AgentAttentionQueue()
        let long = AgentAttentionText.shortened("a-very-long-worktree-name-for-payments")
        queue.wait(sessionID: "a", name: long, agent: .claude, at: Self.epoch)
        queue.endTurn(sessionID: "b", name: "api", agent: .codex, at: Self.epoch, watched: false)
        queue.endTurn(sessionID: "c", name: "web", agent: .vibe, at: Self.epoch, watched: false)
        let line = try? XCTUnwrap(AgentAttentionText.popoverLine(queue))
        XCTAssertEqual(line, "a-very-long-worktree-na… needs you (+2)")
        XCTAssertLessThanOrEqual(line?.count ?? 99, 44)
        XCTAssertNil(AgentAttentionText.popoverLine(AgentAttentionQueue()))
    }

    @MainActor
    func testANameCannotCarryControlCharacters() async {
        XCTAssertEqual(AgentAttentionText.shortened("pay\nments\u{1B}"), "pay ments ")
    }

    // MARK: - Is the user looking at the pane

    @MainActor
    func testThePaneShownIsReadFromLocalEvidenceOnly() async throws {
        let registry = ClaudeSessionRegistry(now: { Self.epoch }, isProcessAlive: { _ in true })
        registry.ingest(try claude(#"{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/w/p"}"#), origin: local)
        var desktop = try claude(#"{"hook_event_name":"SessionStart","session_id":"d1","cwd":"/w/q"}"#)
        desktop.process = ClaudeHookProcessInfo(hookPID: 12, claudePID: 13, desktopSessionID: "local_0f3a")
        registry.ingest(desktop, origin: local)
        let focusedTTY = Box<String?>("/dev/ttys004")
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in focusedTTY.get() },
            focusedDesktopSessionURL: { _ in "https://claude.ai/epitaxy/local_0f3a" }
        )
        let ghostty = TerminalScreenTarget(pid: 77, bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        let shownInGhostty = await resolver.sessionShown(target: ghostty)
        XCTAssertEqual(shownInGhostty, "s1")
        focusedTTY.set("/dev/ttys009")
        let shownElsewhere = await resolver.sessionShown(target: ghostty)
        XCTAssertNil(shownElsewhere)
        let desktopTarget = TerminalScreenTarget(pid: 78, bundleID: ClaudeDesktopAllowlist.bundleID)
        let shownInDesktop = await resolver.sessionShown(target: desktopTarget)
        XCTAssertEqual(shownInDesktop, "d1")
        let editor = TerminalScreenTarget(pid: 79, bundleID: "com.apple.TextEdit")
        let shownInEditor = await resolver.sessionShown(target: editor)
        XCTAssertNil(shownInEditor)
    }
}

/// Holds a pane check until the test lets it answer.
private final class AsyncGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}
