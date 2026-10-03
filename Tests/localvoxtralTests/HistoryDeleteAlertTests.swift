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
                HistoryDeleteAlert.answer(to: .alertFirstButtonReturn, in: alert),
                .delete(removingBackups: false), question.title)
        }
    }

    func testTickingTheBoxDeletesTheBackups() throws {
        for question in explicitDeletions {
            let alert = question.makeAlert()
            alert.suppressionButton?.state = .on
            XCTAssertEqual(
                HistoryDeleteAlert.answer(to: .alertFirstButtonReturn, in: alert),
                .delete(removingBackups: true), question.title)
            XCTAssertEqual(HistoryDeleteAlert.answer(to: .alertSecondButtonReturn, in: alert), .cancel)
        }
    }

    /// A trim to fewer days keeps its snapshot and the quarantine (#985), so
    /// it has no box to tick.
    func testARetentionTrimDoesNotAskAboutTheBackups() {
        let alert = HistoryDeleteAlert.retention(.days7, count: 4).makeAlert()
        XCTAssertFalse(alert.showsSuppressionButton)
        alert.suppressionButton?.state = .on
        XCTAssertEqual(
            HistoryDeleteAlert.answer(to: .alertFirstButtonReturn, in: alert), .delete(removingBackups: false))
    }
}
