import AppKit
import SwiftUI

/// The consent toggles — everything that lets something OTHER than your
/// spoken words reach the polisher.
///
/// Split out of Text Processing (2026-08-04): these are consent-grade toggles
/// whose titles are the consent, and they were being read past as formatting
/// options next to "Exact match". The group here is STATIC — a toggle
/// switches a group's content, never the number or identity of the groups
/// (owner rule, 2026-07-04).
///
/// The two agent rows gate every session join (Claude Code, opencode, herdr
/// and cmux panes, remote hosts), which is why they are named for the agent
/// session and live here rather than on one harness's pane.
///
/// Copy rule (owner review, 2026-09-25, #578): each toggle's title starts with
/// "Send" and names what leaves the machine, with no line under it. The full
/// terms live in `docs/coding-agents.md` behind the group's Learn more link.
struct IntegrationsContextSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel

    /// Where the group's Learn more link lands.
    private enum LearnMore {
        static let polishContext = DocsLink.page("docs/coding-agents/#polish-context-what-each-toggle-sends")
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
                        title: "Send repo file names"
                    ) {
                        Toggle("", isOn: $settings.repoVocabularyEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Send clipboard excerpt"
                    ) {
                        Toggle("", isOn: $settings.polishClipboardContextEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Send agent's terminal screen"
                    ) {
                        Toggle("", isOn: $settings.terminalScreenContextEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Send diff, recent files and last prompt"
                    ) {
                        Toggle("", isOn: $settings.claudeRepoContextEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Send context to non-local polishing servers"
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
struct ClaudeCodeSettingsPane: View {
    let viewModel: DictationViewModel

    private static let learnMoreURL = DocsLink.page("integrations/claude-code/")

    var body: some View {
        SettingsPage(tab: .integrationsClaude) {
            // The integration model is built once at launch and cleared only on
            // terminate, so the `if let` is not a mode: in a running app the
            // group always has its rows.
            SettingsGroup(title: "Setup", learnMoreURL: Self.learnMoreURL) {
                if let claude = viewModel.claudeIntegrationSettings {
                    ClaudePluginInstallRow(model: claude)
                    ClaudeStatuslineRow(model: claude)
                    DictationNoteRow(model: claude, agent: .claudeCode)
                }
            }
        }
    }
}

struct OpencodeSettingsPane: View {
    let viewModel: DictationViewModel

    private static let learnMoreURL = DocsLink.page("integrations/opencode/")

    var body: some View {
        SettingsPage(tab: .integrationsOpencode) {
            SettingsGroup(title: "Setup", learnMoreURL: Self.learnMoreURL) {
                if let claude = viewModel.claudeIntegrationSettings {
                    OpencodePluginRow(model: claude)
                    DictationNoteRow(model: claude, agent: .opencode)
                }
            }
        }
    }
}

struct VibeSettingsPane: View {
    let viewModel: DictationViewModel

    private static let learnMoreURL = DocsLink.page("integrations/vibe/")

    var body: some View {
        SettingsPage(tab: .integrationsVibe) {
            SettingsGroup(title: "Setup", learnMoreURL: Self.learnMoreURL) {
                if let claude = viewModel.claudeIntegrationSettings {
                    VibeHooksRow(model: claude)
                    DictationNoteRow(model: claude, agent: .vibe)
                }
            }
        }
    }
}

/// Everything herdr: whether it is found, the hosts reporting a herdr pane,
/// and herdr's saved machines — importable as remote hosts — with the local
/// panel row federated clients need. herdr needs no setup of its own, so the
/// sidebar dot is green whenever herdr is found.
struct HerdrSettingsPane: View {
    let viewModel: DictationViewModel

    private static let savedMachinesURL = DocsLink.page("docs/remote-claude-context/#federated-herdr-machines")

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
struct RemoteHostsSettingsPane: View {
    let viewModel: DictationViewModel

    private static let learnMoreURL = DocsLink.page("docs/remote-claude-context/")

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
struct TerminalSettingsPane: View {
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
            SettingsFieldRow(title: "Join sessions in cmux") {
                Toggle("", isOn: $settings.cmuxSurfaceJoinEnabled)
                    .labelsHidden()
            }

            if let claude {
                ClaudeCmuxPasswordSettingsRow(model: claude)
            }
        }
    }

    /// One capability row: "Yes", or what is missing as the value (e.g.
    /// "Needs Ghostty 1.4+"). The Session join row may carry its own value
    /// text when the join route asks for a permission on first use (iTerm2 /
    /// Terminal.app: "Yes, asks for Automation permission on first use").
    private func capabilityRow(
        title: String,
        valueText: String = "Yes",
        supported: Bool,
        reason: String?
    ) -> some View {
        SettingsFieldRow(title: title) {
            Text(supported ? valueText : (reason ?? "No"))
        }
    }
}
