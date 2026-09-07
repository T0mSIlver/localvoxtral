import AppKit
import SwiftUI

struct StatusPopoverConnectionFailurePresenter {
    static func detail(statusText: String) -> String? {
        guard isConnectionFailureStatus(statusText) else { return nil }
        return "Check the engine in Settings."
    }

    private static func isConnectionFailureStatus(_ statusText: String) -> Bool {
        switch statusText {
        case "Invalid endpoint URL.",
             "Connection refused.",
             "Host unreachable.",
             "Connection timed out.",
             "Endpoint path rejected.",
             "Dictation stopped after the network disconnected.",
             "Connection failed.":
            return true
        default:
            return false
        }
    }
}

struct StatusPopoverView: View {
    private static let contentWidth: CGFloat = 280

    @Environment(\.openSettings) private var openSettings

    var viewModel: DictationViewModel

    private var hasLatestSegment: Bool {
        !viewModel.lastFinalSegment.trimmed.isEmpty
    }

    private var dictationButtonTitle: String {
        if viewModel.isFinalizingStop {
            return "Finalizing..."
        }
        if viewModel.isConnectingRealtimeSession {
            return "Connecting..."
        }
        return viewModel.isDictating ? "Stop dictation" : "Start dictation"
    }

    private var connectionFailureDetail: String? {
        StatusPopoverConnectionFailurePresenter.detail(statusText: viewModel.statusText)
    }

    var body: some View {
        Group {
            Button(dictationButtonTitle) {
                if !viewModel.isFinalizingStop, !viewModel.isConnectingRealtimeSession {
                    viewModel.toggleDictation()
                }
            }
            .disabled(viewModel.isFinalizingStop || viewModel.isConnectingRealtimeSession)

            Menu("Microphone") {
                if viewModel.availableInputDevices.isEmpty {
                    Text("No input devices")
                } else {
                    ForEach(viewModel.availableInputDevices) { device in
                        Button {
                            viewModel.selectMicrophoneInput(id: device.id)
                        } label: {
                            if viewModel.selectedInputDeviceID == device.id {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                }
            }

            // Above stereo there is no meaningful downmix to mono, so capture
            // takes ONE channel and the user says which (a mic sits on one
            // preamp of a multi-input interface). Hidden for mono/stereo
            // devices, where the standard downmix applies and the choice would
            // be meaningless.
            if viewModel.selectedInputDeviceChannelCount > 2 {
                Menu("Input channel") {
                    ForEach(0..<Int(viewModel.selectedInputDeviceChannelCount), id: \.self) {
                        channel in
                        Button {
                            viewModel.selectMicrophoneInputChannel(channel)
                        } label: {
                            if viewModel.selectedInputChannel == channel {
                                Label("Channel \(channel + 1)", systemImage: "checkmark")
                            } else {
                                Text("Channel \(channel + 1)")
                            }
                        }
                    }
                }
            }

            Button("Copy latest segment") {
                viewModel.copyLatestSegment()
            }
            .disabled(!hasLatestSegment)

            // Polished commits can't be un-typed into the target app; offer the
            // pre-polish raw transcript for one-tap copy instead (F6). Appears
            // only after a polish-changed commit; a one-line action, never the
            // transcript itself (owner rule: no long text in the popover).
            if viewModel.canCopyRawTranscript {
                Button("Copy raw transcript") {
                    viewModel.copyRawTranscript()
                }
            }

            Divider()

            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }

            if !viewModel.isAccessibilityTrusted {
                Button("Enable Accessibility…") {
                    viewModel.requestAccessibilityPermission()
                    openAccessibilitySettings()
                }
            }

            Divider()

            // Prominent, single-source-of-truth "why can't I dictate right now"
            // banner. Surfaces the Live Auto-Paste + Accessibility gap before the
            // user speaks into the void; the affordance to fix it is right below.
            if let warning = viewModel.liveAutoPasteAccessibilityWarning {
                Text(warning)
                    .foregroundStyle(.orange)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.contentWidth, alignment: .leading)
            }

            Text(viewModel.statusText)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.contentWidth, alignment: .leading)

            if let connectionFailureDetail {
                statusDetailView(connectionFailureDetail)
            } else if viewModel.lastError != nil {
                statusDetailView("See Console for details.")
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .onAppear {
            viewModel.refreshMicrophoneInputs()
            viewModel.refreshAccessibilityTrustState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshAccessibilityTrustState()
        }
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    // Same typography as the Status line so failure details read as part of
    // the popover, not a styled callout. The popover never shows long text
    // (AGENTS.md): callers pass one short sentence, and the line limit here
    // is the backstop for any path that slips a long string through.
    private func statusDetailView(_ detail: String) -> some View {
        Text(detail)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: Self.contentWidth, alignment: .leading)
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

}
