import AppKit
import SwiftUI

struct StatusPopoverConnectionFailurePresenter {
    static func detail(statusText: String, lastError: String?, endpoint: String) -> String? {
        guard isConnectionFailureStatus(statusText) else { return nil }
        if statusText != "Invalid endpoint URL.",
           lastError?.contains(endpoint) != true
        {
            return nil
        }
        return "Endpoint: \(endpoint)"
    }

    private static func isConnectionFailureStatus(_ statusText: String) -> Bool {
        switch statusText {
        case "Invalid endpoint URL.",
             "Connection refused.",
             "Host unreachable.",
             "Connection timed out.",
             "Endpoint path rejected.",
             "Network lost. Dictation stopped.",
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
        return viewModel.isDictating ? "Stop Dictation" : "Start Dictation"
    }

    private var connectionFailureDetail: String? {
        StatusPopoverConnectionFailurePresenter.detail(
            statusText: viewModel.statusText,
            lastError: viewModel.lastError,
            endpoint: sanitizedRealtimeEndpointDescription
        )
    }

    private var sanitizedRealtimeEndpointDescription: String {
        guard let endpoint = viewModel.settings.resolvedWebSocketURL(for: viewModel.settings.realtimeProvider) else {
            return "<invalid endpoint>"
        }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint.absoluteString
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? endpoint.absoluteString
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
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }

            Button("Export Diagnostics…") {
                exportDiagnostics()
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

            Text("Status: \(viewModel.statusText)")
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.contentWidth, alignment: .leading)

            if let connectionFailureDetail {
                statusDetailView(connectionFailureDetail)
            } else if let lastError = viewModel.lastError {
                statusDetailView("Error: \(lastError)")
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

    /// Writes a local-first diagnostics report to the Desktop. The report
    /// contains only non-secret configuration/status (no API keys, no dictated
    /// content). See `DiagnosticsExporter` for the redaction boundary.
    private func exportDiagnostics() {
        let backendManager = viewModel.backendManager
        let snapshot = DiagnosticsExporter.makeSnapshot(
            settings: viewModel.settings,
            voxmlxStatus: backendManager.voxmlxStatus,
            mlxLMStatus: backendManager.mlxLMStatus,
            voxmlxRecentOutput: backendManager.recentOutput(for: BackendCatalog.voxmlx),
            mlxLMRecentOutput: backendManager.recentOutput(for: BackendCatalog.mlxLM)
        )

        guard let desktop = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first else {
            Log.diagnostics.error("diagnostics export failed: Desktop directory unavailable")
            return
        }

        // Snapshot is built on the MainActor above; rendering and the file
        // write happen off-main so a slow/iCloud-backed Desktop can never
        // beachball the menu bar app.
        let exportedAt = Date()
        Task.detached(priority: .utility) {
            do {
                let writtenURL = try DiagnosticsExporter.writeReport(
                    snapshot: snapshot,
                    to: desktop,
                    now: exportedAt
                )
                Log.diagnostics.info("diagnostics exported: \(writtenURL.path, privacy: .public)")
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([writtenURL])
                }
            } catch {
                Log.diagnostics.error("diagnostics export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
