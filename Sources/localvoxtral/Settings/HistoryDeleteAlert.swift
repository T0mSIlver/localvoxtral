import AppKit

/// The question before the History pane deletes what the user chose to
/// delete. Delete All, Don't keep and the storage switches also ask whether
/// the backups go: the History snapshots and the quarantine keep a copy of
/// what is deleted, and they go only when the box is ticked (#1574). An
/// `NSAlert` rather than a SwiftUI dialog, which cannot hold a checkbox.
@MainActor
struct HistoryDeleteAlert {
    let title: String
    let message: String
    let deleteTitle: String
    var backups = Backups.ask

    /// What the alert does with the backups.
    enum Backups {
        /// The "Also delete the backups" box decides.
        case ask
        /// A retention trim keeps them, so there is no box.
        case keep
        /// Nothing but backups is left to delete, so deleting is deleting
        /// them, and a box that kept them would leave the button doing
        /// nothing.
        case delete
    }

    static let backupsCheckboxTitle = "Also delete the backups"

    /// What the user answered.
    enum Answer: Equatable {
        case cancel
        case delete(removingBackups: Bool)
    }

    /// The alert, unshown: Delete first, so Return deletes as the dialog it
    /// replaces did, and the box unticked, so the backups stay unless the
    /// user says otherwise.
    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: deleteTitle).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if backups == .ask {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = Self.backupsCheckboxTitle
            alert.suppressionButton?.state = .off
        }
        return alert
    }

    /// `alert` is the one `makeAlert()` made.
    func answer(to response: NSApplication.ModalResponse, in alert: NSAlert) -> Answer {
        guard response == .alertFirstButtonReturn else { return .cancel }
        switch backups {
        case .ask: return .delete(removingBackups: alert.suppressionButton?.state == .on)
        case .keep: return .delete(removingBackups: false)
        case .delete: return .delete(removingBackups: true)
        }
    }

    /// Shows the alert as a sheet on `window`, or on its own without one,
    /// and calls `onDelete` unless the user cancels.
    func present(on window: NSWindow?, onDelete: @escaping @MainActor (_ removingBackups: Bool) -> Void) {
        let alert = makeAlert()
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if case .delete(let removingBackups) = answer(to: response, in: alert) {
                onDelete(removingBackups)
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

// MARK: - The History pane's questions

extension HistoryDeleteAlert {
    private static let backupsKeepHistory = "The backups kept in case History is lost still hold them."

    private static let backupsHoldEarlier = "The backups kept in case History is lost still hold earlier dictations."

    /// With no dictation left, Delete All deletes what the backups hold.
    static func deleteAll(count: Int) -> HistoryDeleteAlert {
        guard count > 0 else {
            return HistoryDeleteAlert(
                title: "Delete the backups?",
                message: "History is empty. Its backups still hold earlier dictations, recordings or diagnostic records.",
                deleteTitle: "Delete Backups",
                backups: .delete)
        }
        return HistoryDeleteAlert(
            title: "Delete all \(count.formatted()) dictations?",
            message: backupsKeepHistory,
            deleteTitle: "Delete All")
    }

    /// A shorter retention: Don't keep asks about the backups, a trim to
    /// fewer days keeps them. `count` is nil when the store could not count.
    static func retention(_ retention: DictationHistoryRetention, count: Int?) -> HistoryDeleteAlert {
        let deleteTitle: String
        switch count {
        case nil: deleteTitle = "Delete"
        case 1?: deleteTitle = "Delete 1 Dictation"
        case let count?: deleteTitle = "Delete \(count.formatted()) Dictations"
        }
        if !retention.savesDictations, count == 0 {
            return HistoryDeleteAlert(
                title: "Stop keeping dictations?",
                message: "New dictations won't be saved, and term suggestions stop. \(backupsHoldEarlier)",
                deleteTitle: "Stop Keeping")
        }
        guard retention.savesDictations else {
            return HistoryDeleteAlert(
                title: "Delete every saved dictation?",
                message: "New dictations won't be saved, and term suggestions stop. \(backupsKeepHistory)",
                deleteTitle: deleteTitle)
        }
        return HistoryDeleteAlert(
            title: "Delete dictations older than \(retention.days ?? 0) days?",
            message: "This can't be undone.",
            deleteTitle: deleteTitle,
            backups: .keep)
    }

    /// Without a count (not read yet, or the read failed) the question
    /// names none.
    static func audioOff(count: Int?) -> HistoryDeleteAlert {
        let title: String
        switch count {
        case 0?:
            return HistoryDeleteAlert(
                title: "Stop keeping dictation audio?",
                message: "The backups keep the recordings of dictations deleted in the last 30 days.",
                deleteTitle: "Stop Keeping")
        case nil: title = "Delete every recording?"
        case 1?: title = "Delete 1 recording?"
        case let count?: title = "Delete \(count.formatted()) recordings?"
        }
        return HistoryDeleteAlert(
            title: title,
            message: "The dictations stay. The backups keep the recordings of dictations deleted in the last 30 days.",
            deleteTitle: "Delete Recordings")
    }

    static func recordsOff(count: Int?) -> HistoryDeleteAlert {
        let title: String
        switch count {
        case 0?:
            return HistoryDeleteAlert(
                title: "Stop keeping diagnostic records?",
                message: "The backups keep the diagnostic records of dictations deleted in the last 30 days.",
                deleteTitle: "Stop Keeping")
        case nil: title = "Delete every diagnostic record?"
        case 1?: title = "Delete 1 diagnostic record?"
        case let count?: title = "Delete \(count.formatted()) diagnostic records?"
        }
        return HistoryDeleteAlert(
            title: title,
            message:
                "The dictations stay. The backups keep the diagnostic records of dictations deleted in the last 30 days.",
            deleteTitle: "Delete Records")
    }
}
