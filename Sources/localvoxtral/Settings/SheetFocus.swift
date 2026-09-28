import AppKit
import SwiftUI

extension View {
    /// Opens a sheet with nothing focused. AppKit hands a new sheet's first
    /// key view the focus, so its first link ("Learn more", "Details") drew
    /// a focus ring before the user touched the keyboard. Tab still walks
    /// the key view loop from its start; focus rings stay on.
    func opensWithNothingFocused() -> some View {
        background(NothingFocusedOnOpen())
    }
}

private struct NothingFocusedOnOpen: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        private var observer: (any NSObjectProtocol)?
        private var cleared = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !cleared, observer == nil else { return }
            window.initialFirstResponder = nil
            if window.isKeyWindow {
                clear()
                return
            }
            // A sheet becomes key after its content is in it, and picks its
            // first key view then: clear the focus once that has happened.
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.clear() }
            }
        }

        private func clear() {
            cleared = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            // After AppKit's own pick, which runs in the same turn.
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(nil)
            }
        }
    }
}
