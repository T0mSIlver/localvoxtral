import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore

/// A cmux socket in memory: every write answers `writeAnswer`, and the
/// focused surface is `focusedSurfaceID`.
private final class RouteTestCmux: CmuxSurfaceQuerying, CmuxSurfaceWriting, @unchecked Sendable {
    let writeAnswer: CmuxWriteResult
    let workspaceIsRemote: Bool?
    /// The focused surface each `focusedSurface` call reports, in turn; the
    /// last one repeats.
    private let focusSequence: Mutex<[String?]>
    private let sent = Mutex<[String]>([])

    init(writeAnswer: CmuxWriteResult, focusSequence: [String?], workspaceIsRemote: Bool? = nil) {
        self.writeAnswer = writeAnswer
        self.focusSequence = Mutex(focusSequence)
        self.workspaceIsRemote = workspaceIsRemote
    }

    var writes: [String] { sent.withLock { $0 } }

    func focusedSurface(expectedPeerPID _: pid_t) async -> CmuxQueryResult<CmuxFocusedSurface> {
        let focused = focusSequence.withLock { $0.count > 1 ? $0.removeFirst() : $0.first ?? nil }
        return focused.map { .value(CmuxFocusedSurface(surfaceID: $0, workspaceIsRemote: workspaceIsRemote)) }
            ?? .unavailable
    }

    func surfaceText(surfaceID _: String, expectedPeerPID _: pid_t) async -> CmuxQueryResult<String> {
        .unavailable
    }

    func sendText(_ text: String, surfaceID: String, expectedPeerPID _: pid_t) async -> CmuxWriteResult {
        sent.withLock { $0.append("\(surfaceID) text \(text)") }
        return writeAnswer
    }

    func sendEnter(surfaceID: String, expectedPeerPID _: pid_t) async -> CmuxWriteResult {
        sent.withLock { $0.append("\(surfaceID) enter") }
        return writeAnswer
    }
}

@MainActor
final class CmuxSurfaceRouteTests: XCTestCase {
    private let surface = "22222222-2222-2222-2222-222222222222"
    private let otherSurface = "99999999-9999-9999-9999-999999999999"
    private let cmuxPID: pid_t = 4242

    private func deliver(
        _ call: AgentPromptCall = .append("run the tests"),
        answer: CmuxWriteResult,
        focused: String?,
        focusSequence: [String?]? = nil,
        frontmost: pid_t?,
        enabled: Bool = true,
        sessionHoldsSurface: Bool = true,
        remote: (join: Bool, workspaceIsRemote: Bool?) = (false, nil)
    ) async -> (AgentPromptDelivery, [String]) {
        let cmux = RouteTestCmux(
            writeAnswer: answer, focusSequence: focusSequence ?? [focused],
            workspaceIsRemote: remote.workspaceIsRemote
        )
        let route = CmuxSurfaceRoute(
            surfaceID: surface, cmuxPID: cmuxPID, client: cmux,
            isEnabled: { enabled }, frontmostPID: { frontmost },
            sessionHoldsSurface: { sessionHoldsSurface },
            isRemoteJoin: remote.join
        )
        return (await route.deliver(call), cmux.writes)
    }

    func testAReportedDeliveryIsDeliveredWhereverFocusIs() async {
        for queued in [false, true] {
            let (outcome, writes) = await deliver(answer: .accepted(queued: queued), focused: otherSurface, frontmost: 1)
            XCTAssertEqual(outcome, .delivered)
            XCTAssertEqual(writes, ["\(surface) text run the tests"])
        }
        let (submit, writes) = await deliver(.submit, answer: .accepted(queued: false), focused: nil, frontmost: nil)
        XCTAssertEqual(submit, .delivered)
        XCTAssertEqual(writes, ["\(surface) enter"])
    }

    /// An older cmux with no delivery report can drop text sent to an
    /// unfocused tab (manaflow-ai/cmux#3129): its success counts only while
    /// the surface is focused, and otherwise the text is in History.
    func testAnUnreportedDeliveryCountsOnlyOnTheFocusedSurface() async {
        let (onFocused, _) = await deliver(answer: .accepted(queued: nil), focused: surface, frontmost: 1)
        XCTAssertEqual(onFocused, .delivered)
        let (onUnfocused, _) = await deliver(answer: .accepted(queued: nil), focused: otherSurface, frontmost: cmuxPID)
        XCTAssertEqual(onUnfocused, .keepInHistory)
        // Focused only once the write was out: it may have been dropped.
        let (focusedLate, _) = await deliver(answer: .accepted(queued: nil), focused: nil,
                                             focusSequence: [otherSurface, surface], frontmost: cmuxPID)
        XCTAssertEqual(focusedLate, .keepInHistory)
    }

    /// A `cmux ssh` session can exit without the registry hearing of it, so
    /// an Enter needs cmux to report the surface focused and remote-hosted.
    func testARemoteJoinSubmitsOnlyWhileCmuxReportsTheSurfaceRemoteHosted() async {
        let (hosted, hostedWrites) = await deliver(.submit, answer: .accepted(queued: false), focused: surface,
                                                   frontmost: 1, remote: (true, true))
        XCTAssertEqual(hosted, .delivered)
        XCTAssertEqual(hostedWrites, ["\(surface) enter"])
        for workspaceIsRemote in [false, nil] as [Bool?] {
            let (outcome, writes) = await deliver(.submit, answer: .accepted(queued: false), focused: surface,
                                                  frontmost: 1, remote: (true, workspaceIsRemote))
            XCTAssertEqual(outcome, .keepInHistory)
            XCTAssertEqual(writes, [], "no Enter into what may now be a local shell")
        }
    }

    /// Nothing was sent: typed while cmux is frontmost, unless cmux says
    /// another surface is focused; a socket that cannot answer (cmux left
    /// password mode) still types, as dictation did before the route.
    func testARefusalTypesOnlyWhereTheKeysReachTheSurface() async {
        let (focused, _) = await deliver(answer: .refused, focused: surface, frontmost: cmuxPID)
        XCTAssertEqual(focused, .typeInstead)
        let (otherApp, _) = await deliver(answer: .refused, focused: surface, frontmost: 77)
        XCTAssertEqual(otherApp, .keepInHistory)
        let (otherSurface, _) = await deliver(answer: .refused, focused: otherSurface, frontmost: cmuxPID)
        XCTAssertEqual(otherSurface, .keepInHistory)
        let (unknown, _) = await deliver(answer: .refused, focused: nil, frontmost: cmuxPID)
        XCTAssertEqual(unknown, .typeInstead, "the socket is gone; keys behave as with no route")
    }

    func testAnUnconfirmedWriteIsNeverTypedAgain() async {
        let (outcome, _) = await deliver(answer: .unconfirmed, focused: surface, frontmost: cmuxPID)
        XCTAssertEqual(outcome, .keepInHistory)
    }

    /// cmux turns a newline into Return and Escape into a key: such text is
    /// never sent.
    func testControlCharactersAreNeverSent() async {
        for text in ["line one\nline two", "a\rb", "tab\there", "\u{1B}[A", "del\u{7F}", "c1\u{9B}2J"] {
            let (outcome, writes) = await deliver(.append(text), answer: .accepted(queued: false), focused: surface, frontmost: cmuxPID)
            XCTAssertEqual(outcome, .typeInstead, text.debugDescription)
            XCTAssertEqual(writes, [], text.debugDescription)
        }
        XCTAssertTrue(CmuxSurfaceRoute.isSendable("naïve café — ✓ 日本語"))
    }

    /// The agent exited: the surface is a shell, where an Enter would run
    /// the dictation.
    func testASessionThatLeftTheSurfaceGetsNothing() async {
        let (submit, writes) = await deliver(.submit, answer: .accepted(queued: false), focused: surface,
                                             frontmost: cmuxPID, sessionHoldsSurface: false)
        XCTAssertEqual(submit, .keepInHistory)
        XCTAssertEqual(writes, [])
    }

    func testTurningTheJoinOffStopsTheWrites() async {
        let (outcome, writes) = await deliver(answer: .accepted(queued: false), focused: surface, frontmost: 1, enabled: false)
        XCTAssertEqual(outcome, .keepInHistory)
        XCTAssertEqual(writes, [])
    }
}
