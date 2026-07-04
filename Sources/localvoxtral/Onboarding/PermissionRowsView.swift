import AppKit
import SwiftUI

/// The single source of truth for the microphone + Accessibility permission
/// rows. Rendered identically by the onboarding wizard's Permissions page and
/// the General settings pane. Live-refreshes on appear and whenever the app is
/// foregrounded (the moment a grant made in System Settings takes effect),
/// mirroring the popover's refresh pattern.
struct PermissionRowsView: View {
    var viewModel: DictationViewModel

    private static let accessibilitySettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    private static let microphoneSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            microphoneRow
            Divider()
            accessibilityRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: refresh)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refresh()
        }
    }

    // MARK: - Rows

    private var microphoneRow: some View {
        PermissionRow(
            title: "Microphone",
            subtitle: "Required to capture audio for dictation.",
            isGranted: microphoneGranted,
            statusText: microphoneStatusText,
            action: microphoneAction
        )
    }

    private var accessibilityRow: some View {
        PermissionRow(
            title: "Accessibility",
            subtitle: "Lets localvoxtral type transcribed text into other apps.",
            isGranted: viewModel.isAccessibilityTrusted,
            statusText: viewModel.isAccessibilityTrusted ? "Granted" : "Not granted",
            action: accessibilityAction
        )
    }

    // MARK: - Microphone state

    private var microphoneGranted: Bool {
        viewModel.microphoneAuthorizationStatus == .authorized
    }

    private var microphoneStatusText: String {
        switch viewModel.microphoneAuthorizationStatus {
        case .authorized: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        }
    }

    private var microphoneAction: PermissionRow.Action? {
        switch viewModel.microphoneAuthorizationStatus {
        case .authorized:
            return nil
        case .notDetermined:
            return PermissionRow.Action(label: "Allow Microphone…") {
                viewModel.requestMicrophonePermission()
            }
        case .denied, .restricted:
            return PermissionRow.Action(label: "Open System Settings") {
                Self.openSettings(Self.microphoneSettingsURL)
            }
        }
    }

    // MARK: - Accessibility state

    private var accessibilityAction: PermissionRow.Action? {
        guard !viewModel.isAccessibilityTrusted else { return nil }
        return PermissionRow.Action(label: "Grant Access") {
            viewModel.requestAccessibilityPermission()
            Self.openSettings(Self.accessibilitySettingsURL)
        }
    }

    private func refresh() {
        viewModel.refreshAccessibilityTrustState()
        viewModel.refreshMicrophonePermissionState()
    }

    private static func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PermissionRow: View {
    struct Action {
        let label: String
        let perform: () -> Void
    }

    let title: String
    let subtitle: String
    let isGranted: Bool
    let statusText: String
    let action: Action?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isGranted ? Color.green : Color.orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isGranted ? Color.green : .secondary)
            }

            Spacer(minLength: 12)

            if let action {
                Button(action.label, action: action.perform)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
