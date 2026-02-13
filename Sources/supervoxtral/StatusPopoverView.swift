import AppKit
import SwiftUI

struct StatusPopoverView: View {
    @Environment(\.openSettings) private var openSettings

    @ObservedObject var viewModel: DictationViewModel

    private var hasLatestSegment: Bool {
        !viewModel.lastFinalSegment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            Button(viewModel.isDictating ? "Stop Dictation" : "Start Dictation") {
                viewModel.toggleDictation()
            }

            Menu("Microphone") {
                if viewModel.availableInputDevices.isEmpty {
                    Text("No Input Devices")
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

            Button("Copy Latest Segment") {
                viewModel.copyLatestSegment()
            }
            .disabled(!hasLatestSegment)

            Divider()

            Button("Settings…") {
                NSApp.setActivationPolicy(.regular)
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

            Text("Status: \(viewModel.statusText)")
                .foregroundStyle(.secondary)

            if let lastError = viewModel.lastError {
                Text(lastError)
                    .foregroundStyle(.red)
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
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
