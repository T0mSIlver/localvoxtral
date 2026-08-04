import AppKit
import SwiftUI

/// Identifies each Settings tab so navigation can be driven programmatically
/// (e.g. the onboarding "I run my own server" link jumps to Endpoints).
enum SettingsTab: String, Hashable, CaseIterable, Sendable {
    case general
    case endpoints
    case dictation
    case textProcessing
    case context
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
        HStack(spacing: 0) {
            SettingsSidebarView(selection: $navigator.selectedTab)

            // The sidebar's trailing hairline. One divider, drawn by the layout
            // rather than by both columns, so it cannot double up.
            Divider()

            detailColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SettingsWindowChrome()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// Header + the selected pane. No transition/animation on the swap: pane
    /// content is dense, and cross-fading it reads as a flicker.
    private var detailColumn: some View {
        VStack(spacing: 0) {
            SettingsPaneHeader(tab: navigator.selectedTab)

            Divider()

            switch navigator.selectedTab {
            case .general:
                GeneralSettingsPane(settings: settings, viewModel: viewModel)
            case .endpoints:
                ConnectionSettingsPane(
                    settings: settings,
                    viewModel: viewModel,
                    backendManager: backendManager,
                    endpointBinding: endpointBinding,
                    modelBinding: modelBinding
                )
            case .dictation:
                DictationSettingsPane(
                    settings: settings,
                    viewModel: viewModel,
                    dictationShortcutBinding: dictationShortcutBinding,
                    overlayBufferShortcutBinding: overlayBufferShortcutBinding,
                    livePasteShortcutBinding: livePasteShortcutBinding,
                    shortcutValidationError: $shortcutValidationError
                )
            case .textProcessing:
                TextProcessingSettingsPane(
                    settings: settings,
                    viewModel: viewModel
                )
            case .context:
                ContextSettingsPane(
                    settings: settings,
                    viewModel: viewModel
                )
            case .about:
                AboutSettingsPane(settings: settings, viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct GeneralSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel

    var body: some View {
        SettingsPage(tab: .general) {
            SettingsGroup(title: "Permissions") {
                // Wrapped rather than given the row insets itself: this view is
                // shared verbatim with the onboarding wizard.
                SettingsGroupRow {
                    PermissionRowsView(viewModel: viewModel)
                }
            }

            SettingsGroup(title: "App") {
                SettingsFieldRow(
                    title: "Copy final segment",
                    help: "Copies to the clipboard on stop."
                ) {
                    Toggle("", isOn: $settings.autoCopyEnabled)
                        .labelsHidden()
                }

                SettingsFieldRow(
                    title: "Setup",
                    help: "Reopen the first-launch setup wizard for permissions and downloads."
                ) {
                    Button("Re-run Setup…") {
                        viewModel.reRunOnboarding()
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
    /// Horizontal inset of a row inside its group card. Owned by the ROW, not
    /// by the card: the dividers between rows have to run the full card width.
    static let rowHorizontalPadding: CGFloat = 14
    static let rowVerticalPadding: CGFloat = 11
    /// Gap between a row's label and its control.
    static let rowSpacing: CGFloat = 14
    /// Sliders report no intrinsic width, so a trailing control column has to
    /// give them one.
    static let sliderWidth: CGFloat = 190
    /// Text fields are worse than sliders: no intrinsic width AND greedy, so in
    /// an inline row's trailing column (`layoutPriority(1)`) an unbounded field
    /// takes the whole card and starves the label to zero width (field report,
    /// PR #201 review — the External URL rows rendered as tall empty bands).
    static let textFieldWidth: CGFloat = 280
    static let cornerRadius: CGFloat = 8
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

    /// Nil when the stored repo is not one of the offered entries — the row then
    /// renders without an explanation, exactly as it did before.
    private var managedPolishingModelHelp: String? {
        guard
            let selectedEntry = managedPolishingModelEntries.first(
                where: { $0.repoID == settings.resolvedManagedLLMPolishingModel }
            )
        else { return nil }

        return PolishModelPickerSupport.helpText(
            for: selectedEntry,
            isDownloaded: PolishModelCache.isDownloaded(
                repoID: selectedEntry.repoID,
                revision: selectedEntry.option?.revision
            )
        )
    }

    var body: some View {
        SettingsPage(tab: .endpoints) {
            SettingsGroup(title: "Dictation") {
                SettingsFieldRow(
                    title: "Mode",
                    help: settings.dictationBackendMode.dictationDescription
                ) {
                    Picker("", selection: dictationBackendModeBinding) {
                        ForEach(BackendMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                switch settings.dictationBackendMode {
                case .externalURL:
                    SettingsFieldRow(title: "Endpoint") {
                        TextField(settings.endpointPlaceholder, text: endpointBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: SettingsLayout.textFieldWidth)
                    }

                    SettingsFieldRow(title: "Model") {
                        TextField(settings.modelPlaceholder, text: modelBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: SettingsLayout.textFieldWidth)
                    }

                    SettingsFieldRow(title: "API key") {
                        SecureField("Required for remote providers", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: SettingsLayout.textFieldWidth)
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

                    SettingsFieldRow(
                        title: "Step interval",
                        help: "Lower values show words sooner; higher values use less compute."
                    ) {
                        Picker("", selection: speechdStepCadenceBinding) {
                            ForEach(SpeechdStepCadence.allCases) { cadence in
                                Text(cadence.displayName).tag(cadence)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    ManagedBackendStatusRow(
                        title: "Status",
                        status: backendManager.speechdStatus
                    )
                }
            }

            SettingsGroup(title: "Polishing") {
                SettingsFieldRow(
                    title: "Mode",
                    help: settings.polishingBackendMode.polishingDescription
                ) {
                    Picker("", selection: polishingBackendModeBinding) {
                        ForEach(BackendMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                switch settings.polishingBackendMode {
                case .externalURL:
                    SettingsFieldRow(
                        title: "Endpoint",
                        help: "Enter a base URL (e.g. http://127.0.0.1:8080); "
                            + "/v1/chat/completions is appended automatically. "
                            + "A full …/v1/chat/completions URL still works."
                    ) {
                        TextField(
                            "http://127.0.0.1:8080",
                            text: polishingEndpointBinding
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: SettingsLayout.textFieldWidth)
                    }

                    SettingsFieldRow(title: "API key") {
                        SecureField(
                            "Required for remote providers",
                            text: $settings.llmPolishingAPIKey
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: SettingsLayout.textFieldWidth)
                    }

                    SettingsFieldRow(title: "Model") {
                        TextField(
                            "mlx-community/Qwen3.5-4B-OptiQ-4bit",
                            text: $settings.llmPolishingModel
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: SettingsLayout.textFieldWidth)
                    }
                case .managedLocal:
                    SettingsFieldRow(title: "Model", help: managedPolishingModelHelp) {
                        Picker("", selection: managedPolishingModelBinding) {
                            ForEach(managedPolishingModelEntries) { entry in
                                Text(entry.label).tag(entry.repoID)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
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
        SettingsPage(tab: .dictation) {
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
                            // A Slider has no intrinsic width; in a trailing
                            // control column it would collapse, so both sliders
                            // in this pane are given the same explicit track.
                            .frame(width: SettingsLayout.sliderWidth)

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

                    SettingsFieldRow(
                        title: "Shortcut behavior",
                        help: settings.dictationShortcutMode.description
                    ) {
                        Picker("", selection: $settings.dictationShortcutMode) {
                            ForEach(DictationShortcutMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }

            SettingsGroup(title: "Overlay Buffer") {
                SettingsFieldRow(
                    title: "Font size",
                    help: "Scales the whole dictation overlay panel."
                ) {
                    HStack(spacing: 8) {
                        Slider(
                            value: $settings.overlayBufferFontSize,
                            in: OverlayLayoutMetrics.minimumBodyFontSize
                                ... OverlayLayoutMetrics.maximumBodyFontSize,
                            step: 1
                        )
                        .frame(width: SettingsLayout.sliderWidth)

                        Text("\(Int(settings.overlayBufferFontSize))pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            SettingsGroup(title: "Menu bar") {
                SettingsFieldRow(
                    title: "Output mode",
                    help: settings.dictationOutputMode.description
                ) {
                    Picker("", selection: dictationOutputModeBinding) {
                        ForEach(DictationOutputMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
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
        SettingsPage(tab: .textProcessing) {
            SettingsGroup(title: "Replacements") {
                SettingsFieldRow(title: "Exact match") {
                    Toggle("", isOn: $settings.replacementDictionaryEnabled)
                        .labelsHidden()
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
                    SettingsFieldRow(
                        title: "Enable",
                        help: "Overlay Buffer dictations only."
                    ) {
                        Toggle("", isOn: llmPolishingEnabledBinding)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Agent prompt profile in terminals",
                        help:
                            "Agent-tuned instructions that trust the model's technical formatting. Clipboard safety checks remain active."
                    ) {
                        Toggle("", isOn: $settings.agentPolishProfileEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Spoken clipboard paste",
                        help:
                            "Say “paste clipboard” to insert your clipboard as a code block on commit."
                    ) {
                        Toggle("", isOn: $settings.clipboardPayloadMacroEnabled)
                            .labelsHidden()
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

                // Stacked: a list of file names with descriptions is a
                // full-width block, not a control.
                SettingsFieldRow(title: "Included files", layout: .stacked) {
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

/// Everything that lets something OTHER than your spoken words reach the
/// polisher, plus the Claude Code plumbing those sources depend on.
///
/// Split out of Text Processing (2026-08-04): these are consent-grade toggles
/// whose help text is the consent, and they were being read past as formatting
/// options next to "Exact match". The three groups here are STATIC — a toggle
/// switches a group's content, never the number or identity of the groups
/// (owner rule, 2026-07-04).
private struct ContextSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel

    /// Same gate as the Text Processing polishing rows: context is only ever
    /// harvested for an Overlay Buffer dictation, so with no shortcut recorded
    /// for one, none of these sources can run.
    private var isLLMPolishingReachable: Bool {
        settings.isOverlayBufferSessionReachable
    }

    var body: some View {
        SettingsPage(tab: .context) {
            SettingsGroup(title: "Polish context") {
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
                    SettingsFieldRow(
                        title: "Repo vocabulary from terminal",
                        help:
                            "Reads file names from the git repo in your terminal to fix technical spellings. Local polishing endpoints only."
                    ) {
                        Toggle("", isOn: $settings.repoVocabularyEnabled)
                            .labelsHidden()
                    }

                    // Names the send, not just the benefit: when the pane is
                    // joined to a live Claude Code session, part of what is on
                    // screen is attached to the prompt verbatim. "Fixes
                    // spellings" describes only the matcher and would be consent
                    // obtained for the smaller half.
                    SettingsFieldRow(
                        title: "Use Claude Code terminal screen as polish context",
                        help:
                            "Reads file names and identifiers from your Claude Code terminal to fix technical spellings. When the terminal is running a Claude Code session, part of the text on screen is also sent to the polisher. Supported terminals (Ghostty, iTerm2, Terminal.app, cmux) only; local polishing endpoints only."
                    ) {
                        Toggle("", isOn: $settings.terminalScreenContextEnabled)
                            .labelsHidden()
                    }

                    // Says what is SENT, not just what is gained: this toggle
                    // attaches file contents and diffs, which the vocabulary
                    // toggle above does not. Someone who agreed to "spell my
                    // filenames right" has not thereby agreed to this.
                    //
                    // All four things the toggle actually sends are named. The
                    // prior request is the one a user would least expect from a
                    // label about "project files", and it is their own typed
                    // words. The remote clause is worded to describe what the
                    // SESSION carries, not a second behavior: a remote session
                    // sends the excerpts its hooks already reported, and never
                    // causes anything on this machine to be read.
                    SettingsFieldRow(
                        title: "Use Claude Code project files as polish context",
                        help:
                            "Sends your uncommitted changes, the contents of files Claude Code recently touched, and the last request you sent that session to the polisher, so it can spell code and file names exactly. For a session on a remote host, only the session's own request and the short excerpts its hooks report are sent — no files are read from that host. Requires a Claude Code session in a supported terminal, or a Remote Control session in the focused browser tab; local polishing endpoints only."
                    ) {
                        Toggle("", isOn: $settings.claudeRepoContextEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Use clipboard as polish context",
                        help:
                            "Grounds technical terms against your clipboard. Local polishing endpoints only."
                    ) {
                        Toggle("", isOn: $settings.polishClipboardContextEnabled)
                            .labelsHidden()
                    }

                    // Names the trade in full: every "local polishing endpoints
                    // only" promise above is exactly what this toggle relaxes,
                    // so the help text says which content classes ride and where
                    // they go. "You trust" puts the judgment where it now lives
                    // — with the user — instead of implying the app can vouch
                    // for their endpoint.
                    SettingsFieldRow(
                        title: "Send polish context to non-local endpoints",
                        help:
                            "Off: clipboard, screen, and project context are only ever sent to a polisher on this Mac. On: the context enabled above is also sent to the polishing endpoint you configured — enable only for an endpoint you trust, such as a server on your own network."
                    ) {
                        Toggle("", isOn: $settings.polishContextTrustedEndpointEnabled)
                            .labelsHidden()
                    }
                }
                .disabled(!isLLMPolishingReachable)
                .opacity(isLLMPolishingReachable ? 1.0 : 0.5)
            }

            // Deliberately NOT under the availability gate above: revocation is
            // the security off switch for an already-bound listener, and
            // plugin/session setup is independent of the current hotkey
            // configuration.
            SettingsGroup(title: "Claude Code") {
                SettingsFieldRow(
                    title: "Local Claude title fallback",
                    help: settings.claudeLocalTitleMarkerFallbackEnabled
                        ? "Writes a window-title marker for local sessions; also export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 so Claude Code does not overwrite it."
                        : "Uses the focused TTY to join local sessions and requires Ghostty 1.4 or a tip build."
                ) {
                    Toggle("", isOn: $settings.claudeLocalTitleMarkerFallbackEnabled)
                        .labelsHidden()
                }

                // Beside the title fallback, not in Polish context above: this
                // is a JOIN arm — it decides which session you are dictating
                // into — and like the title fallback it works with no Overlay
                // Buffer shortcut recorded.
                //
                // Names the prerequisite AND the send. cmux exposes no
                // accessible text, so the socket is the only way to read the
                // pane the user is dictating into — and that socket refuses
                // everyone by default, which is a setup step in ANOTHER app
                // that the user has to know about or this toggle will look
                // broken.
                SettingsFieldRow(
                    title: "Join Claude Code sessions in cmux",
                    help:
                        "Uses cmux's automation socket to tell which session you are dictating into, and to read that one surface as context. In cmux, set Settings → Automation socket mode to Password and choose a socket password, then enter the same password below. Works for local surfaces and for sessions opened with cmux ssh."
                ) {
                    Toggle("", isOn: $settings.cmuxSurfaceJoinEnabled)
                        .labelsHidden()
                }

                if let claude = viewModel.claudeIntegrationSettings {
                    // Directly under the toggle whose prerequisite it is: the
                    // help text above tells the user to enter it "below".
                    ClaudeCmuxPasswordSettingsRow(model: claude)
                    ClaudePluginSettingsRow(model: claude)
                }
            }

            // The integration model is built once at launch and cleared only on
            // terminate, so the `if let` is not a mode: in a running app both
            // groups above and this one always have their rows.
            SettingsGroup(title: "Remote hosts") {
                if let claude = viewModel.claudeIntegrationSettings {
                    ClaudeRemoteHostsSettingsRow(model: claude)
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
        // Stacked: the row's controls are a full button bar plus a result line,
        // which would squeeze the label to a three-line stub beside them.
        SettingsFieldRow(
            title: "Claude Code plugin (this Mac)",
            help:
                "Lets localvoxtral see which Claude Code session owns your terminal, so dictation lands in the right one. Runs `claude plugin` — nothing is installed until you press this.",
            layout: .stacked
        ) {
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
        }
    }
}

/// The cmux automation-socket password, stored in the Keychain.
///
/// A write-only field on purpose: the stored secret is never read back into the
/// UI, so what the user typed leaves the process the moment they save it, and
/// the row reports only whether one is stored.
private struct ClaudeCmuxPasswordSettingsRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel

    var body: some View {
        SettingsFieldRow(
            title: "cmux socket password",
            help:
                "Stored in your Keychain and sent only to cmux's local socket. Save an empty field to remove it."
        ) {
            HStack(alignment: .center, spacing: 8) {
                SecureField("cmux socket password", text: $model.cmuxPasswordField)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    // Bounded like every other inline field: unbounded, it
                    // takes the whole card and starves the label (PR #201).
                    .frame(width: SettingsLayout.textFieldWidth)

                Button("Save") {
                    model.saveCmuxPassword()
                }
            }

            // Its own line rather than a fourth item in the bar: the status is
            // a sentence, and beside a 280pt field it would push the row past
            // the card.
            Text(model.cmuxStatusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Enrolled SSH hosts, and the preview-first setup for each.
private struct ClaudeRemoteHostsSettingsRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel

    var body: some View {
        // Stacked: host rows and the enrollment form are full-width composites.
        SettingsFieldRow(
            title: "Remote Claude Code over SSH",
            help:
                "Dictate into Claude Code running on another machine. Each host gets its own token; revoking one takes effect immediately.",
            layout: .stacked
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if !model.isRemoteAvailable {
                    SettingsInlineMessage(
                        "The enrolled-host list could not be read. See Console for details.",
                        color: .orange
                    )
                } else {
                    hostList
                    // The only place a rejected connection is visible without
                    // the unified log. It is what an hours-long stream of
                    // rejections looked like from the app: nothing at all.
                    if let hint = model.rejectionHint {
                        SettingsInlineMessage(hint, color: .orange)
                    }
                    enrollmentForm
                    listenerStatus
                }
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
                            // Rendered by the model against its injected clock —
                            // "Last context: 2 min ago" — and refreshed with the
                            // rest of the section. A tunnel that quietly stopped
                            // delivering context is otherwise invisible here.
                            Text(host.statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Update Plugin…") { model.requestPluginUpdate(hostID: host.id) }
                            .controlSize(.small)
                            .disabled(model.isPerformingEnrollmentAction)
                        Button("Rotate Token") { Task { await model.rotate(hostID: host.id) } }
                            .controlSize(.small)
                        if !host.isRevoked {
                            Button("Revoke") { Task { await model.revoke(hostID: host.id) } }
                                .controlSize(.small)
                        }
                        Button("Remove") { Task { await model.remove(hostID: host.id) } }
                            .controlSize(.small)
                            // Removing the row an action is reporting into is
                            // handled (the late-result guard drops the outcome),
                            // but offering it mid-run is still offering a race.
                            .disabled(model.isPerformingEnrollmentAction)
                    }
                    persistentForwardRow(for: host)
                    pluginUpdatePanel(for: host)
                }
            }
        }
    }

    /// The app-held tunnel switch for one host, INSIDE that host's row.
    ///
    /// Not a new group: a pane's group structure is constant (owner rule
    /// 2026-07-04), and this belongs to a host, not to the feature. It is the
    /// same idiom as `pluginUpdatePanel` — per-host sub-UI under the host line.
    ///
    /// A host with no alias on file gets no toggle at all rather than a
    /// disabled one with an explanation: there is nothing to enable, because we
    /// were never told where to ssh.
    @ViewBuilder
    private func persistentForwardRow(
        for host: ClaudeIntegrationSettingsModel.HostRow
    ) -> some View {
        if host.canHoldForward {
            HStack(spacing: 8) {
                Toggle(
                    "Keep the tunnel open",
                    isOn: Binding(
                        get: { host.persistentForwardEnabled },
                        set: { model.setPersistentForward($0, hostID: host.id) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.caption)
                if let status = host.forwardStatusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(host.forwardIsFailure ? Color.red : .secondary)
                        .lineLimit(1)
                }
                if host.forwardIsFailure {
                    Button("Retry") { model.retryPersistentForward(hostID: host.id) }
                        .controlSize(.small)
                }
                Spacer()
            }
            .padding(.leading, 12)
        }
    }

    /// One host's plugin-update commands, disclosed in that host's row.
    ///
    /// In the row rather than a new group, and confirmed and reported where the
    /// button is (PR #194): a result the user has to go looking for is a result
    /// they conclude never happened.
    @ViewBuilder
    private func pluginUpdatePanel(for host: ClaudeIntegrationSettingsModel.HostRow) -> some View {
        if let update = model.presentedPluginUpdate, update.hostID == host.id {
            // BOTH mutations, in order — not just the remote commands. The
            // copy-only paths (no recorded alias; the symlink refusal that
            // sends the user here) are exactly where showing only the commands
            // recreated the split brain this feature exists to remove.
            let commands = update.applicationText
            let action = ClaudeIntegrationSettingsModel.EnrollmentAction.updateRemotePlugin(hostID: host.id)
            let pendingConfirmation = model.enrollmentConfirmation.flatMap {
                $0.action == action ? $0 : nil
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Update the plugin on \(host.label)").font(.caption).bold()
                    Spacer()
                    Button("Copy") {
                        // No token here — the update keeps the stored one — but
                        // concealed anyway, so a Settings copy cannot ride into
                        // the next polish prompt's clipboard context.
                        ConcealedPasteboardWriter.write(commands)
                    }
                    .controlSize(.small)
                    Button("Close") { model.dismissPluginUpdate() }
                        .controlSize(.small)
                        .disabled(model.isPerformingEnrollmentAction)
                }
                // The displayed block IS the confirmation preview, highlighted
                // while the question is pending, so confirming still repeats the
                // exact commands it authorizes.
                Text(commands)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(
                        pendingConfirmation != nil
                            ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
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
                } else if update.canRun {
                    Button("Run on SSH host") { model.requestPluginUpdateRun() }
                        .controlSize(.small)
                        .disabled(model.isPerformingEnrollmentAction)
                } else {
                    Text("Replace your-ssh-host with the alias from your ~/.ssh/config, then apply both steps above yourself — the ssh-config block first.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if model.enrollmentResultsAction == action {
                    ClaudeEnrollmentStepResults(statuses: model.enrollmentStepStatuses)
                }
            }
            .padding(.leading, 8)
            .padding(.bottom, 4)
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

/// One action's outcome, rendered inside the section whose button ran it.
///
/// A pooled results area below step 2 is how a step-1 success went unseen in the
/// field and got re-confirmed — so the caller places this, and the model's
/// `enrollmentResultsAction` decides which caller gets to.
private struct ClaudeEnrollmentStepResults: View {
    let statuses: [ClaudeIntegrationSettingsModel.EnrollmentStepStatus]

    var body: some View {
        if !statuses.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(statuses) { step in
                    Text("\(step.succeeded ? "✓" : "✗") \(step.text)")
                        .font(.caption)
                        .foregroundStyle(step.succeeded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .lineLimit(1)
                }
                let details = statuses
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
                    // No Run button when the alias is the placeholder: this host
                    // was enrolled before the alias was persisted, so we do not
                    // know where to send a token. Copy still works.
                    section(
                        "2. Run on the remote host",
                        body: plan.remoteCommands.joined(separator: "\n"),
                        displayedBody: ClaudeIntegrationSettingsModel.redactedRemoteCommands(for: presentation),
                        note: presentation.canRunRemoteSetup
                            ? "One-click execution sends the token through SSH stdin, never process arguments."
                            : "Replace \(ClaudeIntegrationSettingsModel.unknownAliasPlaceholder) with the alias from your ~/.ssh/config and run these yourself — this host was enrolled before localvoxtral recorded its alias.",
                        actionTitle: presentation.canRunRemoteSetup ? "Run on SSH host" : nil,
                        enrollmentAction: .runRemoteSetup,
                        action: presentation.canRunRemoteSetup ? { model.requestRemoteSetup() } : nil
                    )
                    section("Verify", body: plan.verifyCommands.joined(separator: "\n"), note: nil)
                    section(
                        "Update later",
                        body: plan.updateCommands.joined(separator: "\n"),
                        note: "Also available per host in Settings, once localvoxtral ships a newer plugin."
                    )
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

    @ViewBuilder
    private func sectionResults(for enrollmentAction: ClaudeIntegrationSettingsModel.EnrollmentAction) -> some View {
        if model.enrollmentResultsAction == enrollmentAction {
            ClaudeEnrollmentStepResults(statuses: model.enrollmentStepStatuses)
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
    let settings: SettingsStore
    let viewModel: DictationViewModel

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "localvoxtral"
    }

    /// Shows the in-memory value the capture pipeline actually consults
    /// (DictationViewModel+DogfoodCapture), not a live defaults read — a
    /// `defaults write` while the app runs takes effect on relaunch, and the
    /// row must describe what THIS process is doing.
    private var dogfoodCaptureArmed: Bool {
        #if LOCALVOXTRAL_DOGFOOD
        settings.dogfoodCaptureEnabled
        #else
        false
        #endif
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
        SettingsPage(tab: .about) {
            SettingsGroup(title: "Application") {
                SettingsFieldRow(title: "Name") {
                    Text(appName)
                }

                SettingsFieldRow(title: "Version") {
                    Text("\(appVersion) (build \(appBuild))")
                }

                // Constant row, variant-dependent content: "which binary am I
                // running" is exactly the question that has cost field-debug
                // time before (AGENTS.md), and version alone can't answer it —
                // dogfood builds keep the same version and bundle id.
                SettingsFieldRow(
                    title: "Build",
                    help: DogfoodBuildStatus.detail(
                        isDogfoodBuild: DogfoodBuildStatus.isDogfoodBuild,
                        captureArmed: dogfoodCaptureArmed
                    )
                ) {
                    Text(
                        DogfoodBuildStatus.label(
                            isDogfoodBuild: DogfoodBuildStatus.isDogfoodBuild,
                            captureArmed: dogfoodCaptureArmed
                        )
                    )
                    .foregroundStyle(DogfoodBuildStatus.isDogfoodBuild ? Color.orange : Color.primary)
                }

                SettingsFieldRow(title: "Project") {
                    Link(
                        "github.com/T0mSIlver/localvoxtral",
                        destination: URL(string: "https://github.com/T0mSIlver/localvoxtral")!
                    )
                }
            }

            SettingsGroup(title: "Diagnostics") {
                SettingsFieldRow(
                    title: "Export",
                    help: "Writes a redacted report to the Desktop; review before sharing."
                ) {
                    Button("Export Diagnostics…") {
                        viewModel.exportDiagnostics()
                    }
                }
            }
        }
    }
}

private struct SettingsPage<Content: View>: View {
    /// Identifies the pane's content subtree to the AX drills
    /// (`settings.pane.<rawValue>`), which scope their content assertions to it
    /// so a sidebar row's label can never satisfy a pane assertion.
    let tab: SettingsTab
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(SettingsLayout.pagePadding)
            // One place decides how a switch looks, instead of every call site
            // repeating `.toggleStyle(.switch)`.
            .toggleStyle(.switch)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(tab.paneAccessibilityIdentifier)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Every row draws a trailing divider, which makes the LAST one a
            // stray line above the card's bottom edge. Rather than teach the
            // card to enumerate its children (they are heterogeneous, and some
            // arrive wrapped in `Group`/`if` branches), the container is made
            // 1pt shorter than its content and clipped: the final divider hangs
            // outside the clip and is never drawn.
            .padding(.bottom, -1)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: SettingsLayout.cornerRadius,
                    style: .continuous
                )
            )
            .background {
                RoundedRectangle(
                    cornerRadius: SettingsLayout.cornerRadius,
                    style: .continuous
                )
                .fill(.quinary)
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: SettingsLayout.cornerRadius,
                    style: .continuous
                )
                .strokeBorder(.quaternary, lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Insets + trailing divider shared by everything that is a row of a
/// `SettingsGroup`. Rows own their insets so the dividers span the card.
private struct SettingsGroupRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
                .padding(.vertical, SettingsLayout.rowVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
        }
    }
}

private struct SettingsAvailabilityCard: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    private let cornerRadius: CGFloat = 8
    private let horizontalPadding: CGFloat = 12
    private let verticalPadding: CGFloat = 10

    var body: some View {
        SettingsGroupRow {
            card
        }
    }

    /// It is a row of its group like any other (same insets, same trailing
    /// divider) — only its own fill is different.
    private var card: some View {
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

/// Label leading, control trailing, explanation on its own full-width line
/// underneath — the macOS System Settings idiom.
///
/// The label no longer sits in a fixed 128pt column: long labels used to wrap
/// inside it while short ones left a gutter, and the explanation started at the
/// column's edge, which made every card's text a ragged second column. The label
/// now takes the leftover width (`layoutPriority(0)`, so the control keeps its
/// intrinsic size) and the explanation is a row of its own, aligned to the
/// label's leading edge.
private enum SettingsFieldRowLayout {
    /// Label leading, control trailing on the same line. The default.
    case inline
    /// Label on its own line, control full-width beneath it. For rows whose
    /// control is a composite (button bar, host list, file list): beside a
    /// 400pt-wide control the label would be squeezed into a wrapped stub.
    case stacked
}

private struct SettingsFieldRow<Content: View>: View {
    let title: String
    /// The secondary explanation. A parameter rather than a view inside
    /// `content`: a row cannot pull a nested view out of its control column, and
    /// the whole point is that this text is NOT in that column.
    var help: String?
    var layout: SettingsFieldRowLayout
    @ViewBuilder var content: Content

    init(
        title: String,
        help: String? = nil,
        layout: SettingsFieldRowLayout = .inline,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.help = help
        self.layout = layout
        self.content = content()
    }

    var body: some View {
        SettingsGroupRow {
            VStack(alignment: .leading, spacing: 6) {
                switch layout {
                case .inline:
                    inlineRow
                case .stacked:
                    stackedRow
                }

                if let help {
                    SettingsHelpText(help)
                }
            }
        }
    }

    private var label: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var inlineRow: some View {
        // Top-aligned, not centered: some rows' controls are tall (recorder +
        // button pairs, status blocks) and a centered short label next to those
        // reads as misaligned.
        HStack(alignment: .top, spacing: SettingsLayout.rowSpacing) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)

            VStack(alignment: .trailing, spacing: 6) {
                content
            }
            .layoutPriority(1)
        }
    }

    private var stackedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
