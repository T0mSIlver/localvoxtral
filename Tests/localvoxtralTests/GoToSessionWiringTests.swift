import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import XCTest
@testable import localvoxtral

#if DEBUG
/// "Go to <name>" (#723 step 1) wired into the Overlay Buffer stop, against a
/// fake focuser and the overlay mock. No test here reaches
/// `beginDictationSession`, so none arms the connect timeout.
@MainActor
final class GoToSessionWiringTests: XCTestCase {
    private static let terminalPID: pid_t = 4242
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    override func tearDown() async throws {
        TerminalTargetDetector.debugSecureEventInputOverride = nil
        try await super.tearDown()
    }

    func testANamedSessionComesForwardAndNothingIsTyped() async {
        let harness = makeHarness(text: "Go to payments.", sessions: [session("pay", cwd: "/r/payments")])

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(harness.overlay.committedTexts, [], "the command is not inserted")
        XCTAssertEqual(harness.returns.value, [], "no Return is pressed")
        XCTAssertGreaterThan(harness.overlay.resetCallCount, 0, "the panel goes")
        XCTAssertEqual(harness.records.value.count, 0, "a command is not a dictation")
        XCTAssertEqual(harness.viewModel.statusText, "Ready")
    }

    func testANameNoSessionHasIsCommittedAsText() async {
        let harness = makeHarness(text: "go to the tests", sessions: [session("pay", cwd: "/r/payments")])

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, [])
        XCTAssertEqual(harness.overlay.committedTexts, ["go to the tests"])
    }

    func testAnAmbiguousNameDoesNothingAndSaysSo() async {
        let harness = makeHarness(
            text: "go to localvoxtral",
            sessions: [
                session("a", cwd: "/r/localvoxtral", tty: "/dev/ttys001"),
                session("b", cwd: "/r/localvoxtral", tty: "/dev/ttys002"),
            ]
        )

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, [])
        XCTAssertEqual(harness.overlay.committedTexts, [])
        XCTAssertEqual(harness.viewModel.statusText, DictationSessionController.GoToSessionStatus.ambiguous)
    }

    func testASessionWithNoRouteToItsPaneSaysSoInOneSentence() async {
        let harness = makeHarness(
            text: "go to payments",
            sessions: [session("pay", cwd: "/r/payments")],
            outcome: .unsupported(.remote)
        )

        await harness.stop()

        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(harness.overlay.committedTexts, [])
        XCTAssertEqual(harness.viewModel.statusText, DictationSessionController.GoToSessionStatus.unsupported)
    }

    func testTheStatusSentencesFitThePopoverLine() {
        let sentences = [
            DictationSessionController.GoToSessionStatus.ambiguous,
            DictationSessionController.GoToSessionStatus.unsupported,
            DictationSessionController.GoToSessionStatus.paneNotFound,
        ]
        for sentence in sentences {
            XCTAssertLessThanOrEqual(sentence.count, 44, sentence)
        }
    }

    func testThePolisherNeverSeesTheCommand() async {
        let polishingService = FakePolishingService(returning: "Go to payments.")
        let harness = makeHarness(
            text: "go to payments",
            sessions: [session("pay", cwd: "/r/payments")],
            polishingService: polishingService
        )

        await harness.stop()

        let request = await polishingService.lastRequest
        XCTAssertNil(request)
        XCTAssertEqual(harness.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(harness.overlay.committedTexts, [])
    }

    // MARK: - Harness

    private struct Harness {
        let viewModel: DictationViewModel
        let overlay: MockOverlayCoordinator
        let focuser: FakeSessionPaneFocuser
        let returns: Box<[pid_t]>
        let records: Box<[DictationSessionRecord]>

        @MainActor
        func stop() async {
            viewModel.isDictating = false
            viewModel.isFinalizingStop = true
            viewModel.session.finishStoppedSession(promotePendingSegment: false)
            await awaitStoppedSessionCommit(viewModel)
        }
    }

    private func session(_ id: String, cwd: String, tty: String = "/dev/ttys009") -> ClaudeSessionSnapshot {
        var snapshot = ClaudeSessionSnapshot(sessionID: id, origin: local, firstSeen: Date(timeIntervalSince1970: 0))
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: cwd, origin: local)
        snapshot.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: tty, termProgram: "ghostty")
        return snapshot
    }

    private func makeHarness(
        text: String,
        sessions: [ClaudeSessionSnapshot],
        outcome: SessionPaneFocusOutcome = .focused(bundleID: TerminalScreenAllowlist.ghosttyBundleID),
        polishingService: FakePolishingService? = nil
    ) -> Harness {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.overlaySpokenSendEnabled = true
        if polishingService != nil {
            settings.llmPolishingEnabled = true
            settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"
        }
        let overlay = MockOverlayCoordinator()
        overlay.commitTargetAppPID = Self.terminalPID
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlay,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        if let polishingService {
            viewModel.llmPolishingService = polishingService
        }
        retainForTestProcessLifetime(viewModel)
        viewModel.dependencies.bundleIdentifier = { _ in TerminalScreenAllowlist.ghosttyBundleID }
        let records = Box<[DictationSessionRecord]>([])
        viewModel.dependencies.onSessionRecord = { records.value.append($0) }

        let returns = Box<[pid_t]>([])
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { _ in false },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            returnKeyPoster: { pid in
                returns.value.append(pid)
                return true
            }
        )
        TerminalTargetDetector.debugSecureEventInputOverride = { false }

        let focuser = FakeSessionPaneFocuser(outcome: outcome)
        viewModel.session.sessionNavigator = SessionNavigator(
            liveSessions: { sessions },
            repositoryRoot: { _ in .unknown },
            focuser: focuser,
            sleep: ManualSessionClock().sleep
        )
        viewModel.session.sessionOutputMode = .overlayBuffer
        viewModel.transcript.currentDictationEventText = text
        return Harness(viewModel: viewModel, overlay: overlay, focuser: focuser, returns: returns, records: records)
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
#endif
