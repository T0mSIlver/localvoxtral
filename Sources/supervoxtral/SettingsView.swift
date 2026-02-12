import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("SuperVoxtral Settings")
                    .font(.title3)
                    .fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 10) {
                    SettingsField(title: "Realtime endpoint") {
                        TextField("ws://127.0.0.1:8000/v1/realtime", text: $settings.endpointURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    SettingsField(title: "Model name") {
                        TextField("voxtral-mini-latest", text: $settings.modelName)
                            .textFieldStyle(.roundedBorder)
                    }

                    SettingsField(title: "API key (optional for local vLLM)") {
                        SecureField("Optional", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Commit interval")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(String(format: "%.2fs", settings.commitIntervalSeconds))
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $settings.commitIntervalSeconds, in: 0.25 ... 2.5, step: 0.05)
                }

                Toggle("Auto-copy transcript when segment finalizes", isOn: $settings.autoCopyEnabled)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tips")
                        .font(.system(size: 12, weight: .medium))

                    Text("Use a local vLLM realtime endpoint like `ws://127.0.0.1:8000/v1/realtime`.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text("For command+V auto-paste, macOS may ask for Accessibility permission.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.isVisible && $0.canBecomeKey }?
                    .makeKeyAndOrderFront(nil)
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct SettingsField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            content
        }
    }
}
