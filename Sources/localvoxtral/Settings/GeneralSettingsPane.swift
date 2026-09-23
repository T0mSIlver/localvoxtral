import AppKit
import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel
    let loginItem: LoginItemController

    /// Writes through to the system registration, and reads back from it: the
    /// switch follows what macOS ended up doing, not what was asked for.
    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItem.isOn },
            set: { loginItem.setOn($0) }
        )
    }

    var body: some View {
        SettingsPage(tab: .general) {
            SettingsGroup(title: "Permissions") {
                // Wrapped rather than given the row insets itself: this view is
                // shared verbatim with the onboarding wizard.
                SettingsGroupRow {
                    PermissionRowsView(viewModel: viewModel)
                }
            }

            SettingsGroup(title: "App") {
                SettingsFieldRow(
                    title: "Open localvoxtral at login",
                    status: loginItem.statusMessage,
                    statusAccessibilityIdentifier: "settings.general.loginItemStatus"
                ) {
                    Toggle("", isOn: loginItemBinding)
                        .labelsHidden()
                        .disabled(!loginItem.isAvailable)
                        .accessibilityIdentifier("settings.general.loginItem")
                }

                SettingsFieldRow(
                    title: "Open the window at launch",
                    help: "It opens on History."
                ) {
                    Toggle("", isOn: $settings.opensWindowAtLaunch)
                        .labelsHidden()
                        .accessibilityIdentifier("settings.general.openWindowAtLaunch")
                }

                SettingsFieldRow(
                    title: "Setup wizard"
                ) {
                    Button("Re-run setup…") {
                        viewModel.reRunOnboarding()
                    }
                }
            }
        }
        // System Settings can turn the login item off while the app runs, so
        // the switch is re-read from the system every time the pane appears —
        // and again when the app comes back to the front, which is how the
        // user returns from turning it off over there.
        .onAppear { loginItem.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            loginItem.refresh()
        }
    }
}
