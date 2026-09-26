import AppKit
import SwiftUI

/// Shared, observable selection for the Settings `TabView`. Owned by the app
/// delegate so a programmatic tab change survives the Settings window's
/// open/close lifecycle.
@MainActor
@Observable
final class SettingsNavigator {
    var selectedTab: SettingsTab = .general
    /// What the History pane shows when it next appears, then clears: how an
    /// Insights count opens the dictations it counted, period included.
    var historyRequest: HistoryRequest?

    struct HistoryRequest: Equatable {
        let filter: DictationHistoryQuery.Filter
        let since: Date?
    }
}

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var viewModel: DictationViewModel
    var backendManager: BackendManager
    @Bindable var navigator: SettingsNavigator
    /// The login item's system registration, read once per launch by the app
    /// delegate and re-read whenever the General pane appears.
    var loginItem: LoginItemController
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

    /// What History and Insights show. The app hands over the pair it keeps
    /// for its lifetime; without them the view builds its own.
    @State private var historyModel: DictationHistoryModel
    @State private var insightsModel: DictationInsightsModel

    init(
        settings: SettingsStore,
        viewModel: DictationViewModel,
        backendManager: BackendManager,
        navigator: SettingsNavigator,
        loginItem: LoginItemController,
        historyModel: DictationHistoryModel? = nil,
        insightsModel: DictationInsightsModel? = nil
    ) {
        self.settings = settings
        self.viewModel = viewModel
        self.backendManager = backendManager
        self.navigator = navigator
        self.loginItem = loginItem
        _historyModel = State(
            initialValue: historyModel
                ?? DictationHistoryModel(store: { [weak viewModel] in viewModel?.sessionStore }))
        _insightsModel = State(
            initialValue: insightsModel ?? DictationInsightsModel(viewModel: viewModel))
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
                viewModel.engines.applyRealtimeEndpointChange(newValue)
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
                viewModel.shortcuts.updateDictationShortcut(newValue)
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebarView(
                selection: $navigator.selectedTab,
                terminalApps: terminalAppsModel.terminalApps,
                statusDot: sidebarDot,
                badgeCount: { tab in
                    switch tab.kind {
                    case .textProcessing: viewModel.termSuggestions.badgeCount
                    case .inbox: viewModel.quickCapture?.waitingCount ?? 0
                    default: 0
                    }
                },
                addTerminalApp: chooseAndAddTerminalApp,
                addAppMessage: $addAppMessage
            )

            // No hairline between the columns: the sidebar's gray against the
            // detail column's white is the separation.
            detailColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Declared to SwiftUI as well as corrected by the chrome, like the
        // titlebar (see `SettingsWindowChrome`): the Window menu, Mission
        // Control and the AX drills read the title, which is never drawn.
        .navigationTitle(SettingsWindowChromeView.windowTitle)
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
            // History and Insights lead the sidebar: read both now, so the
            // first click on either draws a result, not "Loading…" and a page
            // that grows under the scroll bar. The pane on screen reads for
            // itself.
            if navigator.selectedTab != .history {
                Task { await historyModel.reload() }
            }
            if navigator.selectedTab != .insights {
                Task { await insightsModel.reload() }
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
        case .integrationsVibe:
            return IntegrationsSidebarStatus.vibeDot(
                status: viewModel.claudeIntegrationSettings?.vibeStatus ?? .unknown
            )
        case .integrationsCodex:
            let codex = viewModel.claudeIntegrationSettings
            return IntegrationsSidebarStatus.codexDot(
                status: codex?.codexStatus ?? .unknown,
                hookHeard: codex?.codexHookHeard ?? false
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
        case .general, .dictation, .endpoints, .textProcessing, .integrationsContext, .about,
            .history, .insights:
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
                GeneralSettingsPane(
                    settings: settings, viewModel: viewModel, loginItem: loginItem)
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
            case .integrationsVibe:
                VibeSettingsPane(viewModel: viewModel)
            case .integrationsCodex:
                CodexSettingsPane(viewModel: viewModel)
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
            case .history:
                HistorySettingsPane(
                    settings: settings, viewModel: viewModel, model: historyModel,
                    navigator: navigator)
            case .insights:
                InsightsSettingsPane(
                    viewModel: viewModel, model: insightsModel, navigator: navigator)
            case .inbox:
                InboxSettingsPane(inbox: viewModel.quickCapture)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SettingsLayout.detailBackground)
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
