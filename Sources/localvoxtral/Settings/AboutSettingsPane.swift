import AppKit
import SwiftUI

struct AboutSettingsPane: View {
    let settings: SettingsStore
    let viewModel: DictationViewModel

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
