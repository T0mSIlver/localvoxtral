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
            StatusPopoverView(viewModel: viewModel, settings: settingsStore)
        } label: {
            Label(
                "SuperVoxtral",
                systemImage: viewModel.isDictating ? "waveform.circle.fill" : "waveform.circle"
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settings: settingsStore)
                .frame(minWidth: 520, minHeight: 430)
        }
        .windowResizability(.contentSize)
    }
}
