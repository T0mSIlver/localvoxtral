import AppKit

/// Shows a Dock icon while the app has a window worth switching back to, and
/// takes it away again when the last one closes.
///
/// `LSUIElement` in the Info.plist is only the LAUNCH state: at runtime
/// `NSApplication.setActivationPolicy` moves the process between `.accessory`
/// (menu bar only) and `.regular` (Dock tile, app switcher, main menu). The
/// windows that earn a tile are the ones the user expects to find again
/// without going back through the menu bar — Settings and the onboarding
/// wizard. The dictation overlay does not: it is a borderless non-activating
/// panel whose whole job is to stay out of the way of focus.
///
/// Windows register themselves rather than having this type scan
/// `NSApp.windows`: SwiftUI's `Settings` scene exposes no open/close callback,
/// so a scan would have to match on the window title — and the window title is
/// already load-bearing for `scripts/ui-smoke.sh` and the AX gate, which pin
/// their probes to the window named "Settings". Registration keeps the two
/// apart.
///
/// A window counts while it is ON SCREEN, which `DockIconWindowRegistrar`
/// defines — minimized and app-hidden windows included, because both still
/// belong in the Dock.
///
/// Every AppKit call goes through `apply`, so the decision runs in tests
/// without an `NSApplication`.
@MainActor
final class DockIconPolicy {
    private var openWindows: Set<ObjectIdentifier> = []
    private var appliedPolicy: NSApplication.ActivationPolicy
    /// Returns whether the process actually took the policy. A refusal leaves
    /// this object's belief untouched, so the next window registration tries
    /// again instead of skipping the call as redundant.
    private let apply: @MainActor (NSApplication.ActivationPolicy) -> Bool

    /// - Parameter initialPolicy: what the process already is, so the first
    ///   window that opens is the first thing that calls `apply`. A menu-bar
    ///   app launches `.accessory`.
    init(
        initialPolicy: NSApplication.ActivationPolicy = .accessory,
        apply: @escaping @MainActor (NSApplication.ActivationPolicy) -> Bool
    ) {
        appliedPolicy = initialPolicy
        self.apply = apply
    }

    /// The policy the process last accepted.
    var currentPolicy: NSApplication.ActivationPolicy { appliedPolicy }

    /// Registering the same window twice is a no-op, so a view that is moved
    /// between windows and back cannot leave a phantom tile behind.
    func addWindow(_ window: ObjectIdentifier) {
        openWindows.insert(window)
        applyIfChanged()
    }

    func removeWindow(_ window: ObjectIdentifier) {
        openWindows.remove(window)
        applyIfChanged()
    }

    private func applyIfChanged() {
        let desired: NSApplication.ActivationPolicy =
            openWindows.isEmpty ? .accessory : .regular
        guard desired != appliedPolicy else { return }
        guard apply(desired) else { return }
        appliedPolicy = desired
    }
}
