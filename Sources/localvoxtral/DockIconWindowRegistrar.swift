import AppKit
import SwiftUI

/// Keeps the host window registered with `DockIconPolicy` for as long as it is
/// on screen. Place it in the background of a SwiftUI scene that should put
/// the app in the Dock.
///
/// A zero-sized `NSViewRepresentable` is the only handle SwiftUI offers on the
/// `NSWindow` behind a scene — the same technique `SettingsWindowChrome` uses
/// on the same window for its titlebar.
struct DockIconWindowRegistrar: NSViewRepresentable {
    let policy: DockIconPolicy

    func makeNSView(context: Context) -> NSView {
        DockIconWindowRegistrarView(policy: policy)
    }

    /// SwiftUI runs this on every content update of the scene, which is the
    /// cheapest catch-all for a window that came back on screen without any of
    /// the observed notifications.
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DockIconWindowRegistrarView)?.refreshRegistration()
    }
}

/// Registration follows whether the window is ON SCREEN, which is not the same
/// as `isVisible`: a minimized window still belongs in the Dock, and a hidden
/// regular app keeps its tile, so `isMiniaturized` counts as on screen too.
///
/// The view stays attached to its window across a close/reopen — SwiftUI keeps
/// the scene's window and content view and merely orders it out — so
/// `viewDidMoveToWindow` fires ONCE and cannot be what drives registration.
/// Reopening Settings a second time left the app without a Dock icon until the
/// observations below covered it (hand-check on the PR #362 build, macOS 26).
final class DockIconWindowRegistrarView: NSView {
    private let policy: DockIconPolicy
    /// The window this view observes, held for as long as the view is in it —
    /// separately from whether that window is currently registered, which is
    /// what closing and reopening toggles.
    private weak var observedWindow: NSWindow?
    private var isRegistered = false

    init(policy: DockIconPolicy) {
        self.policy = policy
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Teardown happens on the way OUT, while the window still exists — AppKit
    /// calls this before detaching the view, and `deinit` on a `@MainActor`
    /// class cannot reach the policy.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== observedWindow { stopObserving() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== observedWindow else {
            refreshRegistration()
            return
        }
        stopObserving()
        observedWindow = window
        for name: NSNotification.Name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didUpdateNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowStateChanged(_:)),
                name: name,
                object: window
            )
        }
        // Closing is the one transition that cannot be read off the window:
        // `willClose` arrives while it is still visible.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        refreshRegistration()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func windowStateChanged(_ notification: Notification) {
        refreshRegistration()
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        setRegistered(false)
    }

    func refreshRegistration() {
        guard let observedWindow else { return }
        setRegistered(Self.isOnScreen(observedWindow))
    }

    /// A minimized window is not `isVisible`, but it still has a Dock tile and
    /// the app it belongs to still belongs in the Dock.
    static func isOnScreen(_ window: NSWindow) -> Bool {
        window.isVisible || window.isMiniaturized
    }

    private func setRegistered(_ registered: Bool) {
        guard let observedWindow, registered != isRegistered else { return }
        isRegistered = registered
        if registered {
            policy.addWindow(ObjectIdentifier(observedWindow))
        } else {
            policy.removeWindow(ObjectIdentifier(observedWindow))
        }
    }

    private func stopObserving() {
        setRegistered(false)
        guard let observedWindow else { return }
        NotificationCenter.default.removeObserver(self, name: nil, object: observedWindow)
        self.observedWindow = nil
    }
}
