import AppKit
import XCTest
@testable import localvoxtral

/// The History pane's delete questions: the explicit deletions ask whether
/// the backups go too, unticked by default, and a retention trim does not
/// ask (#1574).
@MainActor
final class HistoryDeleteAlertTests: XCTestCase {
    private let explicitDeletions: [HistoryDeleteAlert] = [
        .deleteAll(count: 3),
        .retention(.off, count: 3),
        .audioOff(count: 2),
        .recordsOff(count: nil),
    ]

    func testTheBackupsStayUnlessTheBoxIsTicked() throws {
        for question in explicitDeletions {
            let alert = question.makeAlert()
            XCTAssertTrue(alert.showsSuppressionButton, question.title)
            XCTAssertEqual(alert.suppressionButton?.title, HistoryDeleteAlert.backupsCheckboxTitle)
            XCTAssertEqual(
                question.answer(to: .alertFirstButtonReturn, in: alert),
                .delete(removingBackups: false), question.title)
        }
    }

    func testTickingTheBoxDeletesTheBackups() throws {
        for question in explicitDeletions {
            let alert = question.makeAlert()
            alert.suppressionButton?.state = .on
            XCTAssertEqual(
                question.answer(to: .alertFirstButtonReturn, in: alert),
                .delete(removingBackups: true), question.title)
            XCTAssertEqual(question.answer(to: .alertSecondButtonReturn, in: alert), .cancel)
        }
    }

    /// With nothing but backups left, Delete All deletes them and has no
    /// box; Don't keep and the switches still have theirs, since turning
    /// them off does something either way.
    func testWithNothingLeftDeleteAllDeletesTheBackups() {
        let deleteAll = HistoryDeleteAlert.deleteAll(count: 0)
        let alert = deleteAll.makeAlert()
        XCTAssertFalse(alert.showsSuppressionButton)
        XCTAssertEqual(deleteAll.answer(to: .alertFirstButtonReturn, in: alert), .delete(removingBackups: true))
        XCTAssertEqual(deleteAll.answer(to: .alertSecondButtonReturn, in: alert), .cancel)

        for question in [HistoryDeleteAlert.retention(.off, count: 0), .audioOff(count: 0), .recordsOff(count: 0)] {
            let alert = question.makeAlert()
            XCTAssertTrue(alert.showsSuppressionButton, question.title)
            XCTAssertEqual(
                question.answer(to: .alertFirstButtonReturn, in: alert), .delete(removingBackups: false),
                question.title)
        }
    }

    /// A trim to fewer days keeps its snapshot and the quarantine (#985), so
    /// it has no box to tick.
    func testARetentionTrimDoesNotAskAboutTheBackups() {
        let question = HistoryDeleteAlert.retention(.days7, count: 4)
        let alert = question.makeAlert()
        XCTAssertFalse(alert.showsSuppressionButton)
        alert.suppressionButton?.state = .on
        XCTAssertEqual(question.answer(to: .alertFirstButtonReturn, in: alert), .delete(removingBackups: false))
    }
}
