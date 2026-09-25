import AppKit
import SwiftUI

struct AboutSettingsPane: View {
    let settings: SettingsStore
    let viewModel: DictationViewModel

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "localvoxtral"
    }

    /// Shows the in-memory value the capture pipeline actually consults
    /// (DictationSessionController+DogfoodCapture), not a live defaults read — a
    /// `defaults write` while the app runs takes effect on relaunch, and the
    /// row must describe what THIS process is doing.
    private var dogfoodCaptureArmed: Bool {
        #if LOCALVOXTRAL_DOGFOOD
        settings.dogfoodCaptureEnabled
        #else
        false
        #endif
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

                // Constant row, variant-dependent content: "which binary am I
                // running" is exactly the question that has cost field-debug
                // time before (docs/agent/field-debugging.md), and version
                // alone can't answer it —
                // dogfood builds keep the same version and bundle id.
                SettingsFieldRow(title: "Build") {
                    Text(
                        DogfoodBuildStatus.label(
                            isDogfoodBuild: DogfoodBuildStatus.isDogfoodBuild,
                            captureArmed: dogfoodCaptureArmed
                        )
                    )
                    .foregroundStyle(DogfoodBuildStatus.isDogfoodBuild ? Color.orange : Color.primary)
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
