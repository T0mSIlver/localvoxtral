import AppKit
import SwiftUI

/// Hosts the onboarding wizard in a dedicated titled window and wires the flow's
/// terminal actions back to AppKit. For a menu-bar (LSUIElement) app there is no
/// launch window scene, so the wizard is presented programmatically and the app
/// is activated so it is visible.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model: OnboardingViewModel
    private var window: NSWindow?

    /// Invoked once the wizard window has closed (for any reason).
    var onFinished: (() -> Void)?

    init(
        settings: SettingsStore,
        viewModel: DictationViewModel,
        backendManager: any ManagedBackendManaging,
        openEndpointsSettings: @escaping () -> Void
    ) {
        let driver = LiveOnboardingBootstrapDriver(backendManager: backendManager)
        model = OnboardingViewModel(settings: settings, viewModel: viewModel, driver: driver)
        super.init()
        model.onRequestClose = { [weak self] in self?.closeWindow() }
        model.onOpenEndpointsSettings = openEndpointsSettings
    }

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: OnboardingWizardView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Welcome to localvoxtral"
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The hosting view reports its fixed 540x480 only after a layout pass;
        // centering before it means the frame grows off-center afterwards.
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeWindow() {
        // `close()` posts `windowWillClose` (where completion + teardown happen)
        // without routing through `windowShouldClose`, so programmatic dismissal
        // is unconditional.
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Any dismissal — including the title-bar close button — completes
        // onboarding (closing counts as "skip"); the user can re-run it from
        // Settings ▸ General.
        model.completeOnboarding()
        window?.delegate = nil
        window = nil
        onFinished?()
    }
}
