import SwiftUI

/// The local agents-panel row offer for federated herdr clients.
///
/// A 0.9 client renders its agents panel from this Mac's herdr config, not
/// from an enrolled host's config. This row appears only when the live
/// machine catalog has an enabled machine, stays inside the existing Remote
/// hosts group, and never renders generated TOML: consent names the file in
/// one sentence, with Details pointing at the docs.
struct ClaudeHerdrLocalPanelSettingsRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    @State private var isShowingSetup = false

    private static let documentationURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/remote-claude-context.md#federated-herdr-machines"
    )!

    var body: some View {
        if model.hasEnabledHerdrMachine {
            SettingsFieldRow(
                title: "Federated herdr panel row",
                help: "Adds the mic-indicator row to this Mac's herdr config.",
                status: model.localHerdrPanelResult,
                statusAccessibilityIdentifier: "integrations.claude.localHerdrPanel.status"
            ) {
                Button("Set up…") {
                    model.requestLocalHerdrPanelConfiguration()
                    isShowingSetup = model.enrollmentConfirmation?.action == .configureLocalHerdrPanel
                }
                .controlSize(.small)
                .disabled(model.isEnrollmentBusy)
                .accessibilityIdentifier("integrations.claude.localHerdrPanel.setUp")
            }
            .sheet(isPresented: $isShowingSetup) {
                ClaudeLocalHerdrPanelSetupSheet(model: model) { isShowingSetup = false }
            }
        }
    }
}

/// Consent for the local herdr config edit.
private struct ClaudeLocalHerdrPanelSetupSheet: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    var dismiss: () -> Void

    private static let documentationURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/remote-claude-context.md#federated-herdr-machines"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Federated herdr panel row")
                .font(.headline)
                .accessibilityIdentifier("integrations.claude.localHerdrPanelSheet.title")
            if let confirmation = model.enrollmentConfirmation,
               confirmation.action == .configureLocalHerdrPanel {
                Text(confirmation.title)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Details", destination: Self.documentationURL)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        model.cancelEnrollmentActionConfirmation()
                        dismiss()
                    }
                    .accessibilityIdentifier("integrations.claude.localHerdrPanelSheet.cancel")
                    Button(confirmation.confirmButtonTitle) {
                        Task {
                            await model.confirmEnrollmentAction()
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isEnrollmentBusy)
                    .accessibilityIdentifier("integrations.claude.localHerdrPanelSheet.apply")
                }
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
