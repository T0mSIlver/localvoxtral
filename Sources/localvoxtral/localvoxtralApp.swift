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
            if let icon = MenuBarIconAsset.icon {
                MenuBarIconView(icon: icon, isDictating: viewModel.isDictating)
            } else {
                Label(
                    "localvoxtral",
                    systemImage: viewModel.isDictating ? "waveform.circle.fill" : "waveform.circle"
                )
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settings: settingsStore)
                .frame(minWidth: 336, idealWidth: 360, maxWidth: 520, minHeight: 470, idealHeight: 520, maxHeight: 960)
        }
        .defaultSize(width: 360, height: 520)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
    }
}

@MainActor
private enum MenuBarIconAsset {
    static let icon: NSImage? = {
        let bundle = Bundle.main
        guard let iconURL = bundle.url(forResource: "MicIconTemplate", withExtension: "png"),
              let image = NSImage(contentsOf: iconURL)
        else {
            return nil
        }
        image.isTemplate = true
        return image
    }()
}

private struct MenuBarIconView: View {
    let icon: NSImage
    let isDictating: Bool

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 13, height: 16)
            .overlay(alignment: .topTrailing) {
                if isDictating {
                    Circle()
                        .fill(.red)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -2)
                }
            }
            .accessibilityLabel("localvoxtral")
    }
}
