import AppKit
import SwiftUI

/// Makes the Settings window's titlebar transparent and full-size, so the
/// sidebar material runs to the top edge.
///
/// Applied twice on purpose: once when the view is placed in a window, and again
/// on every `didBecomeKey`. SwiftUI re-asserts its own titlebar configuration
/// when it rebuilds the scene's window (observed with the `Settings` scene:
/// close, reopen, and the title reappears), and there is no notification for
/// "SwiftUI just reconfigured you" — becoming key is the reliable moment we get.
struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SettingsWindowChromeView: NSView {
    private var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if observedWindow !== window {
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didBecomeKeyNotification,
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

    private static func applyChrome(to window: NSWindow) {
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
