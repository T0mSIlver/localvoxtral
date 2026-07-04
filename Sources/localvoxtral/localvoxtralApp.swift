import AppKit
import SwiftUI

@main
struct localvoxtralApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverView(viewModel: appDelegate.viewModel)
        } label: {
            let viewModel = appDelegate.viewModel
            let state = viewModel.realtimeSessionIndicatorState
            if let idleIcon = MenuBarIconAsset.idleIcon {
                let iconConfiguration: (
                    icon: NSImage,
                    renderingMode: Image.TemplateRenderingMode,
                    id: String,
                    label: String
                ) = {
                    switch state {
                    case .idle:
                        return (idleIcon, .template, "realtime-idle", "localvoxtral")
                    case .connected:
                        if let connectedIcon = MenuBarIconAsset.connectedIcon {
                            return (
                                connectedIcon,
                                .original,
                                "realtime-connected",
                                "localvoxtral, realtime session active"
                            )
                        }
                        return (
                            idleIcon,
                            .template,
                            "realtime-connected",
                            "localvoxtral, realtime session active"
                        )
                    case .recentFailure:
                        if let failureIcon = MenuBarIconAsset.failureIcon {
                            return (
                                failureIcon,
                                .original,
                                "realtime-failed",
                                "localvoxtral, realtime connection failed recently"
                            )
                        }
                        return (
                            idleIcon,
                            .template,
                            "realtime-failed",
                            "localvoxtral, realtime connection failed recently"
                        )
                    }
                }()

                Image(nsImage: iconConfiguration.icon)
                    .resizable()
                    .renderingMode(iconConfiguration.renderingMode)
                    .scaledToFit()
                    .frame(width: 13, height: 16)
                    .id(iconConfiguration.id)
                    .accessibilityLabel(iconConfiguration.label)
            } else {
                switch state {
                case .idle:
                    Label("localvoxtral", systemImage: "waveform.circle")
                case .connected:
                    Label("localvoxtral", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .recentFailure:
                    Label("localvoxtral", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                settings: appDelegate.settingsStore,
                viewModel: appDelegate.viewModel,
                backendManager: appDelegate.backendManager,
                navigator: appDelegate.settingsNavigator
            )
            .frame(minWidth: 560, idealWidth: 580, minHeight: 380, idealHeight: 420)
        }
        .defaultSize(width: 580, height: 420)
        .restorationBehavior(.disabled)
    }
}

/// Owns the shared model graph and presents the first-launch onboarding wizard.
/// A menu-bar (LSUIElement) app has no launch window scene, so the wizard is
/// shown here from `applicationDidFinishLaunching`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore: SettingsStore
    let backendManager: BackendManager
    let viewModel: DictationViewModel
    let settingsNavigator = SettingsNavigator()

    private var onboardingController: OnboardingWindowController?

    override init() {
        let settings = SettingsStore()
        let manager = BackendManager()
        settingsStore = settings
        backendManager = manager
        viewModel = DictationViewModel(settings: settings, backendManager: manager)
        super.init()
        viewModel.onRequestReRunOnboarding = { [weak self] in
            self?.presentOnboarding()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !settingsStore.onboardingCompleted else { return }
        presentOnboarding()
    }

    private func presentOnboarding() {
        if let onboardingController {
            onboardingController.present()
            return
        }
        let controller = OnboardingWindowController(
            settings: settingsStore,
            viewModel: viewModel,
            backendManager: backendManager,
            openEndpointsSettings: { [weak self] in self?.openEndpointsSettings() }
        )
        controller.onFinished = { [weak self] in self?.onboardingController = nil }
        onboardingController = controller
        controller.present()
    }

    private func openEndpointsSettings() {
        settingsNavigator.selectedTab = .endpoints
        NSApp.activate(ignoringOtherApps: true)
        // AppKit entry point for the SwiftUI `Settings` scene on macOS 14+.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

@MainActor
private enum MenuBarIconAsset {
    static let idleIcon: NSImage? = loadIcon(candidates: [
        "MicIconTemplate@2x",
        "MicIconTemplate",
    ], asTemplate: true)

    static let connectedIcon: NSImage? = loadIcon(candidates: [
        "MicIconTemplate_connected",
        "MicIconTemplate@2x_connected",
    ], asTemplate: false)

    static let failureIcon: NSImage? = loadIcon(candidates: [
        "MicIconTemplate_failure",
        "MicIconTemplate@2x_failure",
    ], asTemplate: false)

    private static func loadIcon(candidates: [String], asTemplate: Bool) -> NSImage? {
        let bundle = Bundle.main
        for candidate in candidates {
            guard let iconURL = bundle.url(forResource: candidate, withExtension: "png"),
                  let image = NSImage(contentsOf: iconURL)
            else {
                continue
            }
            // Plain `@2x` filenames are already point-size normalized by AppKit.
            // Custom-suffixed variants (for example `@2x_connected`) are not.
            if candidate.contains("@2x"), !candidate.hasSuffix("@2x") {
                image.size = NSSize(width: image.size.width / 2.0, height: image.size.height / 2.0)
            }
            image.isTemplate = asTemplate
            return image
        }
        return nil
    }
}
