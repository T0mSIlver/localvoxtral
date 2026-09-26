import AppKit
import SwiftUI

/// Install/update the LOCAL Claude Code plugin.
///
/// Installing is one explicit action: putting a plugin into someone else's
/// Claude Code is their decision. An installed plugin is updated at launch
/// (`updateOutdatedPluginAtLaunch`), so Update shows here only when that
/// failed. The result is one short line next to
/// the label; the CLI's actual output goes to an alert and the log (owner
/// rule: no long text in the pane).
struct ClaudePluginInstallRow: View {
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
                            switch action {
                            case .install:
                                await model.installPlugin()
                            case .repair:
                                // The plugin is installed and current; only
                                // the path Claude Code loads it from is wrong.
                                await model.repairMarketplaceRegistration()
                            case .update, .installOrUpdate:
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
struct ClaudeStatuslineRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    @State private var isShowingSetup = false

    private static let docsURL = DocsLink.page("integrations/claude-code/#connection-indicator-opt-in-status-line")

    var body: some View {
        // One line like the plugin row: status leads, small buttons trail.
        SettingsFieldRow(
            title: "Status line",
            status: model.statuslineResult ?? model.statuslineSentence,
            statusAccessibilityIdentifier: "integrations.claude.statusline.status"
        ) {
            HStack(spacing: 8) {
                let status = model.statuslineStatus
                if let title = ClaudeStatuslineInstallService.setupButtonTitle(for: status) {
                    Button(title) { isShowingSetup = true }
                        .disabled(
                            model.isPerformingStatuslineAction || !model.canApplyStatuslineSetup
                        )
                        .accessibilityIdentifier("integrations.claude.statusline.install")
                }
                if ClaudeStatuslineInstallService.offersRemove(for: status) {
                    Button("Remove") { Task { await model.removeStatusline() } }
                        .disabled(model.isPerformingStatuslineAction)
                        .accessibilityIdentifier("integrations.claude.statusline.remove")
                }
                if status == .edited || status == .combinedBroken || status == .foreignNotCombinable {
                    Link("How to combine status lines", destination: Self.docsURL)
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
struct OpencodePluginRow: View {
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

/// Install/remove the Mistral Vibe hooks.
///
/// Same shape as `OpencodePluginRow`: the buttons follow
/// `VibeHooksInstallService.Status`, and setup is confirmed in a consent sheet
/// because it edits the user's `hooks.toml`.
struct VibeHooksRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    @State private var isShowingSetup = false

    var body: some View {
        SettingsFieldRow(
            title: "Hooks",
            status: model.vibeResult ?? model.vibeSentence,
            statusAccessibilityIdentifier: "integrations.vibe.status"
        ) {
            HStack(spacing: 8) {
                if let title = VibeHooksInstallService.setupButtonTitle(for: model.vibeStatus) {
                    Button(title) {
                        isShowingSetup = true
                    }
                    .disabled(model.isPerformingVibeAction)
                    .accessibilityIdentifier("integrations.vibe.install")
                }

                if VibeHooksInstallService.offersRemove(for: model.vibeStatus) {
                    Button("Remove") {
                        Task { await model.removeVibeHooks() }
                    }
                    .disabled(model.isPerformingVibeAction)
                    .accessibilityIdentifier("integrations.vibe.remove")
                }

                if model.isPerformingVibeAction {
                    ProgressView().controlSize(.small)
                }
            }
            .controlSize(.small)
        }
        .sheet(isPresented: $isShowingSetup) {
            VibeHooksSetupSheet(model: model) { isShowingSetup = false }
        }
    }
}

/// The cmux automation-socket password, stored in the Keychain.
///
/// A write-only field on purpose: the stored secret is never read back into the
/// UI, so what the user typed leaves the process the moment they save it, and
/// the row reports only whether one is stored.
struct ClaudeCmuxPasswordSettingsRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel

    var body: some View {
        SettingsFieldRow(title: "Socket password") {
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
struct ClaudeShellSetupRow: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    @State private var isShowingShellSetup = false

    private static let manualStepsURL = DocsLink.page("integrations/claude-code/#1-the-tty-echo-works-through-jump-hosts-and-controlmaster")

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
            if model.shellSetupStatus.offersManualSteps {
                Link("Details", destination: Self.manualStepsURL)
                    .font(.caption)
                    .accessibilityIdentifier("claude.remote.shellSetup.details")
            }
        }
    }
}

/// Enrolled SSH hosts, the enrollment form, and the listener they report to.
struct ClaudeRemoteHostsRows: View {
    @Bindable var model: ClaudeIntegrationSettingsModel

    @ViewBuilder
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
                            // fixed "Update available" sentence is the
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
                            // highlight IS the indicator. Hidden once the host
                            // is known current, since the run would change
                            // nothing.
                            if host.offersUpdate {
                                Button("Update Host…") { model.requestPluginUpdate(hostID: host.id) }
                                    .controlSize(.small)
                                    .fixedSize()
                                    .pluginUpdateProminence(needsUpdate: host.pluginNeedsUpdate)
                                    .disabled(model.isEnrollmentBusy)
                            }
                            // Not while a setup run is in flight: it mints the
                            // host's Vibe credential against the current token,
                            // and the registry refuses to commit it across a
                            // rotation.
                            Button("Rotate token") { Task { await model.rotate(hostID: host.id) } }
                                .controlSize(.small)
                                .disabled(model.isEnrollmentBusy)
                            if !host.isRevoked {
                                Button("Revoke") { Task { await model.revoke(hostID: host.id) } }
                                    .controlSize(.small)
                                    .disabled(model.isEnrollmentBusy)
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
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    private static let remoteSetupDocumentationURL = DocsLink.page("docs/remote-claude-context/")

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
struct ClaudeIntegrationPresentations: ViewModifier {
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
/// same run and both render the same seven steps. The model owns every sentence;
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

/// One consent sentence and the seven-step automated setup run.
private struct ClaudeRemoteEnrollmentSheet: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    let presentation: ClaudeIntegrationSettingsModel.EnrollmentPresentation
    let onDismiss: () -> Void

    private static let documentationURL = DocsLink.page("docs/remote-claude-context/")

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

/// Consent for the shell startup edit.
private struct ClaudeShellSetupSheet: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    var dismiss: () -> Void

    private static let documentationURL = DocsLink.page("docs/remote-claude-context/")

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

    private static func confirmTitle(for status: ClaudeStatuslineInstallService.Status) -> String {
        switch status {
        case .foreign: return "Combine"
        case .stalePath, .otherCopy, .combinedOutdated: return "Update"
        default: return "Set Up"
        }
    }

    private static let documentationURL = DocsLink.page("integrations/claude-code/#connection-indicator-opt-in-status-line")

    var body: some View {
        let status = model.statuslineStatus
        VStack(alignment: .leading, spacing: 12) {
            Text(status == .foreign ? "Combine with your status line" : "Claude Code status line")
                .font(.headline)
            Text(ClaudeStatuslineInstallService.consentSentence(for: status))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Link("Details", destination: Self.documentationURL)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("integrations.statuslineSheet.cancel")
                // The sheet's own button acts at once, so no ellipsis.
                Button(Self.confirmTitle(for: status)) {
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

    private static let documentationURL = DocsLink.page("integrations/opencode/#install")

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

/// Consent for the Mistral Vibe hook files.
private struct VibeHooksSetupSheet: View {
    @Bindable var model: ClaudeIntegrationSettingsModel
    var dismiss: () -> Void

    private static let documentationURL = DocsLink.page("integrations/vibe/#install")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mistral Vibe hooks")
                .font(.headline)
            Text(VibeHooksInstallService.consentSentence)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Link("Details", destination: Self.documentationURL)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("integrations.vibeSheet.cancel")
                Button("Set Up") {
                    Task {
                        await model.installVibeHooks()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("integrations.vibeSheet.apply")
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
