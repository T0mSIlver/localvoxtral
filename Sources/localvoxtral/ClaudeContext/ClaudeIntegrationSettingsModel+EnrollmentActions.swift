import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    public func dismissPlan() {
        // The plaintext goes with it. Nothing else holds a copy.
        presentedPlan = nil
        enrollmentConfirmation = nil
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        verificationChecks = []
        setupRun = nil
        setupManualInstructions = nil
    }

    public func requestPluginUpdate(hostID: String) {
        guard !isEnrollmentBusy,
              let host = hosts.first(where: { $0.id == hostID })
        else { return }
        // The ENROLLED alias, never the label: a host named `prod` may be
        // reached over alias `builder`, and `ssh prod …` would then update
        // whatever machine answers to that name (review finding, PR #197).
        // Hosts enrolled before the alias was persisted have none and must be
        // re-enrolled rather than targeting a guessed host.
        let alias = host.sshHostAlias.flatMap {
            ClaudeRemoteEnrollmentService.isValidHostAlias($0) ? $0 : nil
        }
        // A fresh panel must not inherit another action's results, for the same
        // reason a fresh enrollment sheet must not (field report 2026-07-26).
        enrollmentConfirmation = nil
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        // Regenerate the block unless it is already current. `nil` from the
        // service means "cannot tell", and cannot-tell must regenerate: the
        // cost of a redundant idempotent rewrite is nothing, and the cost of
        // assuming a stale block is current is a silently dead host.
        let alreadyCurrent =
            registry?.host(id: hostID).flatMap { host in
                expectedSSHConfigSnippet(for: host).flatMap {
                    enrollmentService.sshConfigBlockIsCurrent(snippet: $0, hostID: host.id)
                }
            } ?? false
        let snippet: String? = alreadyCurrent ? nil : registry?.host(id: hostID).map { host in
            ClaudeRemoteEnrollmentService.sshConfigSnippet(
                host: host,
                sshHostAlias: alias ?? Self.unknownAliasPlaceholder,
                listenerPort: listener?.boundPort ?? ClaudeRemoteListenerLimits.default.port,
                remoteForwardPort: remoteForwardPort
            )
        }
        presentedPluginUpdate = PluginUpdatePresentation(
            hostID: hostID,
            sshHostAlias: alias,
            commands: ClaudeRemoteEnrollmentService.updateCommands(
                sshHostAlias: alias ?? Self.unknownAliasPlaceholder,
                remoteForwardPort: remoteForwardPort
            ),
            sshConfigSnippet: snippet
        )
    }

    /// Exactly what `performPluginUpdate` will do, retained as a test seam.
    static func updatePreview(for presentation: PluginUpdatePresentation) -> String {
        presentation.applicationText
    }

    /// The ssh-config block this build writes for `host`, or nil when it has
    /// no valid alias to write it for.
    func expectedSSHConfigSnippet(for host: ClaudeRemoteHost) -> String? {
        guard let alias = host.sshHostAlias,
              ClaudeRemoteEnrollmentService.isValidHostAlias(alias)
        else { return nil }
        return ClaudeRemoteEnrollmentService.sshConfigSnippet(
            host: host,
            sshHostAlias: alias,
            listenerPort: listener?.boundPort ?? ClaudeRemoteListenerLimits.default.port,
            remoteForwardPort: remoteForwardPort
        )
    }

    /// Stands in for an alias we were never told. It is not a valid target and
    /// exists only for deterministic plans used by documentation and tests.
    static let unknownAliasPlaceholder = "your-ssh-host"

    public func dismissPluginUpdate() {
        switch enrollmentResultsAction {
        case .updateRemotePlugin?, .updateHost?:
            enrollmentStepStatuses = []
            enrollmentResultsAction = nil
        default:
            break
        }
        switch enrollmentConfirmation?.action {
        case .updateRemotePlugin?, .updateHost?:
            enrollmentConfirmation = nil
        default:
            break
        }
        setupRun = nil
        setupManualInstructions = nil
        presentedPluginUpdate = nil
    }

    /// Ask before running the legacy plugin-only update path.
    public func requestPluginUpdateRun() {
        guard let presentation = presentedPluginUpdate,
              presentation.canRun,
              !isEnrollmentBusy
        else { return }
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        verificationChecks = []
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .updateRemotePlugin(hostID: presentation.hostID),
            title: presentation.sshConfigSnippet == nil
                ? "Update the plugin on this SSH host?"
                : "Update ~/.ssh/config on this Mac and the plugin on this SSH host?",
            preview: Self.updatePreview(for: presentation),
            confirmButtonTitle: "Confirm update"
        )
        Log.claudeContext.info("Claude remote plugin update confirmation requested")
    }

    public func requestHostUpdateRun() {
        guard let presentation = presentedPluginUpdate,
              presentation.canRun,
              !isEnrollmentBusy
        else { return }
        setupRun = nil
        setupManualInstructions = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .updateHost(hostID: presentation.hostID),
            title: hostSetupConsentSentence(
                sshHostAlias: presentation.sshHostAlias ?? Self.unknownAliasPlaceholder
            ),
            preview: setupPreview(
                sshConfigSnippet: presentation.sshConfigSnippet,
                remoteCommands: presentation.commands
            ),
            confirmButtonTitle: "Update Host"
        )
        Log.claudeContext.info("Claude remote host update confirmation requested")
    }

    public func requestSSHConfigInsertion() {
        guard let presentation = presentedPlan, !isEnrollmentBusy, !presentation.isPreview else { return }
        enrollmentStepStatuses = []
        // The verdicts described the setup BEFORE this change. Leaving them up
        // beside a fresh result reads as if they described the state after it
        // (review finding, round 3).
        verificationChecks = []
        enrollmentResultsAction = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .insertSSHConfig,
            title: "Insert this exact block into ~/.ssh/config?",
            preview: presentation.plan.sshConfigSnippet,
            confirmButtonTitle: "Confirm insert"
        )
        Log.claudeContext.info("Claude remote ssh config confirmation requested")
    }

    public func requestRemoteSetup() {
        guard let presentation = presentedPlan,
              // A placeholder alias must not reach ssh: automation would hand
              // the new token to whatever answers to a name we invented.
              presentation.canRunRemoteSetup,
              !isEnrollmentBusy,
              !presentation.isPreview
        else { return }
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        verificationChecks = []
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .runRemoteSetup,
            title: "Run these commands on the SSH host?",
            preview: Self.redactedRemoteCommands(for: presentation),
            confirmButtonTitle: "Confirm run"
        )
        Log.claudeContext.info("Claude remote setup confirmation requested")
    }

    public func requestHostSetup() {
        guard let presentation = presentedPlan,
              presentation.canRunRemoteSetup,
              !isEnrollmentBusy,
              !presentation.isPreview
        else { return }
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        verificationChecks = []
        setupRun = nil
        setupManualInstructions = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .setupHost,
            title: hostSetupConsentSentence(sshHostAlias: presentation.sshHostAlias),
            preview: setupPreview(
                sshConfigSnippet: presentation.plan.sshConfigSnippet,
                remoteCommands: presentation.plan.remoteCommands
            ),
            confirmButtonTitle: "Run Setup"
        )
        Log.claudeContext.info("Claude remote host setup confirmation requested")
    }

    public func cancelEnrollmentActionConfirmation() {
        enrollmentConfirmation = nil
    }

    public func confirmEnrollmentAction() async {
        guard let confirmation = enrollmentConfirmation, !isEnrollmentBusy else { return }
        switch confirmation.action {
        case .insertSSHConfig, .runRemoteSetup:
            await performPlanAction(confirmation)
        case .updateRemotePlugin:
            await performPluginUpdate(confirmation)
        case .setupHost, .updateHost:
            await performSetupRun(confirmation)
        case .configureHerdrPanel:
            await performHerdrPanelConfiguration(confirmation)
        case .configureLocalHerdrPanel:
            await performLocalHerdrPanelConfiguration(confirmation)
        }
    }

    public func cancelSetupRun() {
        guard setupRun != nil, isPerformingEnrollmentAction else { return }
        setupCancellationRequested = true
    }

    private func setupPreview(
        sshConfigSnippet: String?,
        remoteCommands: [String]
    ) -> String {
        var sections: [String] = []
        if let sshConfigSnippet {
            sections.append("Mac ~/.ssh/config:\n\(sshConfigSnippet)")
        }
        if let shellSetupPreview {
            sections.append("Mac shell startup file:\n\(shellSetupPreview)")
        }
        sections.append("Remote host:\n" + remoteCommands.joined(separator: "\n"))
        sections.append(
            "Remote herdr, when installed:\n"
                + ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet
                + "\nherdr server reload-config"
        )
        return sections.joined(separator: "\n\n")
    }

    func shellRCPathForConsent() -> String {
        guard let shell = loginShell() else { return "your shell startup file" }
        let relative = ClaudeShellRCSetup.relativeRCPath(for: shell) { relative in
            FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(relative).path
            )
        }
        return "~/\(relative)"
    }

    func performPlanAction(_ confirmation: EnrollmentConfirmation) async {
        // Belt and braces: a preview sheet cannot raise a confirmation in the
        // first place, and if one somehow existed it would run against a host
        // the registry has never heard of.
        guard let presentation = presentedPlan, !presentation.isPreview else { return }
        let service = enrollmentService
        let work: @Sendable () throws -> [ClaudeRemoteEnrollmentService.ExecutionStep]
        switch confirmation.action {
        case .insertSSHConfig:
            work = {
                try service.insertSSHConfig(presentation.plan, hostID: presentation.host.id)
                return []
            }
        case .runRemoteSetup:
            work = {
                try service.executeRemoteSetup(
                    presentation.plan,
                    sshHostAlias: presentation.sshHostAlias,
                    token: presentation.token
                )
            }
        case .updateRemotePlugin, .setupHost, .updateHost:
            // Routed to performPluginUpdate: that action belongs to a host row,
            // has no plan and no token, and must not run against one.
            return
        case .configureHerdrPanel, .configureLocalHerdrPanel:
            return
        }
        enrollmentConfirmation = nil
        isPerformingEnrollmentAction = true
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        defer { isPerformingEnrollmentAction = false }

        let attempt = await performEnrollmentAsync(work)

        // The sheet may have been dismissed (window close) and even replaced
        // while the detached work ran; a late result must not surface under a
        // different sheet. The whole presentation must match, not just the
        // host id — rotation REUSES the host id, and an id-only guard let an
        // old-token outcome render beneath the new token's commands. Rotation
        // mints a fresh token, so value equality distinguishes generations.
        guard presentedPlan == presentation else { return }

        publish(attempt, action: confirmation.action)
    }

    private func performPluginUpdate(_ confirmation: EnrollmentConfirmation) async {
        guard let presentation = presentedPluginUpdate,
              let alias = presentation.sshHostAlias
        else { return }
        enrollmentConfirmation = nil
        isPerformingEnrollmentAction = true
        enrollmentStepStatuses = []
        enrollmentResultsAction = nil
        defer { isPerformingEnrollmentAction = false }

        let service = enrollmentService
        // Copied out of self before the detached hop, like `service`: the
        // closure is @Sendable and must not capture the main-actor model.
        let port = remoteForwardPort
        let hostID = presentation.hostID
        // Only the block this path's confirmation disclosed, and only when the
        // file does not already hold it. Unlike the setup run, whose consent
        // names ~/.ssh/config either way, this one may have promised no local
        // edit at all, so it never regenerates one.
        let snippet = presentation.sshConfigSnippet
            .flatMap { service.sshConfigBlockIsCurrent(snippet: $0, hostID: hostID) == true ? nil : $0 }
        // ORDER IS THE SAFETY PROPERTY. The local block is rewritten first, and
        // the remote is touched only if that succeeded. Reverse them and a
        // refused local write (symlinked config, untrusted ~/.ssh) leaves the
        // remote posting to a port this Mac does not forward — silently. This
        // way the worst case is "nothing changed anywhere, with an error on
        // screen", which is a state a user can act on.
        let attempt = await performEnrollmentAsync {
            if let snippet {
                try service.insertSSHConfig(snippet: snippet, hostID: hostID)
            }
            return try service.executeRemotePluginUpdate(
                sshHostAlias: alias, remoteForwardPort: port
            )
        }

        // Same rule as the sheet: the row may have been closed, or another
        // host's opened, while ssh was still running — one host's outcome must
        // never render under another host's commands.
        guard presentedPluginUpdate == presentation else { return }

        publish(attempt, action: confirmation.action)
    }

    /// Turn one finished attempt into the statuses its section renders.
    func publish(_ attempt: ClaudeEnrollmentActionAttempt, action: EnrollmentAction) {
        if let failure = attempt.failure {
            enrollmentStepStatuses = Self.failureStatuses(failure, action: action)
            enrollmentResultsAction = action
            alert = DetailAlert(
                title: Self.failureAlertTitle(for: action),
                detail: Self.enrollmentFailureDetail(failure, action: action)
            )
            Log.claudeContext.error(
                "Claude remote enrollment action failed: \(failure.describedError, privacy: .public)"
            )
            return
        }

        switch action {
        case .insertSSHConfig:
            enrollmentStepStatuses = [
                EnrollmentStepStatus(
                    id: 0, text: "Inserted this host's block into ~/.ssh/config.", succeeded: true, detail: ""
                )
            ]
        case .runRemoteSetup, .updateRemotePlugin:
            enrollmentStepStatuses = attempt.steps.map {
                EnrollmentStepStatus(
                    id: $0.index,
                    text: "Step \($0.index + 1) succeeded.",
                    succeeded: true,
                    detail: $0.message
                )
            }
        case .configureHerdrPanel:
            enrollmentStepStatuses = [
                EnrollmentStepStatus(
                    id: 0,
                    text: "Configured the remote herdr agents panel.",
                    succeeded: true,
                    detail: attempt.steps.first?.message ?? ""
                )
            ]
        case .configureLocalHerdrPanel:
            enrollmentStepStatuses = [
                EnrollmentStepStatus(
                    id: 0,
                    text: "Configured the local herdr agents panel.",
                    succeeded: true,
                    detail: attempt.steps.first?.message ?? ""
                )
            ]
        case .setupHost, .updateHost:
            break
        }
        enrollmentResultsAction = action
    }

    static func failureAlertTitle(for action: EnrollmentAction) -> String {
        switch action {
        case .insertSSHConfig, .runRemoteSetup, .setupHost: return "Remote Claude Code setup"
        case .updateRemotePlugin: return "Remote Claude Code plugin"
        case .updateHost: return "Remote host update"
        case .configureHerdrPanel: return "Remote herdr panel"
        case .configureLocalHerdrPanel: return "Local herdr panel"
        }
    }

    private static func failureStatuses(
        _ failure: ClaudeEnrollmentActionFailure,
        action: EnrollmentAction
    ) -> [EnrollmentStepStatus] {
        guard action != .insertSSHConfig else {
            return [EnrollmentStepStatus(id: 0, text: "SSH config update failed.", succeeded: false, detail: failure.describedError)]
        }

        let failedStep: Int
        let detail: String
        switch failure.serviceError {
        case .commandFailed(let step, _, _, let message):
            failedStep = step
            detail = message
        case .commandTimedOut(let step, _, _, let message):
            failedStep = step
            detail = message
        case .runnerFailed(let step, _, let message):
            failedStep = step
            detail = message
        default:
            var text = "Remote setup failed."
            if case .updateRemotePlugin = action { text = "Plugin update failed." }
            if case .configureHerdrPanel = action { text = "Herdr panel setup failed." }
            if case .configureLocalHerdrPanel = action { text = "Local herdr panel setup failed." }
            let detail: String
            if failure.serviceError == .herdrPanelConfigAlreadyCustomized
                || failure.serviceError == .localHerdrPanelConfigAlreadyCustomized {
                detail = "Open Details for the manual herdr configuration."
            } else {
                detail = failure.describedError
            }
            return [EnrollmentStepStatus(id: 0, text: text, succeeded: false, detail: detail)]
        }
        let succeeded = (0..<failedStep).map {
            EnrollmentStepStatus(id: $0, text: "Step \($0 + 1) succeeded.", succeeded: true, detail: "")
        }
        return succeeded + [
            EnrollmentStepStatus(
                id: failedStep,
                text: "Step \(failedStep + 1) failed.",
                succeeded: false,
                detail: detail
            )
        ]
    }

    /// The alert body. `action` names the work in the user's terms — an alert
    /// that says "SSH setup" after they pressed Update Plugin reads as a
    /// different failure than the one they are looking at.
    static func enrollmentFailureDetail(
        _ failure: ClaudeEnrollmentActionFailure,
        action: EnrollmentAction
    ) -> String {
        var subject = "SSH setup"
        if case .updateRemotePlugin = action { subject = "Plugin update" }
        if case .configureHerdrPanel = action { subject = "Herdr panel setup" }
        if case .configureLocalHerdrPanel = action { subject = "Local herdr panel setup" }
        switch failure.serviceError {
        case .commandTimedOut(_, _, let seconds, let message):
            let output = message.isEmpty ? "" : "\n\n\(message)"
            return "\(subject) did not finish within \(Int(seconds))s and was stopped.\(output)"
        case .commandFailed(_, _, let exitCode, let message):
            return "\(subject) exited with code \(exitCode).\n\n\(message)"
        case .runnerFailed(_, _, let message):
            return "\(subject) could not run.\n\n\(message)"
        case .invalidSSHConfigEncoding:
            return "~/.ssh/config is not valid UTF-8, so localvoxtral left it unchanged."
        case .sshConfigIsSymlink:
            return "~/.ssh/config or ~/.ssh is a symlink, likely from a dotfiles setup. "
                + "localvoxtral won't replace the link. Open Details and add the block "
                + "to the real file yourself."
        case .sshDirectoryNotTrusted:
            return "~/.ssh is not exclusively writable by you (wrong owner or group/world-"
                + "writable), so localvoxtral left it unchanged. Open Details for the "
                + "manual remedy."
        case .sshConfigEditingNotConfigured:
            return "Editing ~/.ssh/config is not available in this build."
        case .executionNotConfigured:
            return "Running commands over SSH is not available in this build."
        case .invalidHostAlias:
            return "The SSH host alias is invalid."
        case .herdrPanelConfigAlreadyCustomized:
            return "The remote herdr config already has an agents table or rows key, so "
                + "localvoxtral left it unchanged. Open Details for the manual remedy."
        case .localHerdrPanelConfigAlreadyCustomized:
            return "This Mac's herdr config already has an agents table or rows key, so "
                + "localvoxtral left it unchanged. Open Details for the manual remedy."
        case .localHerdrConfigEditingNotConfigured:
            return "Editing this Mac's herdr config is not available in this build."
        case .localHerdrConfigUnreadable:
            return "This Mac's herdr config could not be read safely, so localvoxtral "
                + "left it unchanged. Open Details for the manual remedy."
        case .none:
            return failure.describedError
        }
    }
}
