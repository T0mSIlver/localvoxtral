import AppKit
import SwiftUI

/// Identifies each Settings tab so navigation can be driven programmatically
/// (e.g. the onboarding "I run my own server" link jumps to Endpoints).
enum SettingsTab: String, Hashable, CaseIterable, Sendable {
    case general
    case endpoints
    case dictation
    case textProcessing
    case about
}

/// Shared, observable selection for the Settings `TabView`. Owned by the app
/// delegate so a programmatic tab change survives the Settings window's
/// open/close lifecycle.
@MainActor
@Observable
final class SettingsNavigator {
    var selectedTab: SettingsTab = .general
}

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var viewModel: DictationViewModel
    var backendManager: BackendManager
    @Bindable var navigator: SettingsNavigator
    @State private var shortcutValidationError: String?

    private var endpointBinding: Binding<String> {
        Binding(
            get: {
                settings.endpointURL(for: settings.realtimeProvider)
            },
            set: { newValue in
                viewModel.applyRealtimeEndpointChange(newValue)
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                settings.modelName(for: settings.realtimeProvider)
            },
            set: { newValue in
                settings.realtimeAPIModelName = newValue
            }
        )
    }

    private var dictationShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: {
                settings.dictationShortcut
            },
            set: { newValue in
                viewModel.updateDictationShortcut(newValue)
            }
        )
    }

    private var overlayBufferShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: { settings.overlayBufferShortcut },
            set: { newValue in
                viewModel.updateOverlayBufferShortcut(newValue)
            }
        )
    }

    private var livePasteShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: { settings.livePasteShortcut },
            set: { newValue in
                viewModel.updateLivePasteShortcut(newValue)
            }
        )
    }

    var body: some View {
        TabView(selection: $navigator.selectedTab) {
            GeneralSettingsPane(settings: settings, viewModel: viewModel)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            ConnectionSettingsPane(
                settings: settings,
                viewModel: viewModel,
                backendManager: backendManager,
                endpointBinding: endpointBinding,
                modelBinding: modelBinding
            )
            .tabItem {
                Label("Endpoints", systemImage: "network")
            }
            .tag(SettingsTab.endpoints)

            DictationSettingsPane(
                settings: settings,
                viewModel: viewModel,
                dictationShortcutBinding: dictationShortcutBinding,
                overlayBufferShortcutBinding: overlayBufferShortcutBinding,
                livePasteShortcutBinding: livePasteShortcutBinding,
                shortcutValidationError: $shortcutValidationError
            )
            .tabItem {
                Label("Dictation", systemImage: "mic")
            }
            .tag(SettingsTab.dictation)

            TextProcessingSettingsPane(
                settings: settings,
                viewModel: viewModel
            )
            .tabItem {
                Label("Text Processing", systemImage: "text.badge.checkmark")
            }
            .tag(SettingsTab.textProcessing)

            AboutSettingsPane(viewModel: viewModel)
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(SettingsTab.about)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GeneralSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Permissions") {
                PermissionRowsView(viewModel: viewModel)
            }

            SettingsGroup(title: "App") {
                SettingsFieldRow(title: "Copy final segment") {
                    Toggle("", isOn: $settings.autoCopyEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)

                    SettingsHelpText("Copies to the clipboard on stop.")
                }

                SettingsFieldRow(title: "Setup") {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Re-run Setup…") {
                            viewModel.reRunOnboarding()
                        }

                        SettingsHelpText(
                            "Reopen the first-launch setup wizard for permissions and downloads."
                        )
                    }
                }
            }
        }
    }
}

private enum SettingsLayout {
    static let pageSpacing: CGFloat = 16
    static let pagePadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 10
    static let cardSpacing: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let rowSpacing: CGFloat = 14
    static let labelWidth: CGFloat = 128
    static let cornerRadius: CGFloat = 18
}

private struct ConnectionSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel
    let backendManager: BackendManager
    let endpointBinding: Binding<String>
    let modelBinding: Binding<String>

    private var polishingEndpointBinding: Binding<String> {
        Binding(
            get: { settings.llmPolishingEndpointURL },
            set: { viewModel.applyLLMPolishingEndpointChange($0) }
        )
    }

    private var dictationBackendModeBinding: Binding<BackendMode> {
        Binding(
            get: { settings.dictationBackendMode },
            set: { newValue in
                viewModel.applyDictationBackendModeChange(newValue)
            }
        )
    }

    private var polishingBackendModeBinding: Binding<BackendMode> {
        Binding(
            get: { settings.polishingBackendMode },
            set: { newValue in
                viewModel.applyPolishingBackendModeChange(newValue)
            }
        )
    }

    private var managedPolishingModelBinding: Binding<String> {
        Binding(
            get: { settings.resolvedManagedLLMPolishingModel },
            set: { viewModel.applyLLMPolishingModelChange($0) }
        )
    }

    private var speechdCacheLimitBinding: Binding<SpeechdCacheLimit> {
        Binding(
            get: { settings.speechdCacheLimit },
            set: { viewModel.applySpeechdCacheLimitChange($0) }
        )
    }

    private var speechdStepCadenceBinding: Binding<SpeechdStepCadence> {
        Binding(
            get: { settings.speechdStepCadence },
            set: { viewModel.applySpeechdStepCadenceChange($0) }
        )
    }

    private var managedPolishingModelEntries: [PolishModelPickerEntry] {
        PolishModelPickerSupport.entries(storedRepoID: settings.resolvedManagedLLMPolishingModel)
    }

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Dictation") {
                SettingsFieldRow(title: "Mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: dictationBackendModeBinding) {
                            ForEach(BackendMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        SettingsHelpText(settings.dictationBackendMode.dictationDescription)
                    }
                }

                switch settings.dictationBackendMode {
                case .externalURL:
                    SettingsFieldRow(title: "Endpoint") {
                        TextField(settings.endpointPlaceholder, text: endpointBinding)
                            .textFieldStyle(.roundedBorder)
                    }

                    SettingsFieldRow(title: "Model") {
                        TextField(settings.modelPlaceholder, text: modelBinding)
                            .textFieldStyle(.roundedBorder)
                    }

                    SettingsFieldRow(title: "API key") {
                        SecureField("Required for remote providers", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                case .managedLocal:
                    SettingsFieldRow(title: "Memory limit") {
                        Picker("", selection: speechdCacheLimitBinding) {
                            ForEach(SpeechdCacheLimit.allCases) { limit in
                                Text(limit.displayName).tag(limit)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    SettingsFieldRow(title: "Step interval") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: speechdStepCadenceBinding) {
                                ForEach(SpeechdStepCadence.allCases) { cadence in
                                    Text(cadence.displayName).tag(cadence)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()

                            SettingsHelpText(
                                "Lower values show words sooner; higher values use less compute."
                            )
                        }
                    }

                    ManagedBackendStatusRow(
                        title: "Status",
                        status: backendManager.speechdStatus
                    )
                }
            }

            SettingsGroup(title: "Polishing") {
                SettingsFieldRow(title: "Mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: polishingBackendModeBinding) {
                            ForEach(BackendMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        SettingsHelpText(settings.polishingBackendMode.polishingDescription)
                    }
                }

                switch settings.polishingBackendMode {
                case .externalURL:
                    SettingsFieldRow(title: "Endpoint") {
                        TextField(
                            "http://127.0.0.1:8080",
                            text: polishingEndpointBinding
                        )
                        .textFieldStyle(.roundedBorder)

                        SettingsHelpText(
                            "Enter a base URL (e.g. http://127.0.0.1:8080); "
                                + "/v1/chat/completions is appended automatically. "
                                + "A full …/v1/chat/completions URL still works."
                        )
                    }

                    SettingsFieldRow(title: "API key") {
                        SecureField(
                            "Required for remote providers",
                            text: $settings.llmPolishingAPIKey
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    SettingsFieldRow(title: "Model") {
                        TextField(
                            "mlx-community/Qwen3.5-4B-OptiQ-4bit",
                            text: $settings.llmPolishingModel
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                case .managedLocal:
                    SettingsFieldRow(title: "Model") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: managedPolishingModelBinding) {
                                ForEach(managedPolishingModelEntries) { entry in
                                    Text(entry.label).tag(entry.repoID)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()

                            if let selectedEntry = managedPolishingModelEntries.first(
                                where: { $0.repoID == settings.resolvedManagedLLMPolishingModel }
                            ) {
                                SettingsHelpText(
                                    PolishModelPickerSupport.helpText(
                                        for: selectedEntry,
                                        isDownloaded: PolishModelCache.isDownloaded(
                                            repoID: selectedEntry.repoID,
                                            revision: selectedEntry.option?.revision
                                        )
                                    )
                                )
                            }
                        }
                    }

                    ManagedBackendStatusRow(
                        title: "Status",
                        status: backendManager.polishdStatus
                    )
                }
            }
        }
    }
}

private struct ManagedBackendStatusRow: View {
    let title: String
    let status: ManagedBackendStatus

    var body: some View {
        SettingsFieldRow(title: title) {
            ManagedBackendStatusLabel(status: status)
        }
    }
}

private struct ManagedBackendStatusLabel: View {
    let status: ManagedBackendStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            // Determinate progress renders as a 54pt linear bar; the
            // indeterminate case is a circular spinner, which must NOT get
            // the bar's fixed width (it centers inside it, reading as a big
            // blob of horizontal padding next to the caption text).
            if case .preparingModel(let progress) = status {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 54)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch status {
        case .preparingModel(let progress):
            return modelDownloadText(progress)
        case .starting:
            return "Starting"
        case .ready:
            return "Ready"
        case .stopped:
            return "Stopped"
        case .failed(let summary, _):
            return "Failed: \(summary)"
        }
    }

    private var statusColor: Color {
        switch status {
        case .ready:
            return .green
        case .preparingModel, .starting:
            return .orange
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    private func modelDownloadText(_ progress: ModelDownloadProgress) -> String {
        guard let totalBytes = progress.totalBytes, totalBytes > 0 else {
            // Bytes moving but no total (CDN sent no length for some file):
            // show movement rather than pretending we are still checking.
            if progress.downloadedBytes > 0 {
                return "Downloading model - \(Self.byteText(progress.downloadedBytes))"
            }
            // No total yet: the downloader is still resolving what (if
            // anything) needs fetching — on a warm cache this phase is all
            // the user ever sees, so don't claim a download is happening.
            return "Checking model..."
        }
        // Clamp: the downloader's aggregate can transiently disagree with the
        // dry-run total (retries, resumed partials); never render > 100%.
        let downloaded = min(progress.downloadedBytes, totalBytes)
        return "Downloading model - \(Self.byteText(downloaded)) of \(Self.byteText(totalBytes))"
    }

    private static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}

private struct DictationSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel
    let dictationShortcutBinding: Binding<DictationShortcut?>
    let overlayBufferShortcutBinding: Binding<DictationShortcut?>
    let livePasteShortcutBinding: Binding<DictationShortcut?>
    @Binding var shortcutValidationError: String?

    private var dictationOutputModeBinding: Binding<DictationOutputMode> {
        Binding(
            get: { settings.dictationOutputMode },
            set: { newValue in
                viewModel.applyDictationOutputModeChange(newValue)
            }
        )
    }
    @State private var overlayValidationError: String?
    @State private var livePasteValidationError: String?

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Start dictation with") {
                SettingsFieldRow(title: "Trigger") {
                    Picker("", selection: Binding(
                        get: { settings.modifierOnlyHotKeyEnabled },
                        set: { newValue in
                            viewModel.applyDictationTriggerModeChange(
                                modifierOnlyEnabled: newValue
                            )
                        }
                    )) {
                        Text("Single modifier key").tag(true)
                        Text("Keyboard shortcuts").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if settings.modifierOnlyHotKeyEnabled {
                    SettingsFieldRow(title: "Modifier key") {
                        Picker("", selection: Binding(
                            get: { settings.modifierOnlyHotKeyModifier },
                            set: { newValue in
                                settings.modifierOnlyHotKeyModifier = newValue
                                viewModel.applyHotKeySettingsChange()
                            }
                        )) {
                            ForEach(ModifierOnlyHotKeyManager.ModifierKey.allCases) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    SettingsFieldRow(title: "Tap") {
                        Text("Overlay Buffer — toggle dictation on and off.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    SettingsFieldRow(title: "Hold") {
                        Text("Live Auto-Paste — talk while held, stops on release.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    SettingsFieldRow(title: "Hold delay") {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { settings.modifierOnlyHoldDelay },
                                    set: { newValue in
                                        settings.modifierOnlyHoldDelay = newValue
                                        viewModel.applyHotKeySettingsChange()
                                    }
                                ),
                                in: 0.1...0.8,
                                step: 0.05
                            )
                            Text("\(Int(settings.modifierOnlyHoldDelay * 1000))ms")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                } else {
                    SettingsFieldRow(title: "Overlay Buffer") {
                        HStack(alignment: .center, spacing: 8) {
                            ShortcutRecorderField(
                                shortcut: overlayBufferShortcutBinding,
                                validationError: $overlayValidationError,
                                fixedWidth: 132
                            )
                            .frame(height: 24, alignment: .leading)

                            Button("Reset") {
                                overlayValidationError = nil
                                viewModel.updateOverlayBufferShortcut(
                                    SettingsStore.defaultDictationShortcut)
                            }
                            .disabled(
                                settings.overlayBufferShortcut == SettingsStore.defaultDictationShortcut)
                        }

                        if let overlayValidationError {
                            SettingsInlineMessage(overlayValidationError, color: .red)
                        } else if settings.overlayBufferShortcut == nil {
                            SettingsInlineMessage(
                                "Not set. Record one to enable.",
                                color: .secondary
                            )
                        }
                    }

                    SettingsFieldRow(title: "Live Auto-Paste") {
                        HStack(alignment: .center, spacing: 8) {
                            ShortcutRecorderField(
                                shortcut: livePasteShortcutBinding,
                                validationError: $livePasteValidationError,
                                fixedWidth: 132
                            )
                            .frame(height: 24, alignment: .leading)

                            // Always present (disabled when empty) so both
                            // shortcut rows keep identical heights and spacing.
                            Button("Clear") {
                                livePasteValidationError = nil
                                viewModel.updateLivePasteShortcut(nil)
                            }
                            .disabled(settings.livePasteShortcut == nil)
                        }

                        if let livePasteValidationError {
                            SettingsInlineMessage(livePasteValidationError, color: .red)
                        } else if settings.livePasteShortcut == nil {
                            SettingsInlineMessage(
                                "Not set. Record one to enable.",
                                color: .secondary
                            )
                        }
                    }

                    SettingsFieldRow(title: "Shortcut behavior") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: $settings.dictationShortcutMode) {
                                ForEach(DictationShortcutMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            SettingsHelpText(settings.dictationShortcutMode.description)
                        }
                    }
                }
            }

            SettingsGroup(title: "Overlay Buffer") {
                SettingsFieldRow(title: "Font size") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Slider(
                                value: $settings.overlayBufferFontSize,
                                in: OverlayLayoutMetrics.minimumBodyFontSize
                                    ... OverlayLayoutMetrics.maximumBodyFontSize,
                                step: 1
                            )
                            Text("\(Int(settings.overlayBufferFontSize))pt")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }

                        SettingsHelpText("Scales the whole dictation overlay panel.")
                    }
                }
            }

            SettingsGroup(title: "Menu bar") {
                SettingsFieldRow(title: "Output mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: dictationOutputModeBinding) {
                            ForEach(DictationOutputMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        SettingsHelpText(settings.dictationOutputMode.description)
                    }
                }
            }
        }
    }
}

private struct TextProcessingSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel

    private var isLLMPolishingReachable: Bool {
        settings.isOverlayBufferSessionReachable
    }

    private var llmPolishingEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.llmPolishingEnabled },
            set: { newValue in
                let wasEnabled = settings.llmPolishingEnabled
                settings.llmPolishingEnabled = newValue

                if newValue, !wasEnabled {
                    viewModel.prepareLLMPolishingPromptAccessIfNeeded()
                }
                // Turning polishing off stops the managed polishd process
                // (Managed local mode only). External URL mode owns no local
                // process, and re-enabling starts managed polishd eagerly.
                viewModel.llmPolishingEnabledDidChange(newValue)
            }
        )
    }

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Replacements") {
                SettingsFieldRow(title: "Exact match") {
                    Toggle("", isOn: $settings.replacementDictionaryEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(
                            "In Live Auto-Paste, corrections briefly retype the last word in place. In apps that don't report the cursor position, avoid clicking elsewhere mid-dictation — a correction landing after the cursor moved can overwrite a few characters at the new position."
                        )
                }
            }

            SettingsGroup(title: "Polishing") {
                if !isLLMPolishingReachable {
                    SettingsAvailabilityCard(
                        title: "No Overlay Buffer shortcut",
                        message:
                            "Polishing runs on Overlay Buffer dictations. Record a shortcut in Dictation to enable it.",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }

                Group {
                    SettingsFieldRow(title: "Enable") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("", isOn: llmPolishingEnabledBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)

                            SettingsHelpText("Overlay Buffer dictations only.")
                        }
                    }

                    SettingsFieldRow(title: "Agent prompt profile in terminals") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("", isOn: $settings.agentPolishProfileEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)

                            SettingsHelpText(
                                "Agent-tuned instructions that trust the model's technical formatting. Clipboard safety checks remain active."
                            )
                        }
                    }

                    SettingsFieldRow(title: "Repo vocabulary from terminal") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("", isOn: $settings.repoVocabularyEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)

                            SettingsHelpText(
                                "Reads file names from the git repo in your terminal to fix technical spellings. Local polishing endpoints only."
                            )
                        }
                    }

                    SettingsFieldRow(title: "Use Claude Code terminal screen as polish context") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("", isOn: $settings.terminalScreenContextEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)

                            // Names the send, not just the benefit: when the
                            // pane is joined to a live Claude Code session, part
                            // of what is on screen is attached to the prompt
                            // verbatim. "Fixes spellings" describes only the
                            // matcher and would be consent obtained for the
                            // smaller half.
                            SettingsHelpText(
                                "Reads file names and identifiers from your Claude Code terminal to fix technical spellings. When the terminal is running a Claude Code session, part of the text on screen is also sent to the polisher. Ghostty only, local polishing endpoints only."
                            )
                        }
                    }

                    // A row in the EXISTING group, never a new group: pane group
                    // structure is constant (owner rule, 2026-07-04).
                    SettingsFieldRow(title: "Use Claude Code project files as polish context") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("", isOn: $settings.claudeRepoContextEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)

                            // Says what is SENT, not just what is gained: this
                            // toggle attaches file contents and diffs, which the
                            // vocabulary toggle above does not. Someone who
                            // agreed to "spell my filenames right" has not
                            // thereby agreed to this.
                            //
                            // All four things the toggle actually sends are
                            // named. The prior request is the one a user would
                            // least expect from a label about "project files",
                            // and it is their own typed words. The remote clause
                            // is worded to describe what the SESSION carries, not
                            // a second behavior: a remote session sends the
                            // excerpts its hooks already reported, and never
                            // causes anything on this machine to be read.
                            SettingsHelpText(
                                "Sends your uncommitted changes, the contents of files Claude Code recently touched, and the last request you sent that session to the polisher, so it can spell code and file names exactly. For a session on a remote host, only the session's own request and the short excerpts its hooks report are sent — no files are read from that host. Requires a Claude Code session in Ghostty; local polishing endpoints only."
                            )
                        }
                    }

                    SettingsFieldRow(title: "Use clipboard as polish context") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("", isOn: $settings.polishClipboardContextEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)

                            SettingsHelpText(
                                "Grounds technical terms against your clipboard. Local polishing endpoints only."
                            )
                        }
                    }

                    // A row in the EXISTING group, never a new group: pane group
                    // structure is constant (owner rule, 2026-07-04).
                    SettingsFieldRow(title: "Send polish context to non-local endpoints") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("", isOn: $settings.polishContextTrustedEndpointEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)

                            // Names the trade in full: every "local polishing
                            // endpoints only" promise above is exactly what
                            // this toggle relaxes, so the help text says which
                            // content classes ride and where they go. "You
                            // trust" puts the judgment where it now lives —
                            // with the user — instead of implying the app can
                            // vouch for their endpoint.
                            SettingsHelpText(
                                "Off: clipboard, screen, and project context are only ever sent to a polisher on this Mac. On: the context enabled above is also sent to the polishing endpoint you configured — enable only for an endpoint you trust, such as a server on your own network."
                            )
                        }
                    }

                    SettingsFieldRow(title: "Spoken clipboard paste") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("", isOn: $settings.clipboardPayloadMacroEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)

                            SettingsHelpText(
                                "Say “paste clipboard” to insert your clipboard as a code block on commit."
                            )
                        }
                    }
                }
                .disabled(!isLLMPolishingReachable)
                .opacity(isLLMPolishingReachable ? 1.0 : 0.5)

                // These remain usable even without an Overlay Buffer shortcut:
                // revocation is the security off switch for an already-bound
                // listener, and plugin/session setup is independent of the
                // current hotkey configuration. They are still rows in the same
                // constant Polishing group.
                SettingsFieldRow(title: "Local Claude title fallback") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("", isOn: $settings.claudeLocalTitleMarkerFallbackEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)

                        SettingsHelpText(
                            settings.claudeLocalTitleMarkerFallbackEnabled
                                ? "Writes a window-title marker for local sessions; also export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 so Claude Code does not overwrite it."
                                : "Uses the focused TTY to join local sessions and requires Ghostty 1.4 or a tip build."
                        )
                    }
                }

                if let claude = viewModel.claudeIntegrationSettings {
                    ClaudePluginSettingsRow(model: claude)
                    ClaudeRemoteHostsSettingsRow(model: claude)
                }
            }

            SettingsGroup(title: "Configuration") {
                SettingsFieldRow(title: "Config folder") {
                    Button("Open Config Folder") {
                        viewModel.openConfigFolder()
                    }
                }

                SettingsFieldRow(title: "Included files") {
                    SettingsFileNotes(notes: [
                        SettingsFileNote(
                            name: "replacement_dictionary.toml",
                            description:
                                "Replacements used in both output modes."
                        ),
                        SettingsFileNote(
                            name: "llm_system_prompt.toml",
                            description: "System prompt for polishing."
                        ),
                        SettingsFileNote(
                            name: "llm_user_prompt.toml",
                            description:
                                "User prompt template for polishing. Remove {{replacement_dictionary}} to stop sending the dictionary to the LLM."
                        ),
                        SettingsFileNote(
                            name: "llm_system_prompt_agent.toml",
                            description: "System prompt for the agent profile in terminals."
                        ),
                        SettingsFileNote(
                            name: "llm_user_prompt_agent.toml",
                            description: "User prompt template for the agent profile."
                        ),
                        SettingsFileNote(
                            name: "terminal_apps.toml",
                            description: "Extra apps to treat as terminals."
                        ),
                    ])
                }
            }
        }
    }
}

/// Install/update the LOCAL Claude Code plugin.
///
/// One explicit action, never anything at launch: putting a plugin into someone
/// else's Claude Code is their decision. The result is one short line here; the
/// CLI's actual output goes to an alert and the log (owner rule: no long text in
/// the pane).
private struct ClaudePluginSettingsRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel

    var body: some View {
        SettingsFieldRow(title: "Claude Code plugin (this Mac)") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Install or Update") {
                        Task { await model.updatePlugin() }
                    }
                    .disabled(model.isPerformingPluginAction)

                    Button("Remove") {
                        Task { await model.uninstallPlugin() }
                    }
                    .disabled(model.isPerformingPluginAction)

                    if model.isPerformingPluginAction {
                        ProgressView().controlSize(.small)
                    }

                    if let result = model.pluginResult {
                        Text(result)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                SettingsHelpText(
                    "Lets localvoxtral see which Claude Code session owns your terminal, so dictation lands in the right one. Runs `claude plugin` — nothing is installed until you press this."
                )
            }
        }
    }
}

/// Enrolled SSH hosts, and the preview-first setup for each.
private struct ClaudeRemoteHostsSettingsRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel

    var body: some View {
        SettingsFieldRow(title: "Remote Claude Code over SSH") {
            VStack(alignment: .leading, spacing: 8) {
                if !model.isRemoteAvailable {
                    SettingsInlineMessage(
                        "The enrolled-host list could not be read. See Console for details.",
                        color: .orange
                    )
                } else {
                    hostList
                    enrollmentForm
                    listenerStatus
                }

                SettingsHelpText(
                    "Dictate into Claude Code running on another machine. Each host gets its own token; revoking one takes effect immediately."
                )
            }
        }
        .sheet(item: Binding(get: { model.presentedPlan }, set: { if $0 == nil { model.dismissPlan() } })) { plan in
            ClaudeRemoteEnrollmentSheet(model: model, presentation: plan) { model.dismissPlan() }
                .interactiveDismissDisabled(model.isPerformingEnrollmentAction)
        }
        // The current API, not `alert(item:)` — that one is deprecated and the
        // repo builds warning-free. The detail lives HERE and never in the pane
        // (owner rule: no long text there).
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            ),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.detail)
        }
        .onAppear {
            model.refreshHosts()
            model.refreshListenerStatus()
        }
    }

    @ViewBuilder
    private var hostList: some View {
        if model.hosts.isEmpty {
            Text("No hosts enrolled.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.hosts) { host in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(host.label).font(.callout)
                            HStack(spacing: 3) {
                                Text(host.statusText)
                                // Self-updating, and no formatter to cache.
                                if let lastSeenAt = host.lastSeenAt, !host.isRevoked {
                                    Text(lastSeenAt, style: .relative)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rotate Token") { Task { await model.rotate(hostID: host.id) } }
                            .controlSize(.small)
                        if !host.isRevoked {
                            Button("Revoke") { Task { await model.revoke(hostID: host.id) } }
                                .controlSize(.small)
                        }
                        Button("Remove") { Task { await model.remove(hostID: host.id) } }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var enrollmentForm: some View {
        HStack(spacing: 8) {
            TextField("Name", text: $model.enrollLabel)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)
            TextField("SSH host alias", text: $model.enrollSSHAlias)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
            Button("Enroll…") { Task { await model.enroll() } }
                .disabled(!model.canEnroll)
        }
    }

    @ViewBuilder
    private var listenerStatus: some View {
        HStack(spacing: 8) {
            Text(model.listenerStatus.text)
                .font(.caption)
                .foregroundStyle(model.listenerStatus.isFailure ? .orange : .secondary)
                .lineLimit(2)
            if model.listenerStatus.isFailure {
                Button("Retry") { model.retryListener() }
                    .controlSize(.small)
            }
        }
        if let remedy = model.listenerStatus.remedy {
            Text(remedy)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }
}

/// The token, shown exactly once.
///
/// The registry stores only hashes, so this sheet is genuinely the user's one
/// chance to copy the credential — there is no "show it again". The copy says so
/// plainly, and the recovery path (rotate) is one button away in the pane behind
/// it.
private struct ClaudeRemoteEnrollmentSheet: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    let presentation: ClaudeIntegrationSettingsModel.EnrollmentPresentation
    let onDismiss: () -> Void

    private var plan: ClaudeRemoteEnrollmentService.SetupPlan { presentation.plan }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.isRotation ? "New token for \(presentation.host.label)" : "Enroll \(presentation.host.label)")
                .font(.headline)

            if presentation.isRotation {
                Text("The previous token stopped working immediately. This host has no access until you run the install command below with the new token.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section(
                        "Token — copy it now",
                        body: presentation.token,
                        note: "It is not stored and cannot be shown again. If you lose it, rotate."
                    )
                    section(
                        "1. Add to ~/.ssh/config on this Mac",
                        body: plan.sshConfigSnippet,
                        note: "Insertion replaces only this host's marked block and writes the file atomically.",
                        actionTitle: "Insert into ~/.ssh/config",
                        enrollmentAction: .insertSSHConfig,
                        action: { model.requestSSHConfigInsertion() }
                    )
                    section(
                        "2. Run on the remote host",
                        body: plan.remoteCommands.joined(separator: "\n"),
                        displayedBody: ClaudeIntegrationSettingsModel.redactedRemoteCommands(for: presentation),
                        note: "One-click execution sends the token through SSH stdin, never process arguments.",
                        actionTitle: "Run on SSH host",
                        enrollmentAction: .runRemoteSetup,
                        action: { model.requestRemoteSetup() }
                    )
                    section("Verify", body: plan.verifyCommands.joined(separator: "\n"), note: nil)
                    section("Uninstall", body: plan.uninstallCommands.joined(separator: "\n"), note: nil)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.subheadline).bold()
                        ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                            Text("• \(note)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 260)

            HStack {
                if model.isPerformingEnrollmentAction {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Done", action: onDismiss).keyboardShortcut(.defaultAction)
                    .disabled(model.isPerformingEnrollmentAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }

    /// One step's outcome, rendered inside the section whose button ran it.
    /// A pooled results area below step 2 is how a step-1 success went unseen
    /// in the field and got re-confirmed.
    @ViewBuilder
    private func sectionResults(for enrollmentAction: ClaudeIntegrationSettingsModel.EnrollmentAction) -> some View {
        if model.enrollmentResultsAction == enrollmentAction, !model.enrollmentStepStatuses.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.enrollmentStepStatuses) { step in
                    Text("\(step.succeeded ? "✓" : "✗") \(step.text)")
                        .font(.caption)
                        .foregroundStyle(step.succeeded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .lineLimit(1)
                }
                let details = model.enrollmentStepStatuses
                    .map(\.detail)
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                if !details.isEmpty {
                    ScrollView {
                        Text(details)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    private func section(
        _ title: String,
        body: String,
        displayedBody: String? = nil,
        note: String?,
        actionTitle: String? = nil,
        enrollmentAction: ClaudeIntegrationSettingsModel.EnrollmentAction? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        // The confirmation lives in the section whose button requested it, so
        // "Confirm" is always next to the thing it confirms. The displayed body
        // above the buttons IS the confirmation preview (the plan's exact
        // snippet for step 1, the redacted commands for step 2) — highlighted
        // while the question is pending, so the second explicit confirmation
        // still repeats the exact text it authorizes.
        let pendingConfirmation = model.enrollmentConfirmation.flatMap { confirmation in
            confirmation.action == enrollmentAction ? confirmation : nil
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).bold()
                Spacer()
                Button("Copy") {
                    // Everything in this sheet embeds or accompanies the
                    // enrollment token — concealed, so clipboard managers and
                    // our own clipboard-context harvester skip it (F4).
                    ConcealedPasteboardWriter.write(body)
                }
                .controlSize(.small)
            }
            Text(displayedBody ?? body)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(
                    pendingConfirmation != nil
                        ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 4)
                )
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            if let confirmation = pendingConfirmation {
                Text(confirmation.title).font(.caption).bold()
                HStack {
                    Button("Cancel") { model.cancelEnrollmentActionConfirmation() }
                    Button(confirmation.confirmButtonTitle) {
                        Task { await model.confirmEnrollmentAction() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            } else if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .disabled(model.isPerformingEnrollmentAction)
            }
            if let enrollmentAction {
                sectionResults(for: enrollmentAction)
            }
        }
    }
}

private struct AboutSettingsPane: View {
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
        SettingsPage {
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
            }

            SettingsGroup(title: "Diagnostics") {
                SettingsFieldRow(title: "Export") {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Export Diagnostics…") {
                            viewModel.exportDiagnostics()
                        }

                        SettingsHelpText(
                            "Writes a redacted report to the Desktop; review before sharing."
                        )
                    }
                }
            }
        }
    }
}

private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(SettingsLayout.pagePadding)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: SettingsLayout.cardSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsLayout.cardPadding)
            .background {
                RoundedRectangle(
                    cornerRadius: SettingsLayout.cornerRadius,
                    style: .continuous
                )
                .fill(Color(nsColor: .quaternarySystemFill))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: SettingsLayout.cornerRadius,
                        style: .continuous
                    )
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsAvailabilityCard: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    private let cornerRadius: CGFloat = 16
    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background {
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
            .fill(tint.opacity(0.10))
            .overlay {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .stroke(tint.opacity(0.18), lineWidth: 1)
            }
        }
    }
}

private struct SettingsFieldRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.rowSpacing) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsHelpText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsFileNote: Identifiable {
    let id = UUID()
    let name: String
    let description: String
}

private struct SettingsFileNotes: View {
    let notes: [SettingsFileNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))

                    Text(note.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsInlineMessage: View {
    let message: String
    let color: Color

    init(_ message: String, color: Color) {
        self.message = message
        self.color = color
    }

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
