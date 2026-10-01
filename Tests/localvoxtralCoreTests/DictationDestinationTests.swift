import Foundation
import XCTest
@testable import localvoxtralCore

/// The overlay's destinations (#840): the focused app, the Inbox, then the
/// sessions that need you in answer order (#1015); Tab and ⇧Tab move
/// between them.
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

    func testOneTabReachesTheInboxAndWaitingSessionsFollowInAnswerOrder() {
        var list = DictationDestinationList(waitingSessionIDs: ["pay", "web"], focusedSessionID: nil)
        XCTAssertEqual(list.entries, [.focusedApp, .inbox, .session(id: "pay"), .session(id: "web")])
        list.select(list.next)
        XCTAssertEqual(list.selected, .inbox, "one Tab reaches the Inbox with sessions waiting too")
        list.select(list.next)
        XCTAssertEqual(list.selected, .session(id: "pay"), "the second answers the oldest")
        XCTAssertEqual(list.previous, .inbox)
        list.select(.focusedApp)
        XCTAssertEqual(list.previous, .session(id: "web"), "⇧Tab from the focused app wraps to the last session")
    }

    func testTheSessionTheFocusedPaneShowsIsTheFocusedAppNotASecondEntry() {
        let list = DictationDestinationList(waitingSessionIDs: ["pay", "web", "pay"], focusedSessionID: "pay")
        XCTAssertEqual(list.entries, [.focusedApp, .inbox, .session(id: "web")])
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
            [.focusedApp, .inbox, .session(id: "a"), .session(id: "b"), .session(id: "c"), .session(id: "d")]
        )
        XCTAssertEqual(list.selected, .session(id: "b"))
        list.select(.inbox)
        list.refresh(waitingSessionIDs: ["c"], focusedSessionID: nil)
        XCTAssertEqual(list.entries, [.focusedApp, .inbox, .session(id: "c")])
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
