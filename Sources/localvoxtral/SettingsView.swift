import AppKit
import SwiftUI

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

    /// Terminal rows, installed-state cache, and the user-added list. Cached
    /// per Settings open (owner decision): the LaunchServices lookups re-run
    /// in `onAppear`, and nothing else consults the system mid-session —
    /// never a running-process check.
    @State private var terminalAppsModel: TerminalAppsSettingsModel

    /// The sidebar's one-line Add app… refusal message. Reset on every open
    /// of the picker.
    @State private var addAppMessage: String?

    init(
        settings: SettingsStore,
        viewModel: DictationViewModel,
        backendManager: BackendManager,
        navigator: SettingsNavigator
    ) {
        self.settings = settings
        self.viewModel = viewModel
        self.backendManager = backendManager
        self.navigator = navigator
        _terminalAppsModel = State(
            initialValue: TerminalAppsSettingsModel(
                settings: settings,
                isCmuxSocketSetUp: { [weak viewModel] in
                    guard let claude = viewModel?.claudeIntegrationSettings else { return false }
                    return settings.cmuxSurfaceJoinEnabled && claude.hasCmuxPassword
                }
            )
        )
    }

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
            SettingsSidebarView(
                selection: $navigator.selectedTab,
                terminalApps: terminalAppsModel.terminalApps,
                statusDot: sidebarDot,
                addTerminalApp: chooseAndAddTerminalApp,
                addAppMessage: $addAppMessage
            )

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
        // Per Settings open (owner decision): the terminal rows' installed
        // cache and the Integrations dots' statuses refresh with the window,
        // not per pane — a dot is on the sidebar, which is visible on every
        // pane.
        .onAppear {
            terminalAppsModel.refreshInstalledState()
            if let claude = viewModel.claudeIntegrationSettings {
                Task { await claude.refreshIntegrationsStatuses() }
            }
        }
    }

    /// The dot each sidebar row trails (owner decision, 2026-09-07). Nil for
    /// the main panes and About — they have no install state to report.
    private func sidebarDot(for tab: SettingsTab) -> SettingsStatusDot? {
        switch tab.kind {
        case .integrationsContext:
            let anyConsent = settings.repoVocabularyEnabled
                || settings.terminalScreenContextEnabled
                || settings.claudeRepoContextEnabled
                || settings.polishClipboardContextEnabled
                || settings.polishContextTrustedEndpointEnabled
            return IntegrationsSidebarStatus.contextDot(anyConsentEnabled: anyConsent)
        case .integrationsClaude:
            return IntegrationsSidebarStatus.claudeDot(
                pluginStatus: viewModel.claudeIntegrationSettings?.localPluginStatus ?? .unknown
            )
        case .integrationsOpencode:
            return IntegrationsSidebarStatus.opencodeDot(
                status: viewModel.claudeIntegrationSettings?.opencodeStatus ?? .unknown
            )
        case .integrationsHerdr:
            return IntegrationsSidebarStatus.herdrDot(
                isDetected: viewModel.claudeIntegrationSettings?.isHerdrDetected ?? false
            )
        case .terminal:
            guard let app = tab.terminalApp else { return nil }
            return terminalAppsModel.dot(for: app)
        case .general, .dictation, .endpoints, .textProcessing, .about:
            return nil
        }
    }

    /// The Terminals section's Add app… action: an `NSOpenPanel` filtered to
    /// applications (owner decision). The chosen app's bundle id and display
    /// name go into settings; a refusal leaves one short line under the
    /// section (owner rule: never more than a sentence in chrome).
    private func chooseAndAddTerminalApp() {
        addAppMessage = nil
        let panel = NSOpenPanel()
        panel.title = "Add a terminal app"
        panel.message = "Choose an application localvoxtral should treat as a terminal."
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard
            let bundle = Bundle(url: url),
            let bundleID = bundle.bundleIdentifier,
            !bundleID.trimmed.isEmpty
        else {
            Log.config.error(
                "Add app: no readable bundle id in \(url.lastPathComponent, privacy: .public)"
            )
            addAppMessage = "That app has no readable bundle id."
            return
        }
        let displayName =
            (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)?.trimmed
            ?? url.deletingPathExtension().lastPathComponent
        if terminalAppsModel.addUserApp(bundleID: bundleID, displayName: displayName) {
            navigator.selectedTab = SettingsTab.terminal(
                TerminalAppsSettingsModel.descriptor(
                    for: UserTerminalApp(bundleID: bundleID, displayName: displayName)
                ))
        } else {
            addAppMessage = "That app is already listed."
        }
    }

    /// Header + the selected pane. No transition/animation on the swap: pane
    /// content is dense, and cross-fading it reads as a flicker.
    private var detailColumn: some View {
        VStack(spacing: 0) {
            SettingsPaneHeader(tab: navigator.selectedTab)

            Divider()

            switch navigator.selectedTab.kind {
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
            case .integrationsContext:
                IntegrationsContextSettingsPane(settings: settings, viewModel: viewModel)
            case .integrationsClaude:
                ClaudeCodeSettingsPane(settings: settings, viewModel: viewModel)
            case .integrationsOpencode:
                OpencodeSettingsPane(viewModel: viewModel)
            case .integrationsHerdr:
                HerdrSettingsPane(viewModel: viewModel)
            case .terminal:
                if let app = navigator.selectedTab.terminalApp {
                    TerminalSettingsPane(
                        app: app,
                        model: terminalAppsModel,
                        onRemove: removeUserTerminalApp
                    )
                }
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

/// The consent toggles — everything that lets something OTHER than your
/// spoken words reach the polisher (owner decision, 2026-09-07: its own pane
/// under the Integrations section).
///
/// Split out of Text Processing (2026-08-04): these are consent-grade toggles
/// whose help text is the consent, and they were being read past as formatting
/// options next to "Exact match". The group here is STATIC — a toggle
/// switches a group's content, never the number or identity of the groups
/// (owner rule, 2026-07-04).
///
/// Copy rule (owner review, 2026-09-07): each toggle's help is ONE line
/// stating what leaves the machine — the consequence, nothing else. The full
/// terms live in `docs/coding-agents.md` behind the group's Learn more link.
private struct IntegrationsContextSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel

    /// Where the group's Learn more link lands. Repo pages, not relative
    /// links: Settings is a shipped app, not a doc site.
    private enum LearnMore {
        static let polishContext = URL(
            string:
                "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/coding-agents.md#polish-context-what-each-toggle-sends"
        )!
    }

    /// Same gate as the Text Processing polishing rows: context is only ever
    /// harvested for an Overlay Buffer dictation, so with no shortcut recorded
    /// for one, none of these sources can run.
    private var isLLMPolishingReachable: Bool {
        settings.isOverlayBufferSessionReachable
    }

    var body: some View {
        SettingsPage(tab: .integrationsContext) {
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
                        help: "Sends a capped excerpt of your clipboard to the polisher."
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
        }
    }
}

/// Everything Claude-Code-related in one place (owner decision, 2026-09-07):
/// the plugin row, the status-line row, the cmux join toggle + password, and
/// the Remote hosts group (enrolled hosts, Add host, shell setup).
private struct ClaudeCodeSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel

    /// Where each group's Learn more link lands. Repo pages, not relative
    /// links: Settings is a shipped app, not a doc site.
    private enum LearnMore {
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

    var body: some View {
        SettingsPage(tab: .integrationsClaude) {
            SettingsGroup(title: "Claude Code", learnMoreURL: LearnMore.claudeCode) {
                if let claude = viewModel.claudeIntegrationSettings {
                    ClaudePluginInstallRow(model: claude)
                    ClaudeStatuslineRow(model: claude)
                }

                // Not on the Context pane: this is a JOIN arm — it decides
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
            // groups always have their rows.
            SettingsGroup(title: "Remote hosts", learnMoreURL: LearnMore.remoteHosts) {
                if let claude = viewModel.claudeIntegrationSettings {
                    ClaudeRemoteHostsSettingsRow(model: claude)
                }
            }
        }
        .onAppear {
            if isEnrollmentSheetPreviewArmed,
               let claude = viewModel.claudeIntegrationSettings {
                claude.presentPreviewPlan()
            }
        }
    }
}

/// The opencode pane (owner decision, 2026-09-07): the install row plus one
/// sentence on what an installed plugin gets.
private struct OpencodeSettingsPane: View {
    let viewModel: DictationViewModel

    var body: some View {
        SettingsPage(tab: .integrationsOpencode) {
            SettingsGroup(title: "opencode") {
                if let claude = viewModel.claudeIntegrationSettings {
                    OpencodePluginRow(model: claude)
                }

                SettingsFieldRow(
                    title: "What it gets",
                    help: "Dictation joins the focused opencode session and polishes with its prompt and touched files."
                ) {
                    EmptyView()
                }
            }
        }
    }
}

/// The herdr pane (owner decision, 2026-09-07): status sentence, and the
/// enrolled-host names when any enrolled host reports a herdr pane. herdr
/// needs no setup — the row is status-only, and the dot is green whenever
/// herdr is found.
private struct HerdrSettingsPane: View {
    let viewModel: DictationViewModel

    var body: some View {
        SettingsPage(tab: .integrationsHerdr) {
            SettingsGroup(title: "herdr") {
                SettingsFieldRow(
                    title: "Status",
                    status: herdrSentence,
                    statusAccessibilityIdentifier: "integrations.herdr.status"
                ) {
                    EmptyView()
                }

                if !herdrPaneHostLabels.isEmpty {
                    SettingsFieldRow(
                        title: "Hosts reporting a herdr pane",
                        help: herdrPaneHostLabels.joined(separator: ", ")
                    ) {
                        EmptyView()
                    }
                }
            }
        }
    }

    private var claude: ClaudeIntegrationSettingsModel? {
        viewModel.claudeIntegrationSettings
    }

    private var herdrSentence: String {
        guard let claude else { return "Not found." }
        return claude.isHerdrDetected
            ? ClaudeIntegrationSettingsModel.herdrDetectedSentence
            : "Not found."
    }

    private var herdrPaneHostLabels: [String] {
        claude?.herdrPaneHostLabels ?? []
    }
}

/// One terminal's pane (owner decision, 2026-09-07): the status sentence that
/// explains the row's dot, the capabilities as three short rows, the cmux
/// socket-mode instruction, and — for a user-added app — removal.
///
/// Group structure is constant per pane (owner rule, 2026-07-04): Status,
/// then Capabilities. cmux's socket row is present whenever its pane is; a
/// user app's Remove row likewise.
private struct TerminalSettingsPane: View {
    let app: TerminalAppDescriptor
    @Bindable var model: TerminalAppsSettingsModel
    /// Removal is owned by the pane's caller: it also has to move the
    /// selection off the pane that is about to disappear.
    let onRemove: (String) -> Void

    var body: some View {
        SettingsPage(tab: .terminal(app)) {
            SettingsGroup(title: "Status") {
                SettingsFieldRow(
                    title: app.displayName,
                    status: model.dot(for: app).terminalSentence,
                    statusAccessibilityIdentifier: "terminals.\(app.slug).status"
                ) {
                    EmptyView()
                }

                if app.isUserAdded {
                    SettingsFieldRow(
                        title: "Added app",
                        help: "Treated as a terminal for dictation and the agent prompt profile."
                    ) {
                        Button("Remove") {
                            onRemove(app.detectionBundleIDs.first ?? "")
                        }
                        .accessibilityIdentifier("terminals.\(app.slug).remove")
                    }
                }
            }

            SettingsGroup(title: "Capabilities") {
                capabilityRow(title: "Dictation", supported: true, reason: nil)

                let verdicts = model.capabilityVerdicts(for: app)
                capabilityRow(
                    title: "Session join",
                    supported: verdicts.join,
                    reason: verdicts.joinReason
                )
                capabilityRow(
                    title: "Screen context",
                    supported: verdicts.screen,
                    reason: verdicts.screenReason
                )

                // cmux's socket-mode instruction, one line with a docs link
                // (owner decision): the two-step setup lives in the plugin
                // README, not in the pane.
                if app.slug == "cmux" {
                    SettingsFieldRow(
                        title: "Socket mode",
                        help: TerminalAppCatalog.cmuxSocketReason
                    ) {
                        Link("How to set up", destination: TerminalAppCatalog.cmuxDocsURL)
                    }
                }
            }
        }
    }

    /// One capability row: "Yes", or "No" plus the one-line reason (e.g.
    /// "Ghostty 1.4 or newer needed.").
    private func capabilityRow(
        title: String,
        supported: Bool,
        reason: String?
    ) -> some View {
        SettingsFieldRow(
            title: title,
            help: supported ? nil : reason
        ) {
            Text(supported ? "Yes" : "No")
        }
    }
}

/// Removing the user-added app whose pane is open: the settings write is the
/// model's; the selection has to leave with the pane.
private extension SettingsView {
    func removeUserTerminalApp(bundleID: String) {
        terminalAppsModel.removeUserApp(bundleID: bundleID)
        navigator.selectedTab = .general
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
                        .disabled(!model.canApplyStatuslineSetup)
                        .accessibilityIdentifier("integrations.claude.statusline.install")
                case .installed, .stalePath:
                    Button("Update…") { isShowingSetup = true }
                        .disabled(
                            model.isPerformingStatuslineAction || !model.canApplyStatuslineSetup
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
/// Installation is confirmed in a consent sheet because it writes both the
/// plugin and the user's `tui.json`. Failures report one short line here and
/// the detail in an alert (owner rule).
private struct OpencodePluginRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    @State private var isShowingSetup = false

    var body: some View {
        // One line like the Claude Code rows above.
        SettingsFieldRow(
            title: "opencode",
            status: model.opencodeResult ?? model.opencodeSentence,
            statusAccessibilityIdentifier: "integrations.opencode.status"
        ) {
            HStack(spacing: 8) {
                Button(model.opencodeStatus == .notInstalled ? "Set up…" : "Update…") {
                    isShowingSetup = true
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
        .sheet(isPresented: $isShowingSetup) {
            OpencodePluginSetupSheet(model: model) { isShowingSetup = false }
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

/// Enrolled SSH hosts and their automated setup flow.
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

    /// The plain-ssh join's one setup step: title + status leading, the small
    /// buttons trailing on the TITLE'S line (the outer stack is
    /// baseline-aligned, so a wrapped status never drags the buttons down).
    /// The status may wrap to a SECOND line rather than truncate — the
    /// crossing sentence ("Open a new terminal window for it to take
    /// effect.") is an instruction, and an instruction must never be
    /// ellipsized (owner rule, PR #282 review). The two facts the status
    /// carries (is the export in the rc file; has a new session arrived
    /// carrying it) stay separate texts for the drills, separated by a
    /// middle dot. Nothing is written until the consent sheet's Set Up.
    @ViewBuilder
    private var shellSetup: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                // Two lines, not an ellipsis: lineLimit(2) lets the status
                // wrap, fixedSize(horizontal: false, vertical: true) lets the
                // row actually grow to the wrapped height inside the stack.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if model.shellSetupStatus.rc == .applied {
                Button("Remove") { Task { await model.removeShellSetup() } }
                    .controlSize(.small)
                    .accessibilityIdentifier("claude.remote.shellSetup.remove")
            }
            Button("Set up…") { isShowingShellSetup = true }
                .controlSize(.small)
                .disabled(!model.canApplyShellSetup)
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
                            // Labels run to the registry's 64-character cap:
                            // one line, truncating from the middle so head and
                            // tail stay readable, at a priority BELOW the
                            // status — a long name must never squeeze
                            // "Last context: …" off its full line.
                            Text(host.label)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(0)

                            // Rendered by the model against its injected clock —
                            // "Last context: 2 min ago" — and refreshed with the
                            // rest of the section. A tunnel that quietly stopped
                            // delivering context is otherwise invisible here.
                            Text(host.statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .layoutPriority(1)
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

    /// One host's automated update, kept inside that host's row.
    @ViewBuilder
    private func pluginUpdatePanel(for host: ClaudeIntegrationSettingsModel.HostRow) -> some View {
        if let update = model.presentedPluginUpdate, update.hostID == host.id {
            VStack(alignment: .leading, spacing: 4) {
                Text("Update \(host.label)").font(.caption).bold()
                if let alias = update.sshHostAlias {
                    Text(model.hostSetupConsentSentence(sshHostAlias: alias))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Details", destination: Self.remoteSetupDocumentationURL)
                        .font(.caption)
                    if !model.isEnrollmentBusy {
                        HStack(spacing: 8) {
                            Button("Cancel") { model.dismissPluginUpdate() }
                                .controlSize(.small)
                            Button("Set Up") {
                                Task {
                                    model.requestHostUpdateRun()
                                    await model.confirmEnrollmentAction()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier("integrations.remote.setup.run")
                        }
                    }
                } else {
                    Text("Re-enroll this host before updating it because its SSH alias was not recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Cancel") { model.dismissPluginUpdate() }
                            .controlSize(.small)
                        Link("Details", destination: Self.remoteSetupDocumentationURL)
                            .font(.caption)
                    }
                }
                ClaudeSetupRunSteps(model: model, hostID: host.id)
            }
            .padding(.leading, 8)
            .padding(.bottom, 4)
        }
    }

    private static let remoteSetupDocumentationURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/remote-claude-context.md"
    )!

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
            // Wrap, never truncate — the remedy is an instruction ("Quit it
            // and press Retry."), same rule as the shell-setup crossing
            // sentence (PR #282 review).
            Text(remedy)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
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
        let activeRun = model.setupRun.flatMap { $0.hostID == hostID ? $0 : nil }
        let items = activeRun?.items ?? RemoteHostSetupRun.Step.allCases.map {
            RemoteHostSetupRun.Item(step: $0, state: .pending)
        }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
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
        if activeRun != nil, model.isEnrollmentBusy {
            Button("Cancel") { model.cancelSetupRun() }
                .controlSize(.small)
                .accessibilityIdentifier("integrations.remote.setup.cancel")
        }
        if activeRun != nil, let manual = model.setupManualInstructions {
            Text(manual)
                .font(.caption)
                .foregroundStyle(.secondary)
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

/// One consent sentence and the six-step automated setup run.
private struct ClaudeRemoteEnrollmentSheet: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    let presentation: ClaudeIntegrationSettingsModel.EnrollmentPresentation
    let onDismiss: () -> Void

    private static let documentationURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/remote-claude-context.md"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(presentation.isRotation ? "Set up \(presentation.host.label) again" : "Set up \(presentation.host.label)")
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
                Text("The previous token stopped working immediately. Set up this host to restore access.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Text(model.hostSetupConsentSentence(sshHostAlias: presentation.sshHostAlias))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Link("Details", destination: Self.documentationURL)
                .font(.body)

            ScrollView {
                ClaudeSetupRunSteps(model: model, hostID: presentation.host.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 280)

            HStack {
                if model.isEnrollmentBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if !model.isEnrollmentBusy {
                    Button("Cancel", action: onDismiss)
                        .accessibilityIdentifier("integrations.remote.setup.cancel")
                    if presentation.canRunRemoteSetup {
                        Button("Set Up") {
                            Task {
                                model.requestHostSetup()
                                await model.confirmEnrollmentAction()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(presentation.isPreview)
                        .accessibilityIdentifier("integrations.remote.setup.run")
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 520, height: 500)
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

/// Consent for the shell startup edit.
private struct ClaudeShellSetupSheet: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    var dismiss: () -> Void

    private static let documentationURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/remote-claude-context.md"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Terminal setup for plain SSH")
                .font(.headline)
                .accessibilityIdentifier("claude.shellSetupSheet.title")
            Text(model.shellSetupConsentSentence)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Link("Details", destination: Self.documentationURL)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("claude.shellSetupSheet.cancel")
                Button("Set Up") {
                    Task {
                        await model.applyShellSetup()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canApplyShellSetup)
                .accessibilityIdentifier("claude.shellSetupSheet.apply")
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

/// Consent for the Claude Code status-line edit.
private struct ClaudeStatuslineSetupSheet: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    var dismiss: () -> Void

    private static let documentationURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/integrations/claude-code/README.md#connection-indicator-opt-in-status-line"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code status line")
                .font(.headline)
            Text(ClaudeStatuslineInstallService.consentSentence)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Link("Details", destination: Self.documentationURL)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("integrations.statuslineSheet.cancel")
                Button("Set Up") {
                    Task {
                        await model.applyStatuslineSetup()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canApplyStatuslineSetup)
                .accessibilityIdentifier("integrations.statuslineSheet.apply")
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

/// Consent for the opencode plugin files.
private struct OpencodePluginSetupSheet: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    var dismiss: () -> Void

    private static let documentationURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/integrations/opencode/README.md#install"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("opencode plugin")
                .font(.headline)
            Text(OpencodePluginInstallService.consentSentence)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Link("Details", destination: Self.documentationURL)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("integrations.opencodeSheet.cancel")
                Button("Set Up") {
                    Task {
                        await model.installOpencodePlugin()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("integrations.opencodeSheet.apply")
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
