import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                SettingsField(title: "Realtime endpoint") {
                    TextField("ws://127.0.0.1:8000/v1/realtime", text: $settings.endpointURL)
                        .textFieldStyle(.roundedBorder)
                }

                SettingsField(title: "Model") {
                    TextField("voxtral-mini-latest", text: $settings.modelName)
                        .textFieldStyle(.roundedBorder)
                }

                SettingsField(title: "API key") {
                    SecureField("", text: $settings.apiKey)
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

                Slider(value: $settings.commitIntervalSeconds, in: 0.1 ... 1.0, step: 0.1)

                Text("How often finalized transcript chunks are requested from the realtime server.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Toggle("Auto-copy latest segment when finalized", isOn: $settings.autoCopyEnabled)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            content
        }
    }
}
