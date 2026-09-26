import AppKit
import SwiftUI

/// Makes the Settings window's titlebar transparent and full-size, so the
/// sidebar material runs to the top edge and no window title is drawn over it.
///
/// The chrome is not set once and left alone: SwiftUI re-asserts its own
/// titlebar configuration behind the app's back, and there is no notification
/// for "SwiftUI just reconfigured you". Two of those re-assertions are known:
///
///  * When it rebuilds the scene's window — close the Settings window, reopen
///    it, and the title is back. `viewDidMoveToWindow` and `didBecomeKey`
///    cover that one.
///  * On macOS 26, whenever it updates the window's content. Field report on
///    0.8.5-nightly.20260916.2, reproduced on 26.6.2: opening Settings and
///    switching an Engines mode each put `titleVisibility` back to `.visible`,
///    so "localvoxtral Settings" drew next to the traffic lights, over the
///    sidebar. The logged state at the moment of correction was
///    `titleVisible=true transparent=true fullSize=true toolbar=false`: the
///    transparent full-size titlebar this view set had survived, only the
///    title had been turned back on, and no toolbar was involved.
///
/// The second one has no event of its own, and the flip can land after the
/// last window update of the turn — the app then sits idle with the title on
/// screen until something else wakes it, which is what the owner saw. So the
/// hook that has to catch it is KVO on `titleVisibility`, which runs
/// synchronously with whoever set it. `NSWindow.didUpdateNotification` stays
/// as a backstop for a re-assertion that reaches the property without going
/// through the setter.
struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowChromeView()
    }

    /// SwiftUI calls this on every view-graph update of the Settings content,
    /// which is the same work that re-asserts the titlebar. Cheap, and it
    /// closes the gap if a system ever reconfigures the window before the
    /// observations below are installed.
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SettingsWindowChromeView)?.correctChromeIfStale()
    }
}

final class SettingsWindowChromeView: NSView {
    /// The app's one window is named after the app, not after the Settings
    /// scene that hosts it: History and Insights live in it too (owner
    /// decision, 2026-09-22). The scene's own default is "localvoxtral
    /// Settings" (the field report above), so the title is corrected here
    /// with the rest of the chrome rather than trusted to a SwiftUI modifier.
    /// `scripts/ui-smoke.sh` and `scripts/capture-readme-assets.sh` address
    /// the window by this string (`SETTINGS_WINDOW_TITLE`), and
    /// `SettingsTabTests` holds them equal.
    static let windowTitle = "localvoxtral"

    private var observedWindow: NSWindow?
    private var titleVisibilityObservation: NSKeyValueObservation?

    /// Logged once per view, not per correction: SwiftUI re-asserts the title
    /// on every content update, so a line per correction would be a firehose
    /// while a single line still answers "did this system put the titlebar
    /// back, and what did the window look like when it did".
    private var hasLoggedCorrection = false
    private var isApplyingChrome = false

    /// Teardown happens on the way OUT, not on the way in. A KVO registration
    /// that outlives its window takes the process down with it ("deallocated
    /// while key value observers were still registered"), and this is the hook
    /// AppKit calls while the window is still alive — including when the window
    /// itself is going away and lets go of its content view.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== observedWindow {
            stopObserving()
            observedWindow = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if observedWindow !== window {
            stopObserving()
            observedWindow = window
            if let window {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidBecomeKey(_:)),
                    name: NSWindow.didBecomeKeyNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidUpdate(_:)),
                    name: NSWindow.didUpdateNotification,
                    object: window
                )
                // The correction re-enters this handler (it writes the very
                // property being observed) and stops there, because by then
                // the chrome is no longer stale.
                titleVisibilityObservation = window.observe(
                    \.titleVisibility,
                    options: [.new]
                ) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.correctChromeIfStale() }
                }
            }
        }

        guard let window else { return }
        Self.applyChrome(to: window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func stopObserving() {
        titleVisibilityObservation?.invalidate()
        titleVisibilityObservation = nil
        guard let observedWindow else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didUpdateNotification,
            object: observedWindow
        )
    }

    @objc
    private func windowDidBecomeKey(_ notification: Notification) {
        guard let window else { return }
        Self.applyChrome(to: window)
    }

    @objc
    private func windowDidUpdate(_ notification: Notification) {
        correctChromeIfStale()
    }

    func correctChromeIfStale() {
        // KVO on `titleVisibility` fires for every call to the setter, value
        // change or not, so a correction that writes it re-enters here while
        // the rest of the chrome is still half-applied and calls itself until
        // the stack runs out (SIGSEGV in the suite before this guard existed).
        guard !isApplyingChrome else { return }
        guard let window, Self.chromeIsStale(window) else { return }
        isApplyingChrome = true
        defer { isApplyingChrome = false }
        if !hasLoggedCorrection {
            hasLoggedCorrection = true
            let state = "titleVisible=\(window.titleVisibility != .hidden)"
                + " transparent=\(window.titlebarAppearsTransparent)"
                + " fullSize=\(window.styleMask.contains(.fullSizeContentView))"
                + " toolbar=\(window.toolbar != nil)"
            Log.diagnostics.notice(
                "Settings titlebar was reconfigured after setup; re-applying chrome (\(state, privacy: .public))."
            )
        }
        Self.applyChrome(to: window)
    }

    /// True when anything this view owns has been put back the way SwiftUI
    /// wants it. Read on every window update and on every write to
    /// `titleVisibility`, so it stays a field comparison — the assignments in
    /// `applyChrome` are what cost, not this.
    private static func chromeIsStale(_ window: NSWindow) -> Bool {
        window.title != windowTitle
            || window.titleVisibility != .hidden
            || !window.titlebarAppearsTransparent
            || window.titlebarSeparatorStyle != .none
            || !window.styleMask.contains(.fullSizeContentView)
    }

    /// Hiding the title is a titlebar setting, never an empty `window.title`:
    /// the AX drills find the window by `windowTitle`.
    ///
    /// Each setting is written only when it is wrong. A window property
    /// notifies its observers whether or not the value changed, and this runs
    /// on every window update pass.
    private static func applyChrome(to window: NSWindow) {
        if window.title != windowTitle { window.title = windowTitle }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

extension View {
    /// Turns off macOS 26's top scroll-edge effect on a Settings scroll view.
    ///
    /// On macOS 26 a scroll view under the titlebar can get an edge effect
    /// that draws a bar across the titlebar, over the full-size content —
    /// exactly the strip this window must not have. Earlier systems have no
    /// such effect. Paired with the scene's hidden titlebar style.
    @ViewBuilder
    func settingsScrollEdgeEffectHidden() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
