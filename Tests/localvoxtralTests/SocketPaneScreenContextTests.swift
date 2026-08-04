import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// One pane.read request as the seam saw it. The pane id here is the whole
/// point of half these tests: it must always be the JOINED pane's id.
private struct PaneReadRequest: Equatable {
    var socketPath: String
    var paneID: String
}

/// Records every pane.read and scripts its answers per call (start, then
/// stop). Focused-pane / foreground answers are fixed: these tests always
/// resolve the same herdr join first, exactly like production.
private final class ScreenTestHerdrPanes: HerdrPaneQuerying, @unchecked Sendable {
    private let visibleTexts: Mutex<[String?]>
    private let requests = Mutex<[PaneReadRequest]>([])
    private let focused: HerdrFocusedPane?
    private let foreground: HerdrPaneForegroundInfo?

    init(
        focusedPaneID: String = "pane-a",
        foregroundPIDs: [Int32]? = [9001],
        visibleTexts: [String?]
    ) {
        focused = HerdrFocusedPane(paneID: focusedPaneID, claimedClaudeSessionID: nil)
        foreground = HerdrPaneForegroundInfo(shellPID: 8000, foregroundPIDs: foregroundPIDs)
        self.visibleTexts = Mutex(visibleTexts)
    }

    var paneReadRequests: [PaneReadRequest] { requests.withLock { $0 } }

    func focusedPane(socketPath _: String) async -> HerdrFocusedPane? { focused }

    func paneForegroundInfo(
        socketPath _: String, paneID _: String
    ) async -> HerdrPaneForegroundInfo? {
        foreground
    }

    func paneVisibleText(socketPath: String, paneID: String) async -> String? {
        requests.withLock {
            $0.append(PaneReadRequest(socketPath: socketPath, paneID: paneID))
        }
        return visibleTexts.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

private final class ScreenTestLiveness: Sendable {
    private let dead: Mutex<Set<Int32>> = Mutex([])
    var probe: @Sendable (Int32) -> Bool { { [self] pid in dead.withLock { !$0.contains(pid) } } }
    func kill(_ pid: Int32) { dead.withLock { _ = $0.insert(pid) } }
}

/// The herdr pane.read screen-context flow: capture at start, reconcile at
/// stop, always about EXACTLY the joined pane, always failing back to the
/// composite-AX decision (vocabulary-only at best for a herdr join) rather
/// than attaching anything it cannot prove.
@MainActor
final class SocketPaneScreenContextTests: XCTestCase {
    private let loopback = URL(string: "http://127.0.0.1:8472/v1/chat/completions")!
    private let ghostty = TerminalScreenTarget(
        pid: 4242,
        bundleID: TerminalScreenAllowlist.ghosttyBundleID
    )
    private let socketPath = "/tmp/herdr-a.sock"
    private let paneText = "swift build\nerror: FooBar.swift:12"

    private func makeRegistry(liveness: ScreenTestLiveness) -> ClaudeSessionRegistry {
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 2_000_000) },
            isProcessAlive: liveness.probe,
            allocateMarkerValue: { "lvx-abcd" }
        )
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: "s1",
                timestamp: 0,
                rawCwd: "/repo",
                prompt: nil,
                files: [],
                process: ClaudeHookProcessInfo(
                    hookPID: 777,
                    claudePID: 9001,
                    tty: "/dev/ttys-inner",
                    herdrPaneID: "pane-a",
                    herdrSocketPath: socketPath
                )
            ),
            origin: .localAuthenticated(peerUID: 501)
        )
        return registry
    }

    private func makeResolver(
        panes: ScreenTestHerdrPanes,
        liveness: ScreenTestLiveness = ScreenTestLiveness()
    ) -> ClaudeSessionJoinResolver {
        ClaudeSessionJoinResolver(
            registry: makeRegistry(liveness: liveness),
            markerInWindowTitle: { _ in nil },
            focusedTerminalTTY: { _ in "/dev/ttys-outer" },
            focusedWindowID: { _ in 101 },
            herdrClientProbe: { _ in true },
            herdrPanes: panes
        )
    }

    private func herdrJoin(
        resolver: ClaudeSessionJoinResolver
    ) async throws -> ClaudeSessionJoin {
        let resolved = await resolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .herdrPane)
        return join
    }

    private func captureAtStart(
        join: ClaudeSessionJoin?,
        resolver: ClaudeSessionJoinResolver?,
        settingEnabled: Bool = true
    ) async -> SocketPaneScreenCapture? {
        await SocketPaneScreenContext.captureAtStart(
            join: join,
            resolver: resolver,
            settingEnabled: settingEnabled,
            endpointURL: loopback,
            isAccessibilityTrusted: true,
            trustedEndpointEnabled: false
        )
    }

    private func reconcileAtStop(
        start: SocketPaneScreenCapture?,
        join: ClaudeSessionJoin?,
        resolver: ClaudeSessionJoinResolver?,
        fallback: TerminalScreenContextDecision,
        settingEnabled: Bool = true
    ) async -> TerminalScreenContextDecision {
        await SocketPaneScreenContext.reconcileAtStop(
            start: start,
            join: join,
            resolver: resolver,
            fallback: fallback,
            settingEnabled: settingEnabled,
            endpointURL: loopback,
            isAccessibilityTrusted: true,
            trustedEndpointEnabled: false
        )
    }

    /// The AX decision a herdr join produces today: vocabulary-only composite
    /// text, never a render (the join authorizer refuses).
    private var axFallback: TerminalScreenContextDecision {
        .vocabularyOnly(startText: "composite AX text", cause: .rawUnauthorized)
    }

    // MARK: - The positive path

    // (a) A herdr join's screen context IS the pane.read excerpt: unchanged
    // pane text renders, and both the excerpt and the grounding text are the
    // PANE's text, not the composite AX capture.
    func testHerdrJoinRendersPaneReadExcerptAtCommit() async throws {
        let panes = ScreenTestHerdrPanes(visibleTexts: [paneText, paneText])
        let resolver = makeResolver(panes: panes)
        let join = try await herdrJoin(resolver: resolver)

        let start = await captureAtStart(join: join, resolver: resolver)
        XCTAssertEqual(start?.text, paneText)
        XCTAssertEqual(start?.paneKey, "pane-a")

        let decision = await reconcileAtStop(
            start: start, join: join, resolver: resolver, fallback: axFallback
        )
        XCTAssertEqual(
            decision,
            .render(excerpt: paneText, startText: paneText, elidedChurnLines: 0)
        )
        XCTAssertEqual(decision.vocabularyGroundingText, paneText)
        XCTAssertNotNil(
            decision.contextBlock(excerpt: paneText, renderBudget: 4_000),
            "a rendered decision must be attachable through the shared block path"
        )
    }

    // (e) Every pane.read is keyed by the JOINED pane's id and socket — never
    // by anything a later read could drift to.
    func testPaneReadRequestsExactlyTheJoinedPaneID() async throws {
        let panes = ScreenTestHerdrPanes(visibleTexts: [paneText, paneText])
        let resolver = makeResolver(panes: panes)
        let join = try await herdrJoin(resolver: resolver)
        XCTAssertEqual(join.herdrPane?.paneID, "pane-a")

        let start = await captureAtStart(join: join, resolver: resolver)
        _ = await reconcileAtStop(
            start: start, join: join, resolver: resolver, fallback: axFallback
        )

        let expected = PaneReadRequest(socketPath: socketPath, paneID: "pane-a")
        XCTAssertEqual(panes.paneReadRequests, [expected, expected])
    }

    // MARK: - Failure falls back to today's behavior

    // (b) pane.read failing changes NOTHING about the composite capture: the
    // AX decision passes through untouched and the authorizer still refuses
    // raw attachment for the herdr join.
    func testCompositeAXNeverAttachesForHerdrJoinEvenWhenPaneReadFails() async throws {
        let panes = ScreenTestHerdrPanes(visibleTexts: [nil, nil])
        let resolver = makeResolver(panes: panes)
        let join = try await herdrJoin(resolver: resolver)

        let start = await captureAtStart(join: join, resolver: resolver)
        XCTAssertNil(start, "a failed pane.read must not produce a capture")

        let decision = await reconcileAtStop(
            start: start, join: join, resolver: resolver, fallback: axFallback
        )
        XCTAssertEqual(decision, axFallback)
        XCTAssertNil(
            decision.contextBlock(excerpt: "composite AX text", renderBudget: 4_000),
            "the composite AX text must never become an attachable block"
        )

        let gate = TerminalScreenClaudeJoinAuthorizer(
            resolver: resolver, currentJoin: { join }
        )
        XCTAssertFalse(
            gate.isAuthorized(target: ghostty, windowID: 101),
            "the herdr join must keep refusing composite raw screen attachment"
        )
    }

    // (c) A start capture whose stop re-read fails degrades to exactly the
    // composite-AX fallback: vocabulary-only, nothing attached.
    func testStopReadFailureFallsBackToCompositeVocabularyOnly() async throws {
        let panes = ScreenTestHerdrPanes(visibleTexts: [paneText, nil])
        let resolver = makeResolver(panes: panes)
        let join = try await herdrJoin(resolver: resolver)

        let start = await captureAtStart(join: join, resolver: resolver)
        XCTAssertNotNil(start)

        let decision = await reconcileAtStop(
            start: start, join: join, resolver: resolver, fallback: axFallback
        )
        XCTAssertEqual(decision, axFallback)
    }

    // Whitespace-only pane text sanitizes to nothing — garbage, not context.
    func testWhitespaceOnlyPaneTextIsGarbageAndFallsBack() async throws {
        let panes = ScreenTestHerdrPanes(visibleTexts: ["   \n\n   \n"])
        let resolver = makeResolver(panes: panes)
        let join = try await herdrJoin(resolver: resolver)

        let start = await captureAtStart(join: join, resolver: resolver)
        XCTAssertNil(start)
    }

    // MARK: - Sanitization and bounding

    // (d) Pane text rides the SAME sanitize/cap pipeline as an AX read:
    // control characters are stripped, the head is capped at the shared
    // screen character budget.
    func testPaneTextIsControlStrippedAndCapped() async throws {
        let oversized = "bell\u{07} and escape\u{1B}[31m kept-text\n"
            + String(repeating: "x", count: TerminalScreenAXReader.screenCharacterCap + 5_000)
        let panes = ScreenTestHerdrPanes(visibleTexts: [oversized])
        let resolver = makeResolver(panes: panes)
        let join = try await herdrJoin(resolver: resolver)

        let start = await captureAtStart(join: join, resolver: resolver)
        let text = try XCTUnwrap(start?.text)
        XCTAssertFalse(text.contains("\u{07}"))
        XCTAssertFalse(text.contains("\u{1B}"))
        XCTAssertTrue(text.contains("kept-text"))
        XCTAssertLessThanOrEqual(text.count, TerminalScreenAXReader.screenCharacterCap)
        XCTAssertEqual(text, TerminalScreenAXReader.sanitizedScreenText(oversized))
    }

    // MARK: - The shared truth table still applies

    // A pane that streamed new output between start and stop keeps grounding
    // from the START pane text (what the user could see while speaking) but
    // renders nothing.
    func testChangedPaneTextDegradesToPaneVocabularyOnly() async throws {
        let stopText = paneText + "\nBuild complete."
        let panes = ScreenTestHerdrPanes(visibleTexts: [paneText, stopText])
        let resolver = makeResolver(panes: panes)
        let join = try await herdrJoin(resolver: resolver)

        let start = await captureAtStart(join: join, resolver: resolver)
        let decision = await reconcileAtStop(
            start: start, join: join, resolver: resolver, fallback: axFallback
        )

        guard case let .vocabularyOnly(startText, cause) = decision,
              case .screenChanged = cause
        else {
            return XCTFail("expected vocabularyOnly(screenChanged), got \(decision)")
        }
        XCTAssertEqual(
            startText, paneText,
            "grounding must use the PANE text the user saw, not the composite AX capture"
        )
    }

    // A session that died mid-dictation may still ground (the user saw the
    // text while speaking) but must not render — same rule as the AX
    // authorizer's final liveness check.
    func testDeadSessionAtStopWithholdsRenderKeepsPaneVocabulary() async throws {
        let liveness = ScreenTestLiveness()
        let panes = ScreenTestHerdrPanes(visibleTexts: [paneText, paneText])
        let resolver = makeResolver(panes: panes, liveness: liveness)
        let join = try await herdrJoin(resolver: resolver)

        let start = await captureAtStart(join: join, resolver: resolver)
        liveness.kill(9001)

        let decision = await reconcileAtStop(
            start: start, join: join, resolver: resolver, fallback: axFallback
        )
        XCTAssertEqual(
            decision,
            .vocabularyOnly(startText: paneText, cause: .rawUnauthorized)
        )
    }

    // Consent withdrawn mid-session destroys the pane text — it must not
    // survive even as grounding, and a non-drop fallback must not resurrect it.
    func testPolicyRejectedAtStopDropsPaneText() async throws {
        let panes = ScreenTestHerdrPanes(visibleTexts: [paneText, paneText])
        let resolver = makeResolver(panes: panes)
        let join = try await herdrJoin(resolver: resolver)
        let start = await captureAtStart(join: join, resolver: resolver)

        let withDropFallback = await reconcileAtStop(
            start: start, join: join, resolver: resolver,
            fallback: .drop(reason: .policyRejected),
            settingEnabled: false
        )
        XCTAssertEqual(withDropFallback, .drop(reason: .policyRejected))

        let withVocabFallback = await reconcileAtStop(
            start: start, join: join, resolver: resolver,
            fallback: axFallback,
            settingEnabled: false
        )
        XCTAssertEqual(withVocabFallback, .drop(reason: .policyRejected))
    }

    // MARK: - pane.read never fires outside a herdr join

    // (1) The capture refuses a non-herdr join before any socket request, and
    // the resolver's accessor does the same — no other mechanism can reach
    // herdr's socket through this path.
    func testNonHerdrJoinNeverTriggersPaneRead() async throws {
        let panes = ScreenTestHerdrPanes(visibleTexts: [paneText])
        let liveness = ScreenTestLiveness()
        // A registry whose session joins via TTY: same session, no herdr arm.
        let registry = makeRegistry(liveness: liveness)
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in nil },
            focusedTerminalTTY: { _ in "/dev/ttys-inner" },
            focusedWindowID: { _ in 101 },
            herdrClientProbe: { _ in true },
            herdrPanes: panes
        )
        let resolved = await resolver.resolve(target: ghostty)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .ttyDevice)
        XCTAssertNil(join.herdrPane)

        let start = await captureAtStart(join: join, resolver: resolver)
        XCTAssertNil(start)
        let direct = await resolver.herdrPaneVisibleText(for: join)
        XCTAssertNil(direct)
        XCTAssertEqual(panes.paneReadRequests, [], "no pane.read may fire without a herdr join")
    }

    // The consent gate precedes the socket: an opted-out user's pane is never
    // read at all, not read-and-discarded.
    func testCaptureGateRejectionMakesNoSocketRequest() async throws {
        let panes = ScreenTestHerdrPanes(visibleTexts: [paneText])
        let resolver = makeResolver(panes: panes)
        let join = try await herdrJoin(resolver: resolver)

        let start = await captureAtStart(
            join: join, resolver: resolver, settingEnabled: false
        )
        XCTAssertNil(start)
        XCTAssertEqual(panes.paneReadRequests, [])
    }
}

/// The same start/stop pipeline, driven by a cmux surface join instead of a
/// herdr pane. The point of these is that the route changed and NOTHING else
/// did: same consent gate, same sanitize/cap, same reconcile truth table.
private final class ScreenTestCmuxSurfaces: CmuxSurfaceQuerying, @unchecked Sendable {
    private let texts: Mutex<[CmuxQueryResult<String>]>
    private let requests = Mutex<[String]>([])
    private let focusedSurfaceID: String

    init(focusedSurfaceID: String = "surface-a", texts: [CmuxQueryResult<String>]) {
        self.focusedSurfaceID = focusedSurfaceID
        self.texts = Mutex(texts)
    }

    var readRequests: [String] { requests.withLock { $0 } }

    func focusedSurface(expectedPeerPID: pid_t) async -> CmuxQueryResult<CmuxFocusedSurface> {
        .value(
            CmuxFocusedSurface(
                surfaceID: focusedSurfaceID,
                // The local sub-arm REQUIRES both ttys, so the fixture's
                // session tty and this one agree.
                tty: "/dev/ttys004",
                workspaceIsRemote: false
            )
        )
    }

    func surfaceText(
        surfaceID: String, expectedPeerPID: pid_t
    ) async -> CmuxQueryResult<String> {
        requests.withLock { $0.append(surfaceID) }
        return texts.withLock { $0.isEmpty ? .unavailable : $0.removeFirst() }
    }
}

@MainActor
final class CmuxSurfaceScreenContextTests: XCTestCase {
    private let loopback = URL(string: "http://127.0.0.1:8472/v1/chat/completions")!
    private let cmux = TerminalScreenTarget(
        pid: 4242,
        bundleID: TerminalScreenAllowlist.cmuxBundleID
    )
    private let surfaceID = "surface-a"
    private let paneText = "swift build\nerror: FooBar.swift:12"

    private func makeResolver(
        surfaces: ScreenTestCmuxSurfaces,
        liveness: ScreenTestLiveness = ScreenTestLiveness()
    ) -> ClaudeSessionJoinResolver {
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 2_000_000) },
            isProcessAlive: liveness.probe,
            allocateMarkerValue: { "lvx-abcd" }
        )
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: "s1",
                timestamp: 0,
                rawCwd: "/repo",
                prompt: nil,
                files: [],
                process: ClaudeHookProcessInfo(
                    hookPID: 777,
                    claudePID: 9001,
                    tty: "/dev/ttys004",
                    cmuxSurfaceID: surfaceID
                )
            ),
            origin: .localAuthenticated(peerUID: 501)
        )
        return ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in nil },
            focusedTerminalTTY: { _ in nil },
            focusedWindowID: { _ in 101 },
            cmuxSurfaces: surfaces,
            cmuxJoinEnabled: { true }
        )
    }

    private func cmuxJoin(
        resolver: ClaudeSessionJoinResolver
    ) async throws -> ClaudeSessionJoin {
        let resolved = await resolver.resolve(target: cmux)
        let join = try XCTUnwrap(resolved)
        XCTAssertEqual(join.mechanism, .cmuxSurface)
        return join
    }

    private func captureAtStart(
        join: ClaudeSessionJoin?,
        resolver: ClaudeSessionJoinResolver?,
        settingEnabled: Bool = true
    ) async -> SocketPaneScreenCapture? {
        await SocketPaneScreenContext.captureAtStart(
            join: join,
            resolver: resolver,
            settingEnabled: settingEnabled,
            endpointURL: loopback,
            isAccessibilityTrusted: true,
            trustedEndpointEnabled: false
        )
    }

    private func reconcileAtStop(
        start: SocketPaneScreenCapture?,
        join: ClaudeSessionJoin?,
        resolver: ClaudeSessionJoinResolver?,
        settingEnabled: Bool = true
    ) async -> TerminalScreenContextDecision {
        await SocketPaneScreenContext.reconcileAtStop(
            start: start,
            join: join,
            resolver: resolver,
            // For a cmux join the AX fallback carries nothing: there is no
            // accessible text to have captured in the first place.
            fallback: .drop(reason: .noStartCapture),
            settingEnabled: settingEnabled,
            endpointURL: loopback,
            isAccessibilityTrusted: true,
            trustedEndpointEnabled: false
        )
    }

    func testCmuxJoinRendersTheSurfaceExcerptAtCommit() async throws {
        let surfaces = ScreenTestCmuxSurfaces(texts: [.value(paneText), .value(paneText)])
        let resolver = makeResolver(surfaces: surfaces)
        let join = try await cmuxJoin(resolver: resolver)

        let start = await captureAtStart(join: join, resolver: resolver)
        XCTAssertEqual(start?.text, paneText)
        XCTAssertEqual(start?.paneKey, surfaceID)

        let decision = await reconcileAtStop(start: start, join: join, resolver: resolver)
        XCTAssertEqual(
            decision,
            .render(excerpt: paneText, startText: paneText, elidedChurnLines: 0)
        )
        XCTAssertEqual(surfaces.readRequests, [surfaceID, surfaceID])
    }

    func testSurfaceTextIsControlStrippedAndCapped() async throws {
        let noisy = "\u{1B}[31mred\u{1B}[0m\u{07}\n"
            + String(repeating: "x", count: TerminalScreenAXReader.screenCharacterCap + 500)
        let surfaces = ScreenTestCmuxSurfaces(texts: [.value(noisy)])
        let resolver = makeResolver(surfaces: surfaces)
        let join = try await cmuxJoin(resolver: resolver)

        let captured = await captureAtStart(join: join, resolver: resolver)
        let start = try XCTUnwrap(captured)
        XCTAssertLessThanOrEqual(start.text.count, TerminalScreenAXReader.screenCharacterCap)
        XCTAssertFalse(start.text.contains("\u{1B}"))
        XCTAssertFalse(start.text.contains("\u{07}"))
    }

    func testConsentGateRejectionMakesNoSocketRequest() async throws {
        let surfaces = ScreenTestCmuxSurfaces(texts: [.value(paneText)])
        let resolver = makeResolver(surfaces: surfaces)
        let join = try await cmuxJoin(resolver: resolver)

        let captured = await captureAtStart(
            join: join, resolver: resolver, settingEnabled: false
        )
        XCTAssertNil(captured)
        XCTAssertEqual(surfaces.readRequests, [])
    }

    func testAuthFailureAtStartAttachesNothing() async throws {
        let surfaces = ScreenTestCmuxSurfaces(texts: [.authenticationRequired])
        let resolver = makeResolver(surfaces: surfaces)
        let join = try await cmuxJoin(resolver: resolver)

        let captured = await captureAtStart(join: join, resolver: resolver)
        XCTAssertNil(captured)
    }

    func testConsentWithdrawnAtStopDestroysTheSurfaceText() async throws {
        let surfaces = ScreenTestCmuxSurfaces(texts: [.value(paneText), .value(paneText)])
        let resolver = makeResolver(surfaces: surfaces)
        let join = try await cmuxJoin(resolver: resolver)
        let start = await captureAtStart(join: join, resolver: resolver)

        // A NON-drop fallback on purpose: withdrawal must destroy the pane
        // text rather than fall back to whatever the AX path had, so the
        // interesting case is the one where the fallback still carries text.
        let decision = await SocketPaneScreenContext.reconcileAtStop(
            start: start,
            join: join,
            resolver: resolver,
            fallback: .vocabularyOnly(startText: "stale AX text", cause: .rawUnauthorized),
            settingEnabled: false,
            endpointURL: loopback,
            isAccessibilityTrusted: true,
            trustedEndpointEnabled: false
        )

        XCTAssertEqual(decision, .drop(reason: .policyRejected))
        XCTAssertNil(decision.vocabularyGroundingText)
    }

    func testDeadSessionAtStopWithholdsTheRenderButKeepsGrounding() async throws {
        let liveness = ScreenTestLiveness()
        let surfaces = ScreenTestCmuxSurfaces(texts: [.value(paneText), .value(paneText)])
        let resolver = makeResolver(surfaces: surfaces, liveness: liveness)
        let join = try await cmuxJoin(resolver: resolver)
        let start = await captureAtStart(join: join, resolver: resolver)
        liveness.kill(9001)

        let decision = await reconcileAtStop(start: start, join: join, resolver: resolver)

        XCTAssertEqual(decision.vocabularyGroundingText, paneText)
        XCTAssertNil(decision.contextBlock(excerpt: paneText, renderBudget: 4_000))
    }

    func testAStopReadForADifferentSurfaceIsNotReconciled() async throws {
        let surfaces = ScreenTestCmuxSurfaces(texts: [.value(paneText), .value(paneText)])
        let resolver = makeResolver(surfaces: surfaces)
        let join = try await cmuxJoin(resolver: resolver)
        let start = SocketPaneScreenCapture(text: paneText, paneKey: "some-other-surface")

        let decision = await reconcileAtStop(start: start, join: join, resolver: resolver)

        XCTAssertEqual(decision, .drop(reason: .noStartCapture))
    }
}
