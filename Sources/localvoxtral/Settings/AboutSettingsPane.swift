import AppKit
import SwiftUI

struct AboutSettingsPane: View {
    let settings: SettingsStore
    let viewModel: DictationViewModel
    @Bindable private var updates: AppUpdateModel

    init(settings: SettingsStore, viewModel: DictationViewModel) {
        self.settings = settings
        self.viewModel = viewModel
        self.updates = viewModel.updates
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "localvoxtral"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "dev"
    }

    var body: some View {
        SettingsPage(tab: .about) {
            SettingsGroup(title: "Application") {
                SettingsFieldRow(title: "Name") {
                    Text(appName)
                }

                SettingsFieldRow(title: "Version") {
                    Text("\(appVersion) (build \(appBuild))")
                }

                if updates.isAvailable {
                    SettingsFieldRow(title: "Install updates automatically") {
                        Toggle("", isOn: $updates.installsAutomatically)
                            .labelsHidden()
                            .accessibilityIdentifier("settings.about.installUpdatesAutomatically")
                    }

                    SettingsFieldRow(title: "Updates") {
                        Button("Check for Updates…") {
                            updates.checkForUpdates()
                        }
                        .accessibilityIdentifier("settings.about.checkForUpdates")
                    }
                }

                SettingsFieldRow(title: "Project") {
                    Link(
                        "github.com/T0mSIlver/localvoxtral",
                        destination: URL(string: "https://github.com/T0mSIlver/localvoxtral")!
                    )
                }

                SettingsFieldRow(title: "Issues") {
                    Link(
                        "Report an Issue",
                        destination: URL(string: "https://github.com/T0mSIlver/localvoxtral/issues")!
                    )
                }
            }

            SettingsGroup(title: "Diagnostics") {
                SettingsFieldRow(title: "Report") {
                    Button("Export diagnostics…") {
                        viewModel.engines.exportDiagnostics()
                    }
                }
            }
        }
    }
}
