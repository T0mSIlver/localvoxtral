import AppKit
import SwiftUI

/// Makes the Settings window's titlebar transparent and full-size, so the
/// sidebar material runs to the top edge and no window title is drawn over it.
///
/// Applied three times on purpose: when the view is placed in a window, on
/// every `didBecomeKey`, and on every window update that is found with the
/// title back on. SwiftUI re-asserts its own titlebar configuration when it
/// rebuilds the scene's window (observed with the `Settings` scene: close,
/// reopen, and the title reappears), and there is no notification for "SwiftUI
/// just reconfigured you".
///
/// The window update pass is what the first two miss. On macOS 26 (field
/// report on 0.8.5-nightly.20260916.2, reproduced on 26.6.2) SwiftUI puts
/// `titleVisibility` back to `.visible` AFTER the scene's window has been
/// placed and has become key, so "localvoxtral Settings" draws next to the
/// traffic lights over the sidebar and nothing ever takes it down again —
/// neither event fires for an in-window change. `NSWindow.didUpdateNotification`
/// is posted once per event-loop pass over the window, before it draws, which
/// is the one hook that covers a configuration flip nobody announces.
struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class SettingsWindowChromeView: NSView {
    private var observedWindow: NSWindow?

    /// Logged once per view, not per correction: the update pass runs on every
    /// event loop turn, so a line per correction would be a firehose while a
    /// single line still answers "did the titlebar need re-hiding on this
    /// system, and what was the window when it did".
    private var hasLoggedCorrection = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if observedWindow !== window {
            if let observedWindow {
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
            }
        }

        guard let window else { return }
        Self.applyChrome(to: window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func windowDidBecomeKey(_ notification: Notification) {
        guard let window else { return }
        Self.applyChrome(to: window)
    }

    @objc
    private func windowDidUpdate(_ notification: Notification) {
        guard let window, Self.chromeIsStale(window) else { return }
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
    /// wants it. Read on every window update, so it stays a field comparison —
    /// the assignment in `applyChrome` is what costs, not this.
    static func chromeIsStale(_ window: NSWindow) -> Bool {
        window.titleVisibility != .hidden
            || !window.titlebarAppearsTransparent
            || window.titlebarSeparatorStyle != .none
            || !window.styleMask.contains(.fullSizeContentView)
    }

    /// The window title itself is deliberately left alone: `scripts/ui-smoke.sh`
    /// pins every AX probe to the window named "Settings", so hiding the title
    /// is a titlebar setting, never an empty `window.title`.
    static func applyChrome(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
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
