import AppKit
import SwiftUI

@main
struct SuperVoxtralApp: App {
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
                    "SuperVoxtral",
                    systemImage: viewModel.isDictating ? "waveform.circle.fill" : "waveform.circle"
                )
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settings: settingsStore)
                .frame(minWidth: 332, minHeight: 430)
        }
        .windowResizability(.automatic)
    }
}

private enum MenuBarIconAsset {
    static let icon: NSImage? = {
        let bundle = Bundle.main
        for name in ["MicIconTemplate", "MenubarIconTemplate"] {
            if let image = bundle.image(forResource: NSImage.Name(name))
                ?? imageFromURL(in: bundle, name: name, ext: "pdf")
                ?? imageFromURL(in: bundle, name: name, ext: "png") {
                image.isTemplate = true
                return image
            }
        }

        return nil
    }()

    private static func imageFromURL(in bundle: Bundle, name: String, ext: String) -> NSImage? {
        guard let iconURL = bundle.url(forResource: name, withExtension: ext) else {
            return nil
        }
        return NSImage(contentsOf: iconURL)
    }
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
            .accessibilityLabel("SuperVoxtral")
    }
}
