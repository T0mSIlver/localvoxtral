import AppKit
import Foundation

/// Shows the user a connection failure the popover line cannot carry. The
/// view model logs, sets its status and error lines and marks the indicator
/// before asking this; the presenter owns only the surface.
@MainActor
protocol ConnectionFailurePresenting {
    func present(title: String, message: String, technicalDetails: String?, log: ConnectionFailureLog)
}

/// The app's modal `NSAlert` with a "Show Log" button that opens the
/// failure's log lines in a window. A no-op where no
/// alert can run: a process without `NSApplication`, and any XCTest process,
/// where `runModal()` would park the whole suite on a click that never comes
/// (xctest sample 2026-07-19).
@MainActor
struct ModalConnectionFailurePresenter: ConnectionFailurePresenting {
    let logWindow = FailureLogWindowController()

    func present(title: String, message: String, technicalDetails: String?, log: ConnectionFailureLog) {
        // NSApp is nil in processes without an NSApplication (unit tests,
        // headless tools); an alert cannot be presented there and force-
        // unwrapping aborts the process (field flake: a leaked connect-timeout
        // timer SIGTRAPed the test runner mid-suite).
        guard NSApp != nil else {
            Log.dictation.error("connection-failure alert skipped: no NSApplication in this process")
            return
        }
        // The nil guard above is NOT sufficient in a test process: any earlier
        // test that touches NSApplication.shared initializes NSApp for the rest
        // of the suite, and runModal() then stops the whole run dead waiting
        // for a click that never comes.
        guard !DictationSessionController.isTestProcess() else {
            Log.dictation.error("connection-failure alert skipped: XCTest process")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        // The alert keeps the one actionable sentence; the raw system error
        // (an NSError, a helper's stderr) goes to the Show Log window.
        alert.informativeText = message
        if let appIcon = NSApplication.shared.applicationIconImage.copy() as? NSImage {
            appIcon.size = NSSize(width: 20, height: 20)
            alert.icon = appIcon
        }

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Log")
        if alert.runModal() == .alertSecondButtonReturn {
            logWindow.show(log, details: Self.windowDetails(message: message, technicalDetails: technicalDetails))
        }
    }

    /// The technical details worth a place above the log lines: none when
    /// empty or a repeat of the alert's sentence.
    static func windowDetails(message: String, technicalDetails: String?) -> String? {
        guard let details = technicalDetails?.trimmed, !details.isEmpty, details != message.trimmed else { return nil }
        return details
    }
}
