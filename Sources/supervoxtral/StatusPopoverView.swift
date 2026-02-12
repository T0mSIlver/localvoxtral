import AppKit
import SwiftUI

struct StatusPopoverView: View {
    @Environment(\.openSettings) private var openSettings

    @ObservedObject var viewModel: DictationViewModel
    @ObservedObject var settings: SettingsStore

    private var hasTranscript: Bool {
        !viewModel.fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasLatestSegment: Bool {
        !viewModel.lastFinalSegment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Button(viewModel.isDictating ? "Stop Dictation" : "Start Dictation") {
            viewModel.toggleDictation()
        }

        Button("Copy Transcript") {
            viewModel.copyTranscript()
        }
        .disabled(!hasTranscript)

        Button("Paste Latest Segment") {
            viewModel.pasteLatestSegment()
        }
        .disabled(!hasLatestSegment)

        Button("Clear Transcript") {
            viewModel.clearTranscript()
        }
        .disabled(!hasTranscript)

        Divider()

        Button("Settings…") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Divider()

        Text("Status: \(viewModel.statusText)")
            .foregroundStyle(.secondary)

        Text("Model: \(settings.modelName)")
            .foregroundStyle(.secondary)

        if let lastError = viewModel.lastError {
            Text(lastError)
                .foregroundStyle(.red)
        }

        Divider()

        Button("Quit SuperVoxtral") {
            NSApplication.shared.terminate(nil)
        }
    }
}
