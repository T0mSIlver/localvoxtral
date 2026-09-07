import AppKit
import SwiftUI

/// Identifies each Settings tab so navigation can be driven programmatically
/// (e.g. the onboarding "I run my own server" link jumps to Engines).
enum SettingsTab: String, Hashable, CaseIterable, Sendable {
    case general
    case endpoints
    case dictation
    case textProcessing
    case integrations
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
            case .integrations:
                IntegrationsSettingsPane(
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
                    title: "Copy on stop"
                ) {
                    Toggle("", isOn: $settings.autoCopyEnabled)
                        .labelsHidden()
                }

                SettingsFieldRow(
                    title: "Setup wizard"
                ) {
                    Button("Re-run setup…") {
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
    /// Keep this above 4pt. `SettingsGroup` hides the last row's trailing
    /// divider by making the card 1pt shorter than its content and clipping;
    /// with a smaller inset the last row's focus ring would reach into that
    /// clipped pixel and be cut off.
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
    ///
    /// A CAP, not a fixed width: apply it as `.frame(maxWidth:)`. A greedy field
    /// still fills to the cap wherever the card is wide enough (which, at the
    /// Settings window's fixed 780pt, is everywhere), so the look is unchanged —
    /// but a rigid width would crumple the label instead of the field if the
    /// card ever got narrower.
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
                    title: "Mode"
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
                    SettingsFieldRow(title: "Server URL") {
                        TextField(settings.endpointPlaceholder, text: endpointBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: SettingsLayout.textFieldWidth)
                    }

                    SettingsFieldRow(title: "Model") {
                        TextField(settings.modelPlaceholder, text: modelBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: SettingsLayout.textFieldWidth)
                    }

                    SettingsFieldRow(title: "API key") {
                        SecureField("Required for remote providers", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: SettingsLayout.textFieldWidth)
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
                        title: "Step interval"
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
                    title: "Mode"
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
                        title: "Server URL"
                    ) {
                        TextField(
                            "http://127.0.0.1:8080",
                            text: polishingEndpointBinding
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: SettingsLayout.textFieldWidth)
                    }

                    SettingsFieldRow(title: "API key") {
                        SecureField(
                            "Required for remote providers",
                            text: $settings.llmPolishingAPIKey
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: SettingsLayout.textFieldWidth)
                    }

                    SettingsFieldRow(title: "Model") {
                        TextField(
                            "mlx-community/Qwen3.5-4B-OptiQ-4bit",
                            text: $settings.llmPolishingModel
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: SettingsLayout.textFieldWidth)
                    }
                case .managedLocal:
                    SettingsFieldRow(title: "Model") {
                        Picker("", selection: managedPolishingModelBinding) {
                            ForEach(managedPolishingModelEntries) { entry in
                                Text(entry.label).tag(entry.repoID)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    } footer: {
                        if let managedPolishingModelHelp {
                            SettingsHelpText(managedPolishingModelHelp)
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
            return "Failed. \(summary)"
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
                return "Downloading model, \(Self.byteText(progress.downloadedBytes))"
            }
            // No total yet: the downloader is still resolving what (if
            // anything) needs fetching — on a warm cache this phase is all
            // the user ever sees, so don't claim a download is happening.
            return "Checking model..."
        }
        // Clamp: the downloader's aggregate can transiently disagree with the
        // dry-run total (retries, resumed partials); never render > 100%.
        let downloaded = min(progress.downloadedBytes, totalBytes)
        return "Downloading model, \(Self.byteText(downloaded)) of \(Self.byteText(totalBytes))"
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
            SettingsGroup(title: "Trigger") {
                SettingsFieldRow(title: "Method") {
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
                        Text("Toggles Overlay Buffer dictation.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    SettingsFieldRow(title: "Hold") {
                        Text("Streams text live while held.")
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
                    // `.top`: the recorder is a 24pt bordered field with a button
                    // beside it, the tallest inline control in the pane.
                    SettingsFieldRow(
                        title: "Overlay Buffer",
                        controlAlignment: .top
                    ) {
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
                    } footer: {
                        // A footer, not a third item in the control column: a
                        // validation sentence right-aligned under the recorder
                        // wraps in a 200pt column and reads as unattached.
                        if let overlayValidationError {
                            SettingsInlineMessage(overlayValidationError, color: .red)
                        } else if settings.overlayBufferShortcut == nil {
                            SettingsInlineMessage(
                                "Not set. Record one to enable.",
                                color: .secondary
                            )
                        }
                    }

                    SettingsFieldRow(
                        title: "Live Auto-Paste",
                        controlAlignment: .top
                    ) {
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
                    } footer: {
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
                        title: "Shortcut action"
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
                    title: "Font size"
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
                    title: "Output mode"
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
                            "In Live Auto-Paste, corrections briefly retype the last word in place. In apps that do not report the cursor position, stay in place mid-dictation. A correction after a move can overwrite characters at the new position."
                        )
                }
            }

            SettingsGroup(title: "Polishing") {
                if !isLLMPolishingReachable {
                    SettingsAvailabilityCard(
                        title: "No Overlay Buffer shortcut",
                        message:
                            "Polishing runs on Overlay Buffer dictations. Record a shortcut in Dictation.",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }

                Group {
                    SettingsFieldRow(
                        title: "Enable for Overlay Buffer"
                    ) {
                        Toggle("", isOn: llmPolishingEnabledBinding)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Agent prompt profile in terminals",
                        help: "Clipboard safety checks stay on."
                    ) {
                        Toggle("", isOn: $settings.agentPolishProfileEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Spoken clipboard paste",
                        help:
                            "Say \"paste clipboard\" to insert your clipboard as a code block on commit."
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
                    Button("Open config folder") {
                        viewModel.openConfigFolder()
                    }
                }

                // Stacked: a list of file names with descriptions is a
                // full-width block, not a control.
                SettingsFieldRow(title: "Files", layout: .stacked) {
                    SettingsFileNotes(notes: [
                        SettingsFileNote(name: "replacement_dictionary.toml"),
                        SettingsFileNote(name: "llm_system_prompt.toml"),
                        SettingsFileNote(name: "llm_user_prompt.toml"),
                        SettingsFileNote(name: "llm_system_prompt_agent.toml"),
                        SettingsFileNote(name: "llm_user_prompt_agent.toml"),
                        SettingsFileNote(name: "terminal_apps.toml"),
                    ])
                }
            }
        }
    }
}

/// Everything that lets something OTHER than your spoken words reach the
/// polisher, plus one row per harness that feeds it.
///
/// Split out of Text Processing (2026-08-04): these are consent-grade toggles
/// whose help text is the consent, and they were being read past as formatting
/// options next to "Exact match". The four groups here are STATIC — a toggle
/// switches a group's content, never the number or identity of the groups
/// (owner rule, 2026-07-04).
///
/// Copy rule (owner review, 2026-09-07): each toggle's help is ONE line
/// stating what leaves the machine — the consequence, nothing else. The full
/// terms live in `docs/coding-agents.md` behind each group's Learn more link.
private struct IntegrationsSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel

    /// Where each group's Learn more link lands. Repo pages, not relative
    /// links: Settings is a shipped app, not a doc site.
    private enum LearnMore {
        static let polishContext = URL(
            string:
                "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/coding-agents.md#polish-context-what-each-toggle-sends"
        )!
        static let claudeCode = URL(
            string:
                "https://github.com/T0mSIlver/localvoxtral/blob/main/integrations/claude-code/README.md#which-terminal-am-i-dictating-into"
        )!
        static let remoteHosts = URL(
            string: "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/remote-claude-context.md"
        )!
    }

    /// Read ONCE, when the pane is constructed — like every other `debug.`
    /// default, this is a screenshot affordance, not a preference that may
    /// change under a running window. Armed, it auto-presents a SAMPLE
    /// enrollment sheet whose every mutating action the model refuses.
    @State private var isEnrollmentSheetPreviewArmed =
        ClaudeIntegrationSettingsModel.isEnrollmentSheetPreviewArmed()

    /// Same gate as the Text Processing polishing rows: context is only ever
    /// harvested for an Overlay Buffer dictation, so with no shortcut recorded
    /// for one, none of these sources can run.
    private var isLLMPolishingReachable: Bool {
        settings.isOverlayBufferSessionReachable
    }

    var body: some View {
        SettingsPage(tab: .integrations) {
            SettingsGroup(title: "Polish context", learnMoreURL: LearnMore.polishContext) {
                if !isLLMPolishingReachable {
                    SettingsAvailabilityCard(
                        title: "No Overlay Buffer shortcut",
                        message:
                            "Polishing runs on Overlay Buffer dictations. Record a shortcut in Dictation.",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }

                Group {
                    // Each help line names the SEND — the consequence of the
                    // toggle — and nothing else. The full terms (supported
                    // terminals, the remote-session clause, the locality
                    // default and how "Non-local endpoints" relaxes it) are in
                    // docs/coding-agents.md, one Learn more away.
                    SettingsFieldRow(
                        title: "Repo vocabulary",
                        help: "Sends file names from the repo in your terminal to the polisher."
                    ) {
                        Toggle("", isOn: $settings.repoVocabularyEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Claude Code screen",
                        help: "Sends the text on screen in your Claude Code terminal to the polisher."
                    ) {
                        Toggle("", isOn: $settings.terminalScreenContextEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Claude Code project",
                        help: "Sends your uncommitted changes, recent files, and last prompt to the polisher."
                    ) {
                        Toggle("", isOn: $settings.claudeRepoContextEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Clipboard",
                        help: "Sends technical terms from your clipboard to the polisher."
                    ) {
                        Toggle("", isOn: $settings.polishClipboardContextEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Non-local endpoints",
                        help: "Also sends the context enabled above to your non-local polishing endpoint."
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
            SettingsGroup(title: "Claude Code", learnMoreURL: LearnMore.claudeCode) {
                if let claude = viewModel.claudeIntegrationSettings {
                    ClaudePluginInstallRow(model: claude)
                    ClaudeStatuslineRow(model: claude)
                }

                // Not in Polish context above: this is a JOIN arm — it decides
                // which session you are dictating into — and it works with no
                // Overlay Buffer shortcut recorded. The two-step cmux setup
                // (socket password mode, then this password) is in the group's
                // Learn more page.
                SettingsFieldRow(
                    title: "Join Claude Code sessions in cmux",
                    help: "Reads the cmux pane you dictate into, via cmux's automation socket."
                ) {
                    Toggle("", isOn: $settings.cmuxSurfaceJoinEnabled)
                        .labelsHidden()
                }

                if let claude = viewModel.claudeIntegrationSettings {
                    // Directly under the toggle whose prerequisite it is: the
                    // README's two-step setup ends with "enter the same
                    // password below".
                    ClaudeCmuxPasswordSettingsRow(model: claude)
                }
            }

            // The integration model is built once at launch and cleared only on
            // terminate, so the `if let` is not a mode: in a running app both
            // groups above and this one always have their rows.
            SettingsGroup(title: "Remote hosts", learnMoreURL: LearnMore.remoteHosts) {
                if let claude = viewModel.claudeIntegrationSettings {
                    ClaudeRemoteHostsSettingsRow(model: claude)
                }
            }

            SettingsGroup(title: "Other agents") {
                if let claude = viewModel.claudeIntegrationSettings {
                    OpencodePluginRow(model: claude)
                    // Status-only, and absent until something reports herdr:
                    // a row that can only ever say "not found" is noise, not
                    // information.
                    if claude.isHerdrDetected {
                        HerdrPresenceRow()
                    }
                }
            }
        }
        .onAppear {
            if isEnrollmentSheetPreviewArmed,
               let claude = viewModel.claudeIntegrationSettings {
                claude.presentPreviewPlan()
            }
        }
        .task {
            if let claude = viewModel.claudeIntegrationSettings {
                await claude.refreshIntegrationsStatuses()
            }
        }
    }
}

/// Install/update the LOCAL Claude Code plugin.
///
/// One explicit action, never anything at launch: putting a plugin into someone
/// else's Claude Code is their decision. The result is one short line next to
/// the label; the CLI's actual output goes to an alert and the log (owner
/// rule: no long text in the pane).
private struct ClaudePluginInstallRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel

    var body: some View {
        // One line (owner review, 2026-09-07): "label + status" leading, the
        // small buttons in the row's trailing column.
        SettingsFieldRow(
            title: "Plugin on this Mac",
            status: model.pluginResult ?? model.localPluginSentence,
            statusAccessibilityIdentifier: "integrations.claude.plugin.status"
        ) {
            HStack(spacing: 8) {
                Button("Install or update") {
                    Task { await model.updatePlugin() }
                }
                .disabled(model.isPerformingPluginAction)
                .accessibilityIdentifier("integrations.claude.plugin.install")

                Button("Remove") {
                    Task { await model.uninstallPlugin() }
                }
                .disabled(model.isPerformingPluginAction)
                .accessibilityIdentifier("integrations.claude.plugin.remove")

                if model.isPerformingPluginAction {
                    ProgressView().controlSize(.small)
                }
            }
            .controlSize(.small)
        }
    }
}

/// The opt-in connection indicator in Claude Code's bottom bar.
///
/// Install previews the exact JSON first and writes only on consent — the
/// same shape as the shell setup, for the same reason: this edits a file the
/// user owns. A foreign status line is never overwritten: no Install button,
/// only a link to the recipe that runs both.
private struct ClaudeStatuslineRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    @State private var isShowingSetup = false

    private static let docsURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/integrations/claude-code/README.md#connection-indicator-opt-in-status-line"
    )!

    var body: some View {
        // One line like the plugin row: status leads, small buttons trail.
        SettingsFieldRow(
            title: "Status line",
            status: model.statuslineResult ?? model.statuslineSentence,
            statusAccessibilityIdentifier: "integrations.claude.statusline.status"
        ) {
            HStack(spacing: 8) {
                switch model.statuslineStatus {
                case .notConfigured:
                    Button("Set up…") { isShowingSetup = true }
                        .disabled(model.statuslinePreview == nil)
                        .accessibilityIdentifier("integrations.claude.statusline.install")
                case .installed, .stalePath:
                    Button("Update…") { isShowingSetup = true }
                        .disabled(
                            model.isPerformingStatuslineAction || model.statuslinePreview == nil
                        )
                        .accessibilityIdentifier("integrations.claude.statusline.install")
                    Button("Remove") { Task { await model.removeStatusline() } }
                        .disabled(model.isPerformingStatuslineAction)
                        .accessibilityIdentifier("integrations.claude.statusline.remove")
                case .foreign, .edited:
                    Link("How to combine status lines", destination: Self.docsURL)
                case .unknown:
                    EmptyView()
                }

                if model.isPerformingStatuslineAction {
                    ProgressView().controlSize(.small)
                }
            }
            .controlSize(.small)
        }
        .sheet(isPresented: $isShowingSetup) {
            ClaudeStatuslineSetupSheet(model: model) { isShowingSetup = false }
        }
    }
}

/// Install/remove the opencode plugin.
///
/// Acts on press: the copy target is a file this app owns, and the `tui.json`
/// edit touches only this plugin's own list entry — everything else
/// round-trips. Failures report one short line here and the detail in an
/// alert (owner rule).
private struct OpencodePluginRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel

    var body: some View {
        // One line like the Claude Code rows above.
        SettingsFieldRow(
            title: "opencode",
            status: model.opencodeResult ?? model.opencodeSentence,
            statusAccessibilityIdentifier: "integrations.opencode.status"
        ) {
            HStack(spacing: 8) {
                Button("Install") {
                    Task { await model.installOpencodePlugin() }
                }
                .disabled(model.isPerformingOpencodeAction)
                .accessibilityIdentifier("integrations.opencode.install")

                Button("Remove") {
                    Task { await model.removeOpencodePlugin() }
                }
                .disabled(model.isPerformingOpencodeAction)
                .accessibilityIdentifier("integrations.opencode.remove")

                if model.isPerformingOpencodeAction {
                    ProgressView().controlSize(.small)
                }
            }
            .controlSize(.small)
        }
    }
}

/// herdr needs no setup: when it is present, panes join automatically. The
/// row is status-only, and hidden entirely until something reports herdr.
private struct HerdrPresenceRow: View {
    var body: some View {
        SettingsFieldRow(
            title: "herdr",
            status: ClaudeIntegrationSettingsModel.herdrDetectedSentence,
            statusAccessibilityIdentifier: "integrations.herdr.status"
        ) {
            EmptyView()
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
            help: "Stored in your Keychain, sent only to cmux's local socket."
        ) {
            HStack(alignment: .center, spacing: 8) {
                SecureField("cmux socket password", text: $model.cmuxPasswordField)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    // Bounded like every other inline field: unbounded, it
                    // takes the whole card and starves the label (PR #201).
                    .frame(maxWidth: SettingsLayout.textFieldWidth)

                Button("Save") {
                    model.saveCmuxPassword()
                }
            }
        } footer: {
            // The footer, not a trailing item in the control column: the status
            // is a sentence about the row, and in that trailing column it hung
            // flush-right under the Save button.
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
    @State private var isShowingShellSetup = false

    var body: some View {
        // Stacked: host rows and the enrollment form are full-width composites.
        SettingsFieldRow(
            title: "Claude Code over SSH",
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
                    shellSetup
                    herdrPanelSetup
                }
            }
        }
        .sheet(item: Binding(get: { model.presentedPlan }, set: { if $0 == nil { model.dismissPlan() } })) { plan in
            ClaudeRemoteEnrollmentSheet(model: model, presentation: plan) { model.dismissPlan() }
                .interactiveDismissDisabled(model.isEnrollmentBusy)
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
            model.refreshShellSetupStatus()
        }
        .sheet(isPresented: $isShowingShellSetup) {
            ClaudeShellSetupSheet(model: model) { isShowingShellSetup = false }
        }
    }

    /// The plain-ssh join's one setup step, on one line: title + status
    /// leading, the small buttons trailing. The two facts the status carries
    /// (is the export in the rc file; has a new session arrived carrying it)
    /// stay separate texts for the drills, separated by a middle dot.
    /// Nothing is written until the sheet has shown the exact text and been
    /// confirmed.
    @ViewBuilder
    private var shellSetup: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Terminal setup for plain SSH")
                    .font(.callout)
                    .accessibilityIdentifier("claude.remote.shellSetup.title")

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.shellSetupStatus.rcSentence)
                        .accessibilityIdentifier("claude.remote.shellSetup.rcStatus")
                    Text("·")
                        .accessibilityHidden(true)
                        .foregroundStyle(.tertiary)
                    Text(model.shellSetupStatus.crossingSentence)
                        .accessibilityIdentifier("claude.remote.shellSetup.crossingStatus")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if model.shellSetupStatus.rc == .applied {
                Button("Remove") { Task { await model.removeShellSetup() } }
                    .controlSize(.small)
                    .accessibilityIdentifier("claude.remote.shellSetup.remove")
            }
            Button("Set up…") { isShowingShellSetup = true }
                .controlSize(.small)
                .disabled(model.shellSetupPreview == nil)
                .accessibilityIdentifier("claude.remote.shellSetup.setUp")
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
                        // One line per host (owner review, 2026-09-07): label +
                        // "last context" leading, the small buttons trailing.
                        // The transient post-run status is the only thing that
                        // ever adds a second line.
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(host.label).font(.callout)

                            // Rendered by the model against its injected clock —
                            // "Last context: 2 min ago" — and refreshed with the
                            // rest of the section. A tunnel that quietly stopped
                            // delivering context is otherwise invisible here.
                            Text(host.statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        HStack(spacing: 8) {
                            Button("Update host…") { model.requestPluginUpdate(hostID: host.id) }
                                .controlSize(.small)
                                .disabled(model.isEnrollmentBusy)
                            Button("Rotate token") { Task { await model.rotate(hostID: host.id) } }
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
                                .disabled(model.isEnrollmentBusy)
                        }
                    }

                    hostSetupStatus(host.setupStatusText)

                    persistentForwardRow(for: host)
                    pluginUpdatePanel(for: host)
                }
            }
        }
    }

    /// The one-flow setup's last word for this host, written by the run, not
    /// computed here. Transient: the row is one line until a run has spoken.
    @ViewBuilder
    private func hostSetupStatus(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
                        .disabled(model.isEnrollmentBusy)
                }
                // The displayed block IS the confirmation preview, highlighted
                // while the question is pending, so confirming still repeats the
                // exact commands it authorizes.
                Text(commands)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        pendingConfirmation != nil
                            ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
                if let confirmation = pendingConfirmation {
                    Text(confirmation.title).font(.body).bold()
                    HStack {
                        Button("Cancel") { model.cancelEnrollmentActionConfirmation() }
                        Button(confirmation.confirmButtonTitle) {
                            Task { await model.confirmEnrollmentAction() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                } else if update.canRun {
                    HStack(spacing: 8) {
                        Button("Run on SSH host") { model.requestPluginUpdateRun() }
                            .controlSize(.small)
                            .disabled(model.isEnrollmentBusy)
                        Button("Update Host") { model.requestHostUpdateRun() }
                            .controlSize(.small)
                            .disabled(model.isEnrollmentBusy)
                    }
                    updateHostConfirmation(for: host)
                } else {
                    Text("Replace your-ssh-host with the alias from your ~/.ssh/config, then apply both steps above yourself. Do the ssh-config block first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.setupRun?.hostID == host.id {
                    ClaudeSetupRunSteps(model: model, hostID: host.id)
                }
                if model.enrollmentResultsAction == action {
                    ClaudeEnrollmentStepResults(statuses: model.enrollmentStepStatuses)
                }
            }
            .padding(.leading, 8)
            .padding(.bottom, 4)
        }
    }

    /// The one-flow update's consent, inside the row whose button asked for it.
    ///
    /// Same shape as the plugin-update confirmation above it: the exact preview
    /// the run will apply, then one confirming button. The run's own step list
    /// renders below, shared with the enrollment sheet.
    @ViewBuilder
    private func updateHostConfirmation(
        for host: ClaudeIntegrationSettingsModel.HostRow
    ) -> some View {
        let action = ClaudeIntegrationSettingsModel.EnrollmentAction.updateHost(hostID: host.id)
        if let confirmation = model.enrollmentConfirmation,
           confirmation.action == action {
            Text(confirmation.title).font(.body).bold()
            Text(confirmation.preview)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
            HStack {
                Button("Cancel") { model.cancelEnrollmentActionConfirmation() }
                Button(confirmation.confirmButtonTitle) {
                    Task { await model.confirmEnrollmentAction() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("integrations.remote.setup.run")
            }
            .controlSize(.small)
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
                .lineLimit(1)
            if model.listenerStatus.isFailure {
                Button("Retry") { model.retryListener() }
                    .controlSize(.small)
            }
        }
        if let remedy = model.listenerStatus.remedy {
            Text(remedy)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var herdrPanelSetup: some View {
        if let message = model.herdrPanelStatus.message {
            SettingsInlineMessage(message, color: .orange)
            Text(ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            ForEach(model.hosts.filter { !$0.isRevoked && $0.sshHostAlias != nil }) { host in
                let action = ClaudeIntegrationSettingsModel.EnrollmentAction.configureHerdrPanel(
                    hostID: host.id
                )
                if let confirmation = model.enrollmentConfirmation,
                   confirmation.action == action {
                    Text(confirmation.title).font(.caption).bold()
                    HStack {
                        Button("Cancel") { model.cancelEnrollmentActionConfirmation() }
                        Button(confirmation.confirmButtonTitle) {
                            Task { await model.confirmEnrollmentAction() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                } else {
                    Button("Configure on \(host.label)…") {
                        model.requestHerdrPanelConfiguration(hostID: host.id)
                    }
                    .controlSize(.small)
                }
                if model.enrollmentResultsAction == action {
                    ClaudeEnrollmentStepResults(statuses: model.enrollmentStepStatuses)
                }
            }
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
            // One line per step, and no command output: raw remote text is the
            // alert's and the log's job (owner rule), and at .caption2 in a
            // 90pt scroller nobody read it anyway.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(statuses) { step in
                    Text("\(step.succeeded ? "✓" : "✗") \(step.text)")
                        .font(.body)
                        .foregroundStyle(step.succeeded ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
                        .lineLimit(1)
                }
            }
        }
    }
}

/// One consented setup run, one line per step.
///
/// Shared by the enrollment sheet and the per-host update panel: both start the
/// same run and both render the same six steps. The model owns every sentence;
/// this renders strings.
private struct ClaudeSetupRunSteps: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    var hostID: String

    var body: some View {
        if let run = model.setupRun, run.hostID == hostID {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(run.items) { item in
                    HStack(spacing: 6) {
                        Text(Self.glyph(for: item.state))
                            .font(.body)
                            .foregroundStyle(
                                Self.isFailure(item.state)
                                    ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.step.title)
                                .font(.body)
                            Text(Self.statusLine(for: item.state))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .accessibilityIdentifier("integrations.remote.setup.step.\(item.step.rawValue)")
                }
            }
            if model.isEnrollmentBusy {
                Button("Cancel") { model.cancelSetupRun() }
                    .controlSize(.small)
                    .accessibilityIdentifier("integrations.remote.setup.cancel")
            }
            if let manual = model.setupManualInstructions {
                Text(manual)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private static func glyph(for state: RemoteHostSetupRun.State) -> String {
        switch state {
        case .pending: return "○"
        case .running: return "●"
        case .done: return "✓"
        case .skipped: return "–"
        case .failed: return "✗"
        }
    }

    private static func isFailure(_ state: RemoteHostSetupRun.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private static func statusLine(for state: RemoteHostSetupRun.State) -> String {
        switch state {
        case .pending: return "Waiting."
        case .running: return "Running."
        case .done(let summary): return summary
        case .skipped(let reason): return reason
        case .failed(let reason, _): return reason
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

    private static let documentationURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/remote-claude-context.md"
    )!

    private var plan: ClaudeRemoteEnrollmentService.SetupPlan { presentation.plan }

    /// The preview sheet exists to be photographed, so nothing in it may act.
    /// The model refuses a preview presentation on every entry point; this only
    /// stops the buttons looking live.
    private var actionsDisabled: Bool { model.isEnrollmentBusy || presentation.isPreview }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(presentation.isRotation ? "New token for \(presentation.host.label)" : "Enroll \(presentation.host.label)")
                    .font(.headline)
                if presentation.isPreview {
                    Text("Preview")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                }
            }

            if presentation.isRotation {
                Text("The previous token stopped working immediately. This host has no access until you run step 2 again with the new token.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(
                        "Copy the token now",
                        body: presentation.token,
                        note: "It cannot be shown again. If you lose it, rotate."
                    )
                    setupRunSection
                    section(
                        "1. Add the SSH config",
                        body: plan.sshConfigSnippet,
                        primaryActionTitle: "Insert into ~/.ssh/config",
                        enrollmentAction: .insertSSHConfig,
                        action: { model.requestSSHConfigInsertion() }
                    )
                    // No Run button when the alias is the placeholder: this host
                    // was enrolled before the alias was persisted, so we do not
                    // know where to send a token. Copy still works.
                    section(
                        "2. Install on the host",
                        body: plan.remoteCommands.joined(separator: "\n"),
                        displayedBody: ClaudeIntegrationSettingsModel.redactedRemoteCommands(for: presentation),
                        note: presentation.canRunRemoteSetup
                            ? "The token never enters a process argument on this Mac. On the host it is in the install command arguments while it runs, and stored under ~/.claude after. Rotate if that host is shared."
                            : "Replace \(ClaudeIntegrationSettingsModel.unknownAliasPlaceholder) with the alias from your ~/.ssh/config and run these yourself. This host was enrolled before localvoxtral recorded its alias.",
                        primaryActionTitle: presentation.canRunRemoteSetup ? "Run on SSH host" : nil,
                        enrollmentAction: .runRemoteSetup,
                        action: presentation.canRunRemoteSetup ? { model.requestRemoteSetup() } : nil
                    )
                    section(
                        "3. Show the dictation indicator in herdr",
                        body: ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet,
                        note: "After confirmation, localvoxtral appends this only when no agents table or rows key exists. Otherwise it leaves the file unchanged.",
                        primaryActionTitle: presentation.canRunRemoteSetup ? "Configure on SSH host" : nil,
                        enrollmentAction: .configureHerdrPanel(hostID: presentation.host.id),
                        action: presentation.canRunRemoteSetup
                            ? { model.requestHerdrPanelConfiguration(hostID: presentation.host.id) }
                            : nil
                    )
                    verificationSection
                    section(
                        "Update later",
                        body: plan.updateCommands.joined(separator: "\n"),
                        note: "Re-running step 2 does not update the plugin."
                    )

                    Link("Uninstall or check manually", destination: Self.documentationURL)
                        .font(.body)
                }
            }
            .frame(minHeight: 280)

            HStack {
                if model.isEnrollmentBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Done", action: onDismiss).keyboardShortcut(.defaultAction)
                    .disabled(model.isEnrollmentBusy)
            }
        }
        .padding(18)
        .frame(width: 580, height: 580)
    }

    /// The one flow: every numbered step below, in order, each self-verifying.
    ///
    /// Consent covers the whole run at once — the preview names what lands on
    /// this Mac (the ssh block, the shell block) and what runs on the host —
    /// and the run stops at the first failure with its remedy. The numbered
    /// sections stay for copying each step by hand.
    private var setupRunSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up this host").font(.headline)
            Text("Runs all six steps in order, stopping at the first failure with its remedy.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let action = ClaudeIntegrationSettingsModel.EnrollmentAction.setupHost
            if let confirmation = model.enrollmentConfirmation,
               confirmation.action == action {
                Text(confirmation.preview)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                Text(confirmation.title).font(.body).bold()
                HStack {
                    Button("Cancel") { model.cancelEnrollmentActionConfirmation() }
                    Button(confirmation.confirmButtonTitle) {
                        Task { await model.confirmEnrollmentAction() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("integrations.remote.setup.run")
                }
                .controlSize(.small)
            } else if !model.isEnrollmentBusy {
                // Re-runnable on purpose: a failed run's remedy is usually
                // "fix that, then run it again", and the reset (`setupRun`
                // is cleared by `requestHostSetup`) makes the new run's list
                // replace the old one rather than append to it.
                Button("Run Setup", action: { model.requestHostSetup() })
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(actionsDisabled || !presentation.canRunRemoteSetup)
            }
            ClaudeSetupRunSteps(model: model, hostID: presentation.host.id)
        }
    }

    /// Step 3: the app runs the checks and states the verdict.
    ///
    /// There is nothing to copy here on purpose. The commands this replaced
    /// needed a dozen `#` lines to explain their own output — that a forward
    /// failure can be healthy, that HTTP 401 is the success signal — and a
    /// person still read healthy output as broken (field report 2026-07-26).
    /// Interpretation belongs in code.
    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("4. Check the setup").font(.headline)
            Text(
                presentation.canRunRemoteSetup
                    ? "Runs two read-only checks over SSH. Changes nothing."
                    // Same reason step 2 withholds its button: with no alias on
                    // file, checking the placeholder would report on whatever
                    // machine answers to that name.
                    : "Unavailable until this host's SSH alias is known. localvoxtral did not record one when it was enrolled. Re-enrol it, or run the checks from the linked page yourself."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Check setup") { Task { await model.runVerification() } }
                .controlSize(.small)
                .disabled(actionsDisabled || !presentation.canRunRemoteSetup)
            ForEach(model.verificationChecks) { check in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(check.passed ? "✓" : "✗") \(check.title): \(check.summary)")
                        .font(.body)
                        .foregroundStyle(check.passed ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
                    if let hint = check.hint {
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
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
        note: String? = nil,
        primaryActionTitle: String? = nil,
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
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(displayedBody ?? body)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    pendingConfirmation != nil
                        ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 4)
                )
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let confirmation = pendingConfirmation {
                Text(confirmation.title).font(.body).bold()
                HStack {
                    Button("Cancel") { model.cancelEnrollmentActionConfirmation() }
                    Button(confirmation.confirmButtonTitle) {
                        Task { await model.confirmEnrollmentAction() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    if let primaryActionTitle, let action {
                        Button(primaryActionTitle, action: action)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(actionsDisabled)
                    }
                    Button("Copy") {
                        // Everything in this sheet embeds or accompanies the
                        // enrollment token — concealed, so clipboard managers
                        // and our own clipboard-context harvester skip it (F4).
                        // Copy stays live in a preview: it mutates nothing.
                        ConcealedPasteboardWriter.write(body)
                    }
                    .controlSize(.small)
                }
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
                // time before (docs/agent/field-debugging.md), and version
                // alone can't answer it —
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

                SettingsFieldRow(title: "Issues") {
                    Link(
                        "Report an Issue",
                        destination: URL(string: "https://github.com/T0mSIlver/localvoxtral/issues")!
                    )
                }
            }

            SettingsGroup(title: "Diagnostics") {
                SettingsFieldRow(
                    title: "Report",
                    help: "Writes a redacted report to the Desktop. Review before sharing."
                ) {
                    Button("Export diagnostics…") {
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
    /// When set, the group's header row carries ONE "Learn more" link to this
    /// page (owner review, 2026-09-07): details a row's one-line help can no
    /// longer carry live in the docs, not repeated under every toggle.
    var learnMoreURL: URL?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)

                if let learnMoreURL {
                    Spacer(minLength: 12)
                    Link("Learn more", destination: learnMoreURL)
                        .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

private struct SettingsFieldRow<Content: View, Footer: View>: View {
    let title: String
    /// The secondary explanation. A parameter rather than a view inside
    /// `content`: a row cannot pull a nested view out of its control column, and
    /// the whole point is that this text is NOT in that column.
    ///
    /// This is the STATIC explanation of what the row does, ONE line at
    /// `.callout` (owner review, 2026-09-07: readable size, secondary colour,
    /// never a wall of text — the details live in the docs behind the group's
    /// Learn more link). Anything that changes with the row's state — "Not
    /// set.", a validation error, "Password saved." — belongs in `status` or
    /// `footer:` instead.
    var help: String?
    /// One-line dynamic status, rendered next to the label in the LEADING
    /// column so a row with buttons reads "label + status … [buttons]" on a
    /// single line instead of stacking them into a tall row.
    var status: String?
    /// Drill anchor for `status`, preserved from the stacked layout the rows
    /// used before the horizontal rework.
    var statusAccessibilityIdentifier: String?
    var layout: SettingsFieldRowLayout
    /// How the label sits against the control in an `.inline` row. See
    /// `inlineRow` for why the default is `.center`.
    var controlAlignment: VerticalAlignment
    @ViewBuilder var content: Content
    /// Dynamic per-row status, rendered full-width and LEADING-aligned on its
    /// own line under the control. Not a member of `content`: the control column
    /// is trailing-aligned and only ~200pt wide, so a status sentence placed
    /// there is right-aligned, wraps early, and reads as detached from the row
    /// it describes (PR #201 review).
    @ViewBuilder var footer: Footer
    /// Whether `footer` is a real view. `EmptyView` renders nothing but would
    /// still be a child of the stack; rows built without a footer must lay out
    /// exactly as they did before this slot existed.
    private let hasFooter: Bool

    init(
        title: String,
        help: String? = nil,
        status: String? = nil,
        statusAccessibilityIdentifier: String? = nil,
        layout: SettingsFieldRowLayout = .inline,
        controlAlignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.help = help
        self.status = status
        self.statusAccessibilityIdentifier = statusAccessibilityIdentifier
        self.layout = layout
        self.controlAlignment = controlAlignment
        self.content = content()
        self.footer = footer()
        self.hasFooter = true
    }

    init(
        title: String,
        help: String? = nil,
        status: String? = nil,
        statusAccessibilityIdentifier: String? = nil,
        layout: SettingsFieldRowLayout = .inline,
        controlAlignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) where Footer == EmptyView {
        self.title = title
        self.help = help
        self.status = status
        self.statusAccessibilityIdentifier = statusAccessibilityIdentifier
        self.layout = layout
        self.controlAlignment = controlAlignment
        self.content = content()
        self.footer = EmptyView()
        self.hasFooter = false
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

                // Status first, explanation last: the footer reports what the
                // control above it currently is, so it belongs next to it; the
                // help text explains the row as a whole and closes it.
                if hasFooter {
                    footer
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The row's one-line status. The drill anchor is applied only when the
    /// row names one: an unconditional `.accessibilityIdentifier("")` would
    /// put empty ids in every AX dump.
    @ViewBuilder
    private func statusText(_ text: String) -> some View {
        let base = Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)

        if let statusAccessibilityIdentifier {
            base.accessibilityIdentifier(statusAccessibilityIdentifier)
        } else {
            base
        }
    }

    private var inlineRow: some View {
        // Centered by default, top-aligned only where a row asks for it. The
        // default used to be `.top`, which is right for a tall composite control
        // but wrong for the ~10 rows whose control is a lone switch or picker:
        // the 13pt label's cap then sits above the switch's centerline and reads
        // misaligned against System Settings (PR #201 review). A row with a
        // genuinely tall control passes `controlAlignment: .top`.
        HStack(alignment: controlAlignment, spacing: SettingsLayout.rowSpacing) {
            // "Label + one-line status" on the left (owner review, 2026-09-07):
            // baselines aligned, the status truncates rather than wrapping so a
            // row with buttons stays one line tall.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label

                if let status {
                    statusText(status)
                }
            }
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
        // ONE line, at a readable size (owner review, 2026-09-07): `.callout`
        // in secondary colour, truncating rather than wrapping, so no row can
        // grow a wall of text under its control. What does not fit lives in
        // the docs behind the group's Learn more link.
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsFileNote: Identifiable {
    let id = UUID()
    let name: String
}

private struct SettingsFileNotes: View {
    let notes: [SettingsFileNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(notes) { note in
                Text(note.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
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

/// Preview, then consent, then write — the same shape as the enrollment
/// sheet's ssh-config insert, for the same reason: this edits a file the user
/// owns and did not ask us to touch.
private struct ClaudeShellSetupSheet: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Terminal setup for plain SSH")
                .font(.headline)
                .accessibilityIdentifier("claude.shellSetupSheet.title")
            Text(
                "This adds one block to \(model.shellSetupStatus.relativeRCPath ?? "your shell startup file"), so a Claude Code session over plain SSH can be matched to the window you are dictating into. Open a new terminal window afterwards. The value is fixed when a session starts."
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if let preview = model.shellSetupPreview {
                ScrollView {
                    Text(preview)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("claude.shellSetupSheet.preview")
                }
                .frame(maxHeight: 180)
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("claude.shellSetupSheet.cancel")
                Button("Add to my shell") {
                    Task {
                        await model.applyShellSetup()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.shellSetupPreview == nil)
                .accessibilityIdentifier("claude.shellSetupSheet.apply")
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

/// Preview, then consent, then write — the same shape as the shell setup
/// sheet, for the same reason: this edits a file the user owns and did not
/// ask us to touch. Only ever writes the `statusLine` key; a foreign entry
/// never reaches this sheet (the row offers no button for it).
private struct ClaudeStatuslineSetupSheet: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code status line")
                .font(.headline)
            Text(ClaudeStatuslineInstallService.sheetExplanation)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if let preview = model.statuslinePreview {
                ScrollView {
                    Text(preview)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("integrations.statuslineSheet.preview")
                }
                .frame(maxHeight: 120)
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("integrations.statuslineSheet.cancel")
                Button("Add status line") {
                    Task {
                        await model.applyStatuslineSetup()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.statuslinePreview == nil)
                .accessibilityIdentifier("integrations.statuslineSheet.apply")
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
