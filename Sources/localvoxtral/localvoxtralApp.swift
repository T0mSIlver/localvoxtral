import AppKit
import SwiftUI

@main
struct localvoxtralApp: App {
    @State private var settingsStore: SettingsStore
    @State private var viewModel: DictationViewModel

    init() {
        let settings = SettingsStore()
        settingsStore = settings
        viewModel = DictationViewModel(settings: settings)
    }

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverView(viewModel: viewModel)
        } label: {
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
            SettingsView(settings: settingsStore, viewModel: viewModel)
                .frame(minWidth: 336, idealWidth: 360, maxWidth: 520)
        }
        .defaultSize(width: 360, height: 760)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
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
