import AppKit
import SwiftUI

@main
struct SuperVoxtralApp: App {
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var viewModel: DictationViewModel

    init() {
        let settings = SettingsStore()
        _settingsStore = StateObject(wrappedValue: settings)
        _viewModel = StateObject(wrappedValue: DictationViewModel(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverView(viewModel: viewModel)
        } label: {
            if let icon = MenuBarIconAsset.icon {
                MenuBarIconView(icon: icon, isDictating: viewModel.isDictating)
            } else {
                Label(
                    "SuperVoxtral",
                    systemImage: viewModel.isDictating ? "waveform.circle.fill" : "waveform.circle"
                )
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settings: settingsStore)
                .frame(minWidth: 420, minHeight: 280)
        }
        .windowResizability(.contentSize)
    }
}

private enum MenuBarIconAsset {
    static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenubarIconTemplate", withExtension: "png"),
              let image = NSImage(contentsOf: url)
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
            .scaledToFit()
            .frame(width: 18, height: 18)
            .overlay(alignment: .topTrailing) {
                if isDictating {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
            }
            .accessibilityLabel("SuperVoxtral")
    }
}
