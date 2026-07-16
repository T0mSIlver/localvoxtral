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
                settings.realtimeAPIEndpointURL = newValue
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
                    ManagedBackendStatusRow(
                        title: "Status",
                        status: backendManager.voxmlxStatus
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
                            "http://127.0.0.1:8080/v1/chat/completions",
                            text: $settings.llmPolishingEndpointURL
                        )
                        .textFieldStyle(.roundedBorder)
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
            if case .installing(let progress) = status {
                if let fraction = installFraction(from: progress) {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 54)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            } else if case .preparingModel(let progress) = status {
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
        case .notInstalled:
            return "Not installed"
        case .installing(let progress):
            return installingText(progress)
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
        case .installing, .preparingModel, .starting:
            return .orange
        case .failed:
            return .red
        case .notInstalled, .stopped:
            return .secondary
        }
    }

    private func installFraction(from progress: BackendInstallProgress) -> Double? {
        guard case .downloading(let fraction) = progress else { return nil }
        return fraction
    }

    private func installingText(_ progress: BackendInstallProgress) -> String {
        switch progress {
        case .downloading(let fraction):
            guard let fraction else { return "Downloading" }
            return "Downloading \(Int((fraction * 100).rounded()))%"
        case .verifying:
            return "Verifying"
        case .installing(let logLine):
            return logLine.trimmed.isEmpty ? "Installing" : "Installing: \(logLine)"
        case .finished:
            return "Installed"
        }
    }

    private func modelDownloadText(_ progress: ModelDownloadProgress) -> String {
        guard let totalBytes = progress.totalBytes, totalBytes > 0 else {
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

                            SettingsHelpText(
                                "Reads file names and identifiers from your Claude Code terminal to fix technical spellings. Ghostty only, local polishing endpoints only."
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
                            SettingsHelpText(
                                "Sends your uncommitted changes and the contents of files Claude Code recently touched to the polisher, so it can spell code and file names exactly. Requires a Claude Code session in Ghostty; local polishing endpoints only."
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
