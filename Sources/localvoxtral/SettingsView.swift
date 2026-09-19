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

    /// Terminal rows, installed-state cache, and the user-added list. The
    /// LaunchServices sweep runs in `onAppear` — ONCE per Settings open (owner
    /// decision) — and the cache then lives for the window's lifetime;
    /// nothing else consults the system mid-session, never a
    /// running-process check.
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

            // No hairline between the columns: the sidebar's gray against the
            // detail column's white is the separation.
            detailColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Both columns run under the transparent titlebar, so the sidebar's
        // fill reaches the window's top edge. `SettingsSidebarMetrics.topInset`
        // clears the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .background {
            SettingsWindowChrome()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        // Per Settings open (owner decision): the terminal rows' installed
        // cache refreshes with the window, not per pane — a dot is on the
        // sidebar, which is visible on every pane. This onAppear is the
        // sweep's single home (the model's construction deliberately runs no
        // LaunchServices lookups — see `refreshInstalledState`); the
        // Integrations statuses are async work, which is why they refresh
        // here rather than at construction.
        .onAppear {
            // The API-key fields below show what is stored, so opening
            // Settings is the moment the app reads every key — the engine
            // panes are the only place all three are displayed at once, and
            // a read the user did not ask for can cost them a keychain
            // prompt (`SettingsStore.ensureSecretsLoaded`).
            settings.ensureAllSecretsLoaded()
            terminalAppsModel.refreshInstalledState()
            if let claude = viewModel.claudeIntegrationSettings {
                Task { await claude.refreshIntegrationsStatuses() }
            }
        }
        .modifier(ClaudeIntegrationPresentations(model: viewModel.claudeIntegrationSettings))
    }

    /// The dot each sidebar row trails (owner decision, 2026-09-07). Nil for
    /// the main panes and About — they have no install state to report.
    private func sidebarDot(for tab: SettingsTab) -> SettingsStatusDot? {
        switch tab.kind {
        case .integrationsRemote:
            return IntegrationsSidebarStatus.remoteHostsDot(
                activeHostCount: viewModel.claudeIntegrationSettings?.hosts
                    .filter { !$0.isRevoked }.count ?? 0
            )
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
        // The app's own panes carry no dot: a dot means "detected / set up"
        // for something outside the app (a harness, a terminal, a host).
        // Context sits among them since PR #310, so its consents are shown
        // by the pane's toggles, not by the row.
        case .general, .dictation, .endpoints, .textProcessing, .integrationsContext, .about:
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
        let outcome = terminalAppsModel.addUserApp(bundleID: bundleID, displayName: displayName)
        if outcome.added {
            navigator.selectedTab = SettingsTab.terminal(
                TerminalAppsSettingsModel.descriptor(
                    for: UserTerminalApp(bundleID: bundleID, displayName: displayName)
                ))
        } else if let refusalSentence = outcome.refusalSentence {
            // One short sentence under the section (owner rule); the log
            // carries the detail.
            addAppMessage = refusalSentence
        }
    }

    /// Header + the selected pane. No transition/animation on the swap: pane
    /// content is dense, and cross-fading it reads as a flicker.
    private var detailColumn: some View {
        VStack(spacing: 0) {
            SettingsPaneHeader(tab: navigator.selectedTab)

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
                ClaudeCodeSettingsPane(viewModel: viewModel)
            case .integrationsOpencode:
                OpencodeSettingsPane(viewModel: viewModel)
            case .integrationsHerdr:
                HerdrSettingsPane(viewModel: viewModel)
            case .integrationsRemote:
                RemoteHostsSettingsPane(viewModel: viewModel)
            case .terminal:
                if let app = navigator.selectedTab.terminalApp {
                    TerminalSettingsPane(
                        app: app,
                        model: terminalAppsModel,
                        settings: settings,
                        claude: viewModel.claudeIntegrationSettings,
                        onRemove: removeUserTerminalApp
                    )
                }
            case .about:
                AboutSettingsPane(settings: settings, viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SettingsLayout.detailBackground)
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
    static let cornerRadius: CGFloat = 10
    /// The detail column's ground: white in light mode, near-black in dark,
    /// so the gray sidebar and the gray group cards read against it.
    static let detailBackground = Color(nsColor: .textBackgroundColor)
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

    private var mistralDictationModelEntries: [MistralModelPickerEntry] {
        MistralModelCatalog.pickerEntries(
            for: .dictation,
            catalog: settings.mistralModelCatalog,
            storedModel: settings.mistralDictationModel,
            defaultModel: MistralRealtimeWebSocketClient.defaultModel
        )
    }

    private var mistralPolishingModelEntries: [MistralModelPickerEntry] {
        MistralModelCatalog.pickerEntries(
            for: .polishing,
            catalog: settings.mistralModelCatalog,
            storedModel: settings.mistralPolishingModel,
            defaultModel: MistralPolishDefaults.model
        )
    }

    private var mistralDictationModelBinding: Binding<String> {
        Binding(
            get: {
                MistralModelCatalog.selectionTag(
                    storedModel: settings.mistralDictationModel,
                    catalog: settings.mistralModelCatalog,
                    defaultModel: MistralRealtimeWebSocketClient.defaultModel
                )
            },
            set: { settings.mistralDictationModel = $0 }
        )
    }

    private var mistralPolishingModelBinding: Binding<String> {
        Binding(
            get: {
                MistralModelCatalog.selectionTag(
                    storedModel: settings.mistralPolishingModel,
                    catalog: settings.mistralModelCatalog,
                    defaultModel: MistralPolishDefaults.model
                )
            },
            set: { settings.mistralPolishingModel = $0 }
        )
    }

    /// Changes when the pickers could show a different list: a new key, or an
    /// engine switched onto Mistral.
    private var mistralModelListTrigger: String {
        let usesMistral =
            settings.dictationBackendMode == .mistralAPI
            || settings.polishingBackendMode == .mistralAPI
        return usesMistral ? settings.trimmedMistralAPIKey : ""
    }

    private enum LearnMore {
        static let mistralAPI = URL(
            string:
                "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/under-the-hood.md#mistral-api"
        )!
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

                    SettingsFieldRow(
                        title: "API key",
                        status: settings.secretStoreFailureSummary,
                        statusAccessibilityIdentifier: "engines.dictation.apiKey.status"
                    ) {
                        SecureField("Required for remote providers", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: SettingsLayout.textFieldWidth)
                    }
                case .mistralAPI:
                    MistralModelPickerRow(
                        entries: mistralDictationModelEntries,
                        selection: mistralDictationModelBinding,
                        status: viewModel.mistralModelListState.statusLine,
                        identifier: "engines.dictation.mistralModel"
                    )

                    SettingsFieldRow(title: "Status") {
                        MistralConfigurationStatusLabel(
                            summary: settings.mistralAPIStatusSummary,
                            isConfigured: settings.isMistralAPIConfigured
                        )
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
                        status: backendManager.speechdStatus,
                        identifierPrefix: "engines.dictation",
                        onPause: { viewModel.pauseManagedModelDownload(for: BackendCatalog.speechd) },
                        onResume: { viewModel.resumeManagedModelDownload(for: BackendCatalog.speechd) },
                        onCancel: { viewModel.cancelManagedModelDownload(for: BackendCatalog.speechd) }
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

                    SettingsFieldRow(
                        title: "API key",
                        status: settings.secretStoreFailureSummary,
                        statusAccessibilityIdentifier: "engines.polishing.apiKey.status"
                    ) {
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
                case .mistralAPI:
                    MistralModelPickerRow(
                        entries: mistralPolishingModelEntries,
                        selection: mistralPolishingModelBinding,
                        status: viewModel.mistralModelListState.statusLine,
                        identifier: "engines.polishing.mistralModel"
                    )

                    SettingsFieldRow(title: "Status") {
                        MistralConfigurationStatusLabel(
                            summary: settings.mistralAPIStatusSummary,
                            isConfigured: settings.isMistralAPIConfigured
                        )
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
                        status: backendManager.polishdStatus,
                        identifierPrefix: "engines.polishing",
                        onPause: { viewModel.pauseManagedModelDownload(for: BackendCatalog.polishd) },
                        onResume: { viewModel.resumeManagedModelDownload(for: BackendCatalog.polishd) },
                        onCancel: { viewModel.cancelManagedModelDownload(for: BackendCatalog.polishd) }
                    )
                }
            }

            // Always present, and its content never changes with a mode: this
            // is the provider ACCOUNT, not one engine's configuration. Both
            // pickers above can point at it, one, or neither.
            SettingsGroup(title: "Mistral API", learnMoreURL: LearnMore.mistralAPI) {
                SettingsFieldRow(
                    title: "API key",
                    status: settings.secretStoreFailureSummary,
                    statusAccessibilityIdentifier: "engines.mistral.apiKey.status"
                ) {
                    SecureField(
                        "Paste a key from console.mistral.ai",
                        text: $settings.mistralAPIKey
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: SettingsLayout.textFieldWidth)
                    .accessibilityIdentifier("engines.mistral.apiKey")
                }

                SettingsFieldRow(
                    title: "Verify",
                    status: viewModel.mistralAPIKeyCheckState.statusLine,
                    statusAccessibilityIdentifier: "engines.mistral.verify.status"
                ) {
                    Button("Check key") { viewModel.checkMistralAPIKey() }
                        .disabled(
                            !settings.isMistralAPIConfigured
                                || viewModel.mistralAPIKeyCheckState.isChecking
                        )
                        .accessibilityIdentifier("engines.mistral.verify")
                }

                SettingsFieldRow(title: "Quick setup") {
                    Button("Use Mistral for dictation and polishing") {
                        viewModel.applyMistralQuickSetup(apiKey: settings.mistralAPIKey)
                    }
                    .disabled(!settings.isMistralAPIConfigured)
                    .accessibilityIdentifier("engines.mistral.quickSetup")
                }

                MistralUsageRow(viewModel: viewModel)
            }
        }
        .task(id: mistralModelListTrigger) {
            guard !mistralModelListTrigger.isEmpty else { return }
            viewModel.refreshMistralModelCatalog()
        }
    }
}

/// What the Mistral requests made from this Mac cost over a chosen window,
/// estimated from list prices in the local ledger.
private struct MistralUsageRow: View {
    let viewModel: DictationViewModel
    @AppStorage("mistralUsagePeriod") private var periodRawValue =
        MistralUsagePeriod.thirtyDays.rawValue

    private var period: Binding<MistralUsagePeriod> {
        Binding(
            get: { MistralUsagePeriod(rawValue: periodRawValue) ?? .thirtyDays },
            set: { periodRawValue = $0.rawValue }
        )
    }

    private var summary: MistralUsageSummary {
        // Read so a ledger write re-renders the row.
        _ = viewModel.mistralUsageRevision
        return viewModel.mistralUsageLedger?.summary(for: period.wrappedValue)
            ?? MistralUsageSummary()
    }

    var body: some View {
        let summary = summary
        SettingsFieldRow(
            title: "Usage",
            status: summary.line,
            statusAccessibilityIdentifier: "engines.mistral.usage.status"
        ) {
            Picker("", selection: period) {
                ForEach(MistralUsagePeriod.allCases) { period in
                    Text(period.label).tag(period)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("engines.mistral.usage.period")
        } footer: {
            if let note = summary.unpricedNote {
                SettingsHelpText(note)
            }
        }
    }
}

/// A Mistral engine's model menu: the default first, then Mistral's own
/// models, then partner models under their maker's name.
private struct MistralModelPickerRow: View {
    let entries: [MistralModelPickerEntry]
    let selection: Binding<String>
    let status: String?
    let identifier: String

    var body: some View {
        SettingsFieldRow(
            title: "Model",
            status: status,
            statusAccessibilityIdentifier: "\(identifier).status"
        ) {
            Picker("", selection: selection) {
                ForEach(MistralModelCatalog.Section.allCases, id: \.self) { section in
                    let rows = entries.filter { $0.section == section }
                    if !rows.isEmpty {
                        Section(section.rawValue) {
                            ForEach(rows) { entry in
                                Text(entry.label).tag(entry.tag)
                            }
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier(identifier)
            // Capped so a long model name cannot squeeze the label, and
            // trailing like every other menu in the pane: the cap's frame
            // centres its content otherwise.
            .frame(maxWidth: SettingsLayout.textFieldWidth, alignment: .trailing)
        }
    }
}

/// The Mistral engines' one-line readiness. Dimmed while unconfigured, so the
/// pane reads at a glance without a second colour vocabulary beside the managed
/// engines' status light.
private struct MistralConfigurationStatusLabel: View {
    let summary: String
    let isConfigured: Bool

    var body: some View {
        Text(summary)
            .font(.caption)
            .foregroundStyle(isConfigured ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
    }
}

/// A managed engine's readiness, plus the controls for the model download it
/// starts on its own. `identifierPrefix` namespaces those controls per engine
/// ("engines.dictation" / "engines.polishing"); the rest of the row is
/// identical for both.
struct ManagedBackendStatusRow: View {
    let title: String
    let status: ManagedBackendStatus
    let identifierPrefix: String
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    var body: some View {
        SettingsFieldRow(title: title) {
            HStack(spacing: 8) {
                ManagedBackendStatusLabel(status: status)
                ManagedBackendDownloadControls(
                    status: status,
                    identifierPrefix: identifierPrefix,
                    onPause: onPause,
                    onResume: onResume,
                    onCancel: onCancel
                )
            }
        }
    }
}

/// Pause/Resume/Cancel for the automatic model download. Present only while
/// there is a download to act on, so a ready or failed engine's row looks
/// exactly as it did before.
private struct ManagedBackendDownloadControls: View {
    let status: ManagedBackendStatus
    let identifierPrefix: String
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    var body: some View {
        switch status {
        case .preparingModel:
            button("Pause", identifier: "\(identifierPrefix).download.pause", action: onPause)
            button("Cancel", identifier: "\(identifierPrefix).download.cancel", action: onCancel)
        case .pausedModelDownload:
            button("Resume", identifier: "\(identifierPrefix).download.resume", action: onResume)
            button("Cancel", identifier: "\(identifierPrefix).download.cancel", action: onCancel)
        case .starting, .ready, .stopped, .failed:
            EmptyView()
        }
    }

    private func button(
        _ title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier(identifier)
    }
}

struct ManagedBackendStatusLabel: View {
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
            // A paused download keeps its bar — the bytes are still there and
            // resuming continues from them — but never the spinner, which would
            // claim movement that has stopped.
            switch status {
            case .preparingModel(let progress):
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 54)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            case .pausedModelDownload(let progress):
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 54)
                }
            case .starting, .ready, .stopped, .failed:
                EmptyView()
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
        case .pausedModelDownload(let progress):
            guard let totalBytes = progress.totalBytes, totalBytes > 0 else {
                return "Paused"
            }
            let downloaded = min(progress.downloadedBytes, totalBytes)
            return "Paused, \(Self.byteText(downloaded)) of \(Self.byteText(totalBytes))"
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
        // Paused reads as inactive, like stopped: orange is this pane's
        // "something is running" colour and nothing is.
        case .stopped, .pausedModelDownload:
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
    /// The slider works in `Double`; the setting is a whole line count.
    private var overlayBufferVisibleLinesBinding: Binding<Double> {
        Binding(
            get: { Double(settings.overlayBufferVisibleLines) },
            set: { settings.overlayBufferVisibleLines = Int($0.rounded()) }
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
                    SettingsFieldRow(
                        title: "Modifier key",
                        help: "Tap for Overlay Buffer, hold for Live Auto-Paste."
                    ) {
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

            SettingsGroup(title: "Output") {
                SettingsFieldRow(title: "Menu bar mode") {
                    Picker("", selection: dictationOutputModeBinding) {
                        ForEach(DictationOutputMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                SettingsFieldRow(title: "Copy on stop") {
                    Toggle("", isOn: $settings.autoCopyEnabled)
                        .labelsHidden()
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

                SettingsFieldRow(title: "Lines before scrolling") {
                    HStack(spacing: 8) {
                        Slider(
                            value: overlayBufferVisibleLinesBinding,
                            in: Double(OverlayLayoutMetrics.minimumVisibleLines)
                                ... Double(OverlayLayoutMetrics.maximumVisibleLines),
                            step: 1
                        )
                        .frame(width: SettingsLayout.sliderWidth)

                        Text("\(settings.overlayBufferVisibleLines)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }
}

private struct TextProcessingSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel

    static let speakerProfileExample = """
        Backend engineer at Acme, mostly Swift and Python.
        • Names I say a lot: Qwen, Claude Code, vLLM, Ghostty
        """

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
            SettingsGroup(title: "About you") {
                SettingsFieldRow(
                    title: "In your words",
                    layout: .stacked
                ) {
                    TextEditor(text: $settings.polishSpeakerProfile)
                        .font(.body)
                        .frame(height: 96)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .overlay(alignment: .topLeading) {
                            if settings.polishSpeakerProfile.isEmpty {
                                // TextEditor has no prompt of its own. The
                                // 5pt inset is NSTextView's line-fragment
                                // padding, so the example sits where typed
                                // text will.
                                Text(Self.speakerProfileExample)
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor))
                        )
                        .accessibilityIdentifier("settings.aboutYou.profile")
                } footer: {
                    if settings.polishSpeakerProfile.count
                        > LLMPromptTemplates.speakerProfileMaxCharacters
                    {
                        Text("Only the first \(LLMPromptTemplates.speakerProfileMaxCharacters) characters are sent.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsFieldRow(
                    title: "Names and terms",
                    layout: .stacked
                ) {
                    SpeakerTermsField(terms: $settings.polishSpeakerTerms)
                }

                SettingsFieldRow(
                    title: "Suggestions",
                    layout: .stacked
                ) {
                    SpeakerTermSuggestionsView(model: viewModel.termSuggestions)
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

                    SettingsFieldRow(title: "Agent prompt profile in terminals") {
                        Toggle("", isOn: $settings.agentPolishProfileEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Say \"paste clipboard\" to paste clipboard"
                    ) {
                        Toggle("", isOn: $settings.clipboardPayloadMacroEnabled)
                            .labelsHidden()
                    }
                }
                .disabled(!isLLMPolishingReachable)
                .opacity(isLLMPolishingReachable ? 1.0 : 0.5)
            }

            SettingsGroup(title: "Advanced") {
                SettingsFieldRow(
                    title: "Dismissed suggestions",
                    status: "\(settings.polishDismissedTermSuggestions.count)"
                ) {
                    Button("Forget") {
                        settings.polishDismissedTermSuggestions = []
                    }
                    .disabled(settings.polishDismissedTermSuggestions.isEmpty)
                }

                SettingsFieldRow(
                    title: "Replacement dictionary",
                    help: "Legacy"
                ) {
                    Toggle("", isOn: $settings.replacementDictionaryEnabled)
                        .labelsHidden()
                        .help(
                            "In Live Auto-Paste, corrections briefly retype the last word in place. In apps that do not report the cursor position, stay in place mid-dictation. A correction after a move can overwrite characters at the new position."
                        )
                }

                SettingsFieldRow(title: "Config folder") {
                    Button("Open") {
                        viewModel.openConfigFolder()
                    }
                }

                // Stacked: a list of file names with descriptions is a
                // full-width block, not a control. `terminal_apps.toml` is
                // deliberately absent: it is a launch-time import source,
                // not a live config file — the Terminals section is the UI.
                SettingsFieldRow(title: "Files", layout: .stacked) {
                    SettingsFileNotes(notes: [
                        SettingsFileNote(name: "replacement_dictionary.toml"),
                        SettingsFileNote(name: "llm_system_prompt.toml"),
                        SettingsFileNote(name: "llm_user_prompt.toml"),
                        SettingsFileNote(name: "llm_system_prompt_agent.toml"),
                        SettingsFileNote(name: "llm_user_prompt_agent.toml"),
                    ])
                }
            }
        }
    }
}

/// The consent toggles — everything that lets something OTHER than your
/// spoken words reach the polisher.
///
/// Split out of Text Processing (2026-08-04): these are consent-grade toggles
/// whose help text is the consent, and they were being read past as formatting
/// options next to "Exact match". The group here is STATIC — a toggle
/// switches a group's content, never the number or identity of the groups
/// (owner rule, 2026-07-04).
///
/// The two agent rows gate every session join (Claude Code, opencode, herdr
/// and cmux panes, remote hosts), which is why they are named for the agent
/// session and live here rather than on one harness's pane.
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
                    SettingsFieldRow(
                        title: "Repo vocabulary",
                        help: "Sends file names from the repo in your terminal."
                    ) {
                        Toggle("", isOn: $settings.repoVocabularyEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Clipboard",
                        help: "Sends a capped excerpt of your clipboard."
                    ) {
                        Toggle("", isOn: $settings.polishClipboardContextEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Agent screen",
                        help: "Sends the text on screen in your coding agent's terminal."
                    ) {
                        Toggle("", isOn: $settings.terminalScreenContextEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Agent session",
                        help: "Sends your uncommitted changes, recent files, and last prompt."
                    ) {
                        Toggle("", isOn: $settings.claudeRepoContextEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Non-local endpoints",
                        help: "Also sends enabled context to a non-local polishing endpoint."
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

/// The Claude Code plugin on this Mac and its status line. The cmux join
/// lives on the cmux pane, remote hosts on their own pane, and the context
/// toggles on Context.
private struct ClaudeCodeSettingsPane: View {
    let viewModel: DictationViewModel

    private static let learnMoreURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/integrations/claude-code/README.md"
    )!

    var body: some View {
        SettingsPage(tab: .integrationsClaude) {
            // The integration model is built once at launch and cleared only on
            // terminate, so the `if let` is not a mode: in a running app the
            // group always has its rows.
            SettingsGroup(title: "Setup", learnMoreURL: Self.learnMoreURL) {
                if let claude = viewModel.claudeIntegrationSettings {
                    ClaudePluginInstallRow(model: claude)
                    ClaudeStatuslineRow(model: claude)
                }
            }
        }
    }
}

private struct OpencodeSettingsPane: View {
    let viewModel: DictationViewModel

    private static let learnMoreURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/integrations/opencode/README.md"
    )!

    var body: some View {
        SettingsPage(tab: .integrationsOpencode) {
            SettingsGroup(title: "Setup", learnMoreURL: Self.learnMoreURL) {
                if let claude = viewModel.claudeIntegrationSettings {
                    OpencodePluginRow(model: claude)
                }
            }
        }
    }
}

/// Everything herdr: whether it is found, the hosts reporting a herdr pane,
/// and herdr's saved machines — importable as remote hosts — with the local
/// panel row federated clients need. herdr needs no setup of its own, so the
/// sidebar dot is green whenever herdr is found.
private struct HerdrSettingsPane: View {
    let viewModel: DictationViewModel

    private static let savedMachinesURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/remote-claude-context.md#federated-herdr-machines"
    )!

    var body: some View {
        SettingsPage(tab: .integrationsHerdr) {
            SettingsGroup(title: "Status") {
                SettingsFieldRow(
                    title: "herdr",
                    status: herdrSentence,
                    statusAccessibilityIdentifier: "integrations.herdr.status"
                ) {
                    EmptyView()
                }

                if !herdrPaneHostLabels.isEmpty {
                    SettingsFieldRow(
                        title: "Hosts with a herdr pane",
                        status: herdrPaneHostLabels.joined(separator: ", ")
                    ) {
                        EmptyView()
                    }
                }
            }

            SettingsGroup(title: "Saved machines", learnMoreURL: Self.savedMachinesURL) {
                if let claude {
                    SettingsGroupRow {
                        HerdrMachinesSettingsList(model: claude)
                    }
                    ClaudeHerdrLocalPanelSettingsRow(model: claude)
                }
            }
        }
        .onAppear {
            // The saved-machine rows are derived with the host list.
            claude?.refreshHosts()
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

/// Enrolled SSH hosts: the tunnels the Claude Code remote plugin and remote
/// herdr joins both ride, so the pane belongs to neither harness.
private struct RemoteHostsSettingsPane: View {
    let viewModel: DictationViewModel

    private static let learnMoreURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/remote-claude-context.md"
    )!

    /// Read ONCE, when the pane is constructed — like every other `debug.`
    /// default, this is a screenshot affordance, not a preference that may
    /// change under a running window. Armed, it auto-presents a SAMPLE
    /// enrollment sheet whose every mutating action the model refuses.
    @State private var isEnrollmentSheetPreviewArmed =
        ClaudeIntegrationSettingsModel.isEnrollmentSheetPreviewArmed()

    var body: some View {
        SettingsPage(tab: .integrationsRemote) {
            SettingsGroup(title: "Hosts", learnMoreURL: Self.learnMoreURL) {
                if let claude = viewModel.claudeIntegrationSettings {
                    ClaudeRemoteHostsRows(model: claude)
                }
            }

            SettingsGroup(title: "Plain SSH") {
                if let claude = viewModel.claudeIntegrationSettings {
                    ClaudeShellSetupRow(model: claude)
                }
            }
        }
        .onAppear {
            if let claude = viewModel.claudeIntegrationSettings {
                claude.refreshHosts()
                claude.refreshListenerStatus()
                claude.refreshShellSetupStatus()
                if isEnrollmentSheetPreviewArmed {
                    claude.presentPreviewPlan()
                }
            }
        }
    }
}

/// One terminal's pane (owner decision, 2026-09-07): the status sentence that
/// explains the row's dot, the capabilities as three short rows, and — for a
/// user-added app — removal. cmux adds its session-join setup.
///
/// Group structure is constant per pane (owner rule, 2026-07-04): Status,
/// then Capabilities, then (cmux only) Automation socket. A user app's Remove row
/// is content of Status.
private struct TerminalSettingsPane: View {
    let app: TerminalAppDescriptor
    @Bindable var model: TerminalAppsSettingsModel
    @Bindable var settings: SettingsStore
    let claude: ClaudeIntegrationSettingsModel?
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
                    SettingsFieldRow(title: "Added app") {
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
                    valueText: verdicts.joinValueText,
                    supported: verdicts.join,
                    reason: verdicts.joinReason
                )
                capabilityRow(
                    title: "Screen context",
                    supported: verdicts.screen,
                    reason: verdicts.screenReason
                )
            }

            if app.slug == "cmux" {
                cmuxSessionJoinGroup
            }
        }
    }

    /// The cmux join goes through cmux's automation socket: the switch, the
    /// socket password it needs, and the two-step setup behind one link.
    private var cmuxSessionJoinGroup: some View {
        SettingsGroup(title: "Automation socket", learnMoreURL: TerminalAppCatalog.cmuxDocsURL) {
            SettingsFieldRow(
                title: "Join sessions in cmux",
                help: "Reads the pane you dictate into through cmux's socket."
            ) {
                Toggle("", isOn: $settings.cmuxSurfaceJoinEnabled)
                    .labelsHidden()
            }

            if let claude {
                ClaudeCmuxPasswordSettingsRow(model: claude)
            }
        }
    }

    /// One capability row: "Yes", or "No" plus the one-line reason (e.g.
    /// "Ghostty 1.4 or newer needed."). The Session join row may carry its
    /// own value text when the join route asks for a permission on first
    /// use (iTerm2 / Terminal.app: "Yes, asks for Automation permission on
    /// first use").
    private func capabilityRow(
        title: String,
        valueText: String = "Yes",
        supported: Bool,
        reason: String?
    ) -> some View {
        SettingsFieldRow(
            title: title,
            help: supported ? nil : reason
        ) {
            Text(supported ? valueText : "No")
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
/// Installing is one explicit action: putting a plugin into someone else's
/// Claude Code is their decision. An installed plugin is updated at launch
/// (`updateOutdatedPluginAtLaunch`), so Update shows here only when that
/// failed. The result is one short line next to
/// the label; the CLI's actual output goes to an alert and the log (owner
/// rule: no long text in the pane).
private struct ClaudePluginInstallRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel

    var body: some View {
        // One line (owner review, 2026-09-07): "label + status" leading, the
        // small buttons in the row's trailing column.
        SettingsFieldRow(
            title: "Plugin",
            status: model.pluginResult ?? model.localPluginSentence,
            statusAccessibilityIdentifier: "integrations.claude.plugin.status"
        ) {
            HStack(spacing: 8) {
                // The buttons follow the listing: no install button while the
                // installed plugin is current, no Remove when nothing is
                // installed.
                if let action = model.localPluginStatus.primaryAction {
                    Button(action.title) {
                        Task {
                            if action == .install {
                                await model.installPlugin()
                            } else {
                                await model.updatePlugin()
                            }
                        }
                    }
                    .disabled(model.isPerformingPluginAction)
                    .accessibilityIdentifier("integrations.claude.plugin.install")
                }

                if model.localPluginStatus.offersRemove {
                    Button("Remove") {
                        Task { await model.uninstallPlugin() }
                    }
                    .disabled(model.isPerformingPluginAction)
                    .accessibilityIdentifier("integrations.claude.plugin.remove")
                }

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
/// The buttons follow `OpencodePluginInstallService.Status`, so the row never
/// offers a setup that would change nothing. Installation is confirmed in a consent sheet because it writes both the
/// plugin and the user's `tui.json`. Failures report one short line here and
/// the detail in an alert (owner rule).
private struct OpencodePluginRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    @State private var isShowingSetup = false

    var body: some View {
        // One line like the Claude Code plugin row.
        SettingsFieldRow(
            title: "Plugin",
            status: model.opencodeResult ?? model.opencodeSentence,
            statusAccessibilityIdentifier: "integrations.opencode.status"
        ) {
            HStack(spacing: 8) {
                // The buttons follow the status: no setup button while the
                // installed plugin is current, no Remove when nothing is
                // installed.
                if let title = OpencodePluginInstallService.setupButtonTitle(
                    for: model.opencodeStatus
                ) {
                    Button(title) {
                        isShowingSetup = true
                    }
                    .disabled(model.isPerformingOpencodeAction)
                    .accessibilityIdentifier("integrations.opencode.install")
                }

                if OpencodePluginInstallService.offersRemove(for: model.opencodeStatus) {
                    Button("Remove") {
                        Task { await model.removeOpencodePlugin() }
                    }
                    .disabled(model.isPerformingOpencodeAction)
                    .accessibilityIdentifier("integrations.opencode.remove")
                }

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
            title: "Socket password",
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

/// The plain-ssh join's shell startup edit, with its consent sheet.
private struct ClaudeShellSetupRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    @State private var isShowingShellSetup = false

    var body: some View {
        SettingsGroupRow {
            shellSetup
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
                Text("Terminal setup")
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

            // The buttons follow the rc file: no setup button while this
            // build's block is in it, no Remove when there is no clean block.
            if model.shellSetupStatus.offersRemove {
                Button("Remove") { Task { await model.removeShellSetup() } }
                    .controlSize(.small)
                    .accessibilityIdentifier("claude.remote.shellSetup.remove")
            }
            if let title = model.shellSetupStatus.setupButtonTitle {
                Button(title) { isShowingShellSetup = true }
                    .controlSize(.small)
                    .disabled(!model.canApplyShellSetup)
                    .accessibilityIdentifier("claude.remote.shellSetup.setUp")
            }
        }
    }
}

/// Enrolled SSH hosts, the enrollment form, and the listener they report to.
private struct ClaudeRemoteHostsRows: View {
    @Bindable var model: ClaudeIntegrationSettingsModel

    var body: some View {
        if !model.isRemoteAvailable {
            SettingsGroupRow {
                SettingsInlineMessage(
                    "The enrolled-host list could not be read. See Console for details.",
                    color: .orange
                )
            }
        } else {
            SettingsGroupRow {
                VStack(alignment: .leading, spacing: 8) {
                    hostList
                    // The only place a rejected connection is visible without
                    // the unified log. It is what an hours-long stream of
                    // rejections looked like from the app: nothing at all.
                    if let hint = model.rejectionHint {
                        SettingsInlineMessage(hint, color: .orange)
                    }
                }
            }

            SettingsFieldRow(title: "Add host") {
                enrollmentForm
            }

            SettingsGroupRow {
                VStack(alignment: .leading, spacing: 4) {
                    listenerStatus
                }
            }
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
                            // An outdated plugin takes the position over: the
                            // fixed "Plugin update available" sentence is the
                            // fact the user can act on from this row.
                            Text(
                                host.pluginNeedsUpdate
                                    ? ClaudeIntegrationSettingsModel.pluginUpdateAvailableText
                                    : host.statusText
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .accessibilityIdentifier("claude.remote.host.\(host.id).pluginUpdate")
                        }

                        Spacer(minLength: 8)

                        HStack(spacing: 8) {
                            // `.fixedSize()` so the longer label never truncates
                            // — the row's host label (middle-truncating,
                            // layoutPriority 0) absorbs the squeeze instead.
                            // Prominent only while the plugin is outdated: the
                            // highlight IS the indicator.
                            Button("Update Plugin…") { model.requestPluginUpdate(hostID: host.id) }
                                .controlSize(.small)
                                .fixedSize()
                                .pluginUpdateProminence(needsUpdate: host.pluginNeedsUpdate)
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

/// The integration model's enrollment sheet and alert, attached once at the
/// window root: enrollment starts from Remote hosts (Add host) AND from herdr
/// (Import…), and plugin failures raise the alert from any integration pane.
/// One attachment point means one presenter per state, never two panes
/// fighting over the same sheet.
private struct ClaudeIntegrationPresentations: ViewModifier {
    let model: ClaudeIntegrationSettingsModel?

    func body(content: Content) -> some View {
        if let model {
            content
                .sheet(
                    item: Binding(
                        get: { model.presentedPlan },
                        set: { if $0 == nil { model.dismissPlan() } }
                    )
                ) { plan in
                    ClaudeRemoteEnrollmentSheet(model: model, presentation: plan) {
                        model.dismissPlan()
                    }
                    .interactiveDismissDisabled(model.isEnrollmentBusy)
                }
                // The current API, not `alert(item:)` — that one is deprecated
                // and the repo builds warning-free. The detail lives HERE and
                // never in the pane (owner rule: no long text there).
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
        } else {
            content
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
        .settingsScrollEdgeEffectHidden()
        .background(SettingsLayout.detailBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(tab.paneAccessibilityIdentifier)
    }
}

/// The terms list: chips you remove with their ×, one field that adds on
/// Return (a comma-separated paste adds several).
private struct SpeakerTermsField: View {
    @Binding var terms: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !terms.isEmpty {
                SpeakerTermsFlow(spacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        HStack(spacing: 4) {
                            Text(term)
                                .lineLimit(1)
                            Button {
                                terms.removeAll { $0 == term }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(term)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
                    }
                }
            }

            TextField("", text: $draft, prompt: Text("Qwen, Claude Code, vLLM…"))
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    // Past a cap, or a duplicate: the text stays so the
                    // Return visibly did nothing instead of eating the term.
                    let updated = SpeakerTerms.adding(draft, to: terms)
                    guard updated != terms else { return }
                    terms = updated
                    draft = ""
                }
                .accessibilityIdentifier("settings.aboutYou.termsField")
        }
    }
}

/// Suggested terms as ghost chips: the + adds one to the list, the × refuses
/// it for good. Nothing is added without a click.
private struct SpeakerTermSuggestionsView: View {
    let model: SpeakerTermSuggestionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.suggestions.isEmpty {
                SpeakerTermsFlow(spacing: 6) {
                    ForEach(model.suggestions, id: \.self) { term in
                        HStack(spacing: 4) {
                            Button {
                                model.accept(term)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "plus")
                                        .font(.caption2.weight(.bold))
                                    Text(term).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add \(term)")

                            Button {
                                model.dismiss(term)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Never suggest \(term)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(
                            Capsule().strokeBorder(
                                Color.secondary.opacity(0.6),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                            )
                        )
                    }
                }
            }

            if model.phase == .loading {
                SpeakerTermSuggestionsProgress(model: model)
            } else {
                HStack(spacing: 8) {
                    Button(model.suggestions.isEmpty ? "Suggest terms" : "Suggest again") {
                        model.start()
                    }
                    .disabled(model.unavailableReason != nil)
                    .accessibilityIdentifier("settings.aboutYou.suggestTerms")

                    if !model.suggestions.isEmpty {
                        Button("Add all") { model.acceptAll() }
                    }

                    if let reason = model.unavailableReason {
                        Text(reason)
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                    switch model.phase {
                    case .nothingFound:
                        Text("Nothing new to suggest.")
                            .font(.callout).foregroundStyle(.secondary)
                    case .failed(let message):
                        Text(message)
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    case .idle, .loading:
                        EmptyView()
                    }
                    }
                }

                if model.unavailableReason == nil {
                    Text("Uses API credits")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A run in flight: empty dashed chips breathing where the suggestions will
/// land, and one line that keeps counting — what is being read, for how long.
/// The clock is the whole message that this can take minutes.
private struct SpeakerTermSuggestionsProgress: View {
    let model: SpeakerTermSuggestionModel

    private static let placeholderWidths: [CGFloat] = [64, 96, 52, 80, 70]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(Self.placeholderWidths.enumerated()), id: \.offset) { index, width in
                    Capsule()
                        .strokeBorder(
                            Color.secondary.opacity(0.6),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                        )
                        .frame(width: width, height: 22)
                        .phaseAnimator([0.25, 0.9]) { chip, opacity in
                            chip.opacity(opacity)
                        } animation: { _ in
                            .easeInOut(duration: 0.9).delay(Double(index) * 0.15)
                        }
                }
            }
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(statusLine(at: context.date))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Stop") { model.stop() }
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.aboutYou.suggestProgress")
    }

    private func statusLine(at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(model.startedAt ?? date)))
        let clock = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        guard model.readingCount > 0 else { return clock }
        return "Reading \(model.readingCount) dictations · \(clock)"
    }
}

/// Left-to-right wrapping rows for the term chips. Only used where the parent
/// proposes a finite width (a stacked settings row); with no width proposed
/// everything sits on one row.
private struct SpeakerTermsFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(for: subviews, in: proposal.width ?? .infinity)
        return CGSize(
            width: proposal.width ?? (frames.map(\.maxX).max() ?? 0),
            height: frames.map(\.maxY).max() ?? 0
        )
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for (subview, frame) in zip(subviews, frames(for: subviews, in: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func frames(for subviews: Subviews, in width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
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
                // No border: on the detail column's white, the fill alone
                // outlines the card (CodexBar's grouped-row look).
                .fill(.quinary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Insets + trailing divider shared by everything that is a row of a
/// `SettingsGroup`. The divider is inset like the row's content, so it reads
/// as a separator between rows rather than a rule across the card.
private struct SettingsGroupRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
                .padding(.vertical, SettingsLayout.rowVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
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
enum SettingsFieldRowLayout {
    /// Label leading, control trailing on the same line. The default.
    case inline
    /// Label on its own line, control full-width beneath it. For rows whose
    /// control is a composite (button bar, host list, file list): beside a
    /// 400pt-wide control the label would be squeezed into a wrapped stub.
    case stacked
}

struct SettingsFieldRow<Content: View, Footer: View>: View {
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

/// One short inline sentence in a Settings pane. Internal (not private) so
/// pane-subviews in their own files — e.g. `HerdrMachinesSettingsList` — can
/// reuse the idiom instead of copying it.
struct SettingsInlineMessage: View {
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

private extension View {
    /// `.borderedProminent` only while the host's plugin is outdated — the
    /// highlight is the update indicator, so it must never decorate a current
    /// host. Written as an `if`, not a ternary: `buttonStyle(_:)` is generic
    /// over the style type, so the two branches cannot share one expression.
    @ViewBuilder
    func pluginUpdateProminence(needsUpdate: Bool) -> some View {
        if needsUpdate {
            buttonStyle(.borderedProminent)
        } else {
            self
        }
    }
}
