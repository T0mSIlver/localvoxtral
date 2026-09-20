import AppKit
import SwiftUI

/// Keeps the host window registered with `DockIconPolicy` for as long as it is
/// open. Place it in the background of a SwiftUI scene that should put the app
/// in the Dock.
///
/// A zero-sized `NSViewRepresentable` is the only handle SwiftUI offers on the
/// `NSWindow` behind a scene — the same technique `SettingsWindowChrome` uses
/// on the same window for its titlebar.
struct DockIconWindowRegistrar: NSViewRepresentable {
    let policy: DockIconPolicy

    func makeNSView(context: Context) -> NSView {
        DockIconWindowRegistrarView(policy: policy)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class DockIconWindowRegistrarView: NSView {
    private let policy: DockIconPolicy
    private weak var registeredWindow: NSWindow?

    init(policy: DockIconPolicy) {
        self.policy = policy
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Deregistration happens on the way OUT, while the window is still
    /// around — AppKit calls this before detaching the view, and `deinit` on a
    /// `@MainActor` class cannot reach the policy.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== registeredWindow { unregister() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== registeredWindow else { return }
        unregister()
        registeredWindow = window
        // Closing a SwiftUI scene's window does not always tear its content
        // view down, so the close notification — not view teardown — is what
        // reliably marks the end of the window.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        policy.addWindow(ObjectIdentifier(window))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        unregister()
    }

    private func unregister() {
        guard let registeredWindow else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: registeredWindow
        )
        policy.removeWindow(ObjectIdentifier(registeredWindow))
        self.registeredWindow = nil
    }
}
