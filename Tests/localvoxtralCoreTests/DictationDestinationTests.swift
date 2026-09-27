import Foundation
import XCTest
@testable import localvoxtralCore

/// The overlay's destinations (#840): the focused app, the sessions that
/// need you in answer order, then the Inbox; Tab and ⇧Tab move between them.
final class DictationDestinationTests: XCTestCase {
    func testWithNobodyWaitingOneTabReachesTheInboxAndASecondComesBack() {
        var list = DictationDestinationList(waitingSessionIDs: [], focusedSessionID: nil)
        XCTAssertEqual(list.entries, [.focusedApp, .inbox])
        XCTAssertEqual(list.selected, .focusedApp)
        list.select(list.next)
        XCTAssertEqual(list.selected, .inbox)
        list.select(list.next)
        XCTAssertEqual(list.selected, .focusedApp)
    }

    func testWaitingSessionsSitBetweenTheFocusedAppAndTheInboxInAnswerOrder() {
        var list = DictationDestinationList(waitingSessionIDs: ["pay", "web"], focusedSessionID: nil)
        XCTAssertEqual(list.entries, [.focusedApp, .session(id: "pay"), .session(id: "web"), .inbox])
        list.select(list.next)
        XCTAssertEqual(list.selected, .session(id: "pay"), "one Tab answers the oldest")
        XCTAssertEqual(list.previous, .focusedApp)
        list.select(list.previous)
        XCTAssertEqual(list.previous, .inbox, "⇧Tab from the focused app wraps to the Inbox")
    }

    func testTheSessionTheFocusedPaneShowsIsTheFocusedAppNotASecondEntry() {
        let list = DictationDestinationList(waitingSessionIDs: ["pay", "web", "pay"], focusedSessionID: "pay")
        XCTAssertEqual(list.entries, [.focusedApp, .session(id: "web"), .inbox])
    }

    func testAnOpeningEntryTheListLacksFallsBackToTheFocusedApp() {
        let answer = DictationDestinationList(
            waitingSessionIDs: ["pay"], focusedSessionID: nil, selected: .session(id: "pay"))
        XCTAssertEqual(answer.selected, .session(id: "pay"))
        let gone = DictationDestinationList(
            waitingSessionIDs: [], focusedSessionID: nil, selected: .session(id: "pay"))
        XCTAssertEqual(gone.selected, .focusedApp)
        var list = gone
        XCTAssertFalse(list.select(.session(id: "pay")))
        XCTAssertEqual(list.selected, .focusedApp)
    }

    func testARefreshKeepsThePickedSessionAfterItLeftTheQueueAndAddsNewWaits() {
        var list = DictationDestinationList(waitingSessionIDs: ["a", "b", "c"], focusedSessionID: nil)
        list.select(.session(id: "b"))
        // Picking b answered it; d started waiting meanwhile.
        list.refresh(waitingSessionIDs: ["a", "c", "d"], focusedSessionID: nil)
        XCTAssertEqual(
            list.entries,
            [.focusedApp, .session(id: "a"), .session(id: "b"), .session(id: "c"), .session(id: "d"), .inbox]
        )
        XCTAssertEqual(list.selected, .session(id: "b"))
        list.select(.inbox)
        list.refresh(waitingSessionIDs: ["c"], focusedSessionID: nil)
        XCTAssertEqual(list.entries, [.focusedApp, .session(id: "c"), .inbox])
        XCTAssertEqual(list.selected, .inbox)
    }

    func testAnswerOrderPutsEveryWaitBeforeAnyFinishedTurn() {
        var queue = AgentAttentionQueue()
        let epoch = Date(timeIntervalSince1970: 3_000_000)
        queue.endTurn(sessionID: "done", name: "done", agent: .claude, at: epoch, watched: false)
        queue.wait(sessionID: "late", name: "late", agent: .claude, at: epoch.addingTimeInterval(20))
        queue.wait(sessionID: "early", name: "early", agent: .claude, at: epoch.addingTimeInterval(10))
        XCTAssertEqual(queue.answerOrder.map(\.sessionID), ["early", "late", "done"])
        XCTAssertEqual(queue.next?.sessionID, "early")
    }
}
