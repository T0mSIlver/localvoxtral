import AppKit
import Foundation

/// Shows the user a connection failure the popover line cannot carry. The
/// view model logs, sets its status and error lines and marks the indicator
/// before asking this; the presenter owns only the surface.
@MainActor
protocol ConnectionFailurePresenting {
    func present(title: String, message: String, technicalDetails: String?)
}

/// The app's modal `NSAlert` with an "Open Console" button. A no-op where no
/// alert can run: a process without `NSApplication`, and any XCTest process,
/// where `runModal()` would park the whole suite on a click that never comes
/// (xctest sample 2026-07-19).
@MainActor
struct ModalConnectionFailurePresenter: ConnectionFailurePresenting {
    func present(title: String, message: String, technicalDetails: String?) {
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
        // Show the actionable message first; append the raw system error on a new
        // line when present so a wrong port or NSError code is visible at a glance.
        if let technicalDetails, !technicalDetails.trimmed.isEmpty,
           technicalDetails.trimmed != message.trimmed
        {
            alert.informativeText = "\(message)\n\n\(technicalDetails)"
        } else {
            alert.informativeText = message
        }
        if let appIcon = NSApplication.shared.applicationIconImage.copy() as? NSImage {
            appIcon.size = NSSize(width: 20, height: 20)
            alert.icon = appIcon
        }

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Console")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            openSystemConsole()
        }
    }

    private func openSystemConsole() {
        guard let consoleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            return
        }
        _ = NSWorkspace.shared.open(consoleURL)
    }
}
