// The app the e2e dictation lane dictates INTO (scripts/e2e-dictation.sh).
//
// A throwaway target rather than TextEdit, for two reasons. Ending a run means
// killing the target, and killing TextEdit can take the owner's unsaved
// documents with it. And reading another app's text needs an Automation or
// Accessibility read from the runner, while this app simply writes what it
// holds to a file.
//
//   e2e-target <output-dir>
//
// Every 200 ms it writes, when changed:
//   <output-dir>/text    the text view's contents
//   <output-dir>/state   "active=<0|1> key=<0|1> focused=<0|1>"
// The runner refuses to start a dictation until all three are 1: text the app
// under test inserts goes to whatever is focused, and a run that dictated into
// the owner's editor must not be scored as a regression, or happen at all.
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let textURL: URL
    private let stateURL: URL
    private var window: NSWindow?
    private var textView: NSTextView?
    private var lastText: String?
    private var lastState: String?
    private var timer: Timer?

    init(outputDirectory: URL) {
        textURL = outputDirectory.appendingPathComponent("text")
        stateURL = outputDirectory.appendingPathComponent("state")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "localvoxtral e2e target"

        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { exit(3) }
        // Anything that rewrites inserted text would be scored as the app's doing.
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        window.contentView = scrollView
        window.center()

        self.window = window
        self.textView = textView

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)

        publish()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func publish() {
        guard let window, let textView else { return }
        let text = textView.string
        if text != lastText {
            lastText = text
            try? text.write(to: textURL, atomically: true, encoding: .utf8)
        }
        let focused = window.firstResponder === textView
        let state = "active=\(NSApp.isActive ? 1 : 0) key=\(window.isKeyWindow ? 1 : 0) focused=\(focused ? 1 : 0)\n"
        if state != lastState {
            lastState = state
            try? state.write(to: stateURL, atomically: true, encoding: .utf8)
        }
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: e2e-target <output-dir>\n".utf8))
    exit(2)
}

let delegate = AppDelegate(
    outputDirectory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
let app = NSApplication.shared
app.delegate = delegate
app.run()
