import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import XCTest
@testable import localvoxtral

#if DEBUG
/// The needs-you cue's app surfaces (#717): the menu bar mark, the popover
/// line, the banner, and what a dictation into the waiting session does to
/// them. The queue itself is `AgentAttentionTests` (core). These lived in
/// `AnswerAgentTests`, which went with the shortcut that brought the waiting
/// pane forward; the cue stays, and "the cue tells you, you switch yourself".
@MainActor
final class AgentAttentionWiringTests: XCTestCase {
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    func testTheIconAndThePopoverLineShowOnlyWhileTheCueIsOn() {
        let h = makeHarness(sessions: ["pay": "/r/payments"])
        // External modes: no managed backend decides the icon.
        h.viewModel.settings.dictationBackendMode = .externalURL
        h.viewModel.settings.polishingBackendMode = .externalURL
        XCTAssertEqual(h.viewModel.menuBarIndicatorState, .idle)

        h.tracker.receive(.notification, session: h.sessions["pay"]!)

        XCTAssertEqual(h.viewModel.agentAttentionLine, "payments needs you")
        XCTAssertEqual(h.viewModel.menuBarIndicatorState, .agentNeedsYou)
        XCTAssertEqual(h.announcer.announced.map(\.sessionID), ["pay"])

        h.viewModel.settings.agentAttentionEnabled = false
        XCTAssertNil(h.viewModel.agentAttentionLine)
        XCTAssertEqual(h.viewModel.menuBarIndicatorState, .idle)
    }

    func testASessionLeavingTheQueueTakesItsBannerDown() {
        let h = makeHarness(sessions: ["pay": "/r/payments"])
        h.tracker.receive(.notification, session: h.sessions["pay"]!)
        h.tracker.receive(.userPromptSubmit, session: h.sessions["pay"]!)
        XCTAssertEqual(h.announcer.withdrawn, [["pay"]])
    }

    func testADictationThatJoinsASessionAnswersIt() {
        let h = makeHarness(sessions: ["pay": "/r/payments"])
        h.tracker.receive(.notification, session: h.sessions["pay"]!)
        h.viewModel.session.noteDictationJoinedAgentSession("pay")
        XCTAssertTrue(h.tracker.queue.isEmpty)
        XCTAssertNil(h.viewModel.agentAttentionLine)
    }

    // MARK: - Harness

    private struct Harness {
        let viewModel: DictationViewModel
        let tracker: AgentAttentionTracker
        let announcer: RecordingAnnouncer
        let sessions: [String: ClaudeSessionSnapshot]
    }

    private func makeHarness(sessions cwdByID: [String: String]) -> Harness {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.agentAttentionEnabled = true
        let viewModel = DictationViewModel(settings: settings, startRuntimeServices: false)
        viewModel.appConfigStore = MockAppConfigStore()
        retainForTestProcessLifetime(viewModel)

        var sessions: [String: ClaudeSessionSnapshot] = [:]
        for (id, cwd) in cwdByID {
            var snapshot = ClaudeSessionSnapshot(sessionID: id, origin: local, firstSeen: Date(timeIntervalSince1970: 0))
            snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: cwd, origin: local)
            snapshot.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: "/dev/ttys00\(sessions.count)")
            sessions[id] = snapshot
        }
        let live = sessions
        var tick = 0.0
        let tracker = AgentAttentionTracker(
            isEnabled: { settings.agentAttentionEnabled },
            isWatching: { _ in false },
            liveSessionIDs: { Set(live.keys) },
            now: {
                tick += 1
                return Date(timeIntervalSince1970: tick)
            }
        )
        let announcer = RecordingAnnouncer()
        viewModel.agentAttention = AgentAttentionModel(tracker: tracker, announcer: announcer)
        return Harness(viewModel: viewModel, tracker: tracker, announcer: announcer, sessions: sessions)
    }
}

@MainActor
private final class RecordingAnnouncer: AgentAttentionAnnouncing {
    private(set) var announced: [AgentAttentionEntry] = []
    private(set) var withdrawn: [Set<String>] = []

    func requestPermission() {}
    func announce(_ entry: AgentAttentionEntry) { announced.append(entry) }
    func withdraw(sessionIDs: Set<String>) { withdrawn.append(sessionIDs) }
}
#endif
