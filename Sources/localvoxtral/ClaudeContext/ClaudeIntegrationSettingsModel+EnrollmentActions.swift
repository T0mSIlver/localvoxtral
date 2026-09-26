import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    public func dismissPlan() {
        // The plaintext goes with it. Nothing else holds a copy.
        presentedPlan = nil
        enrollmentConfirmation = nil
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
        enrollmentConfirmation = nil
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
            sshConfigSnippet: snippet
        )
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

    /// Stands in for an alias we were never told. It is not a valid target:
    /// `canRun` and `canRunRemoteSetup` withhold every run that would use it.
    static let unknownAliasPlaceholder = "your-ssh-host"

    public func dismissPluginUpdate() {
        switch enrollmentConfirmation?.action {
        case .updateHost?:
            enrollmentConfirmation = nil
        default:
            break
        }
        setupRun = nil
        setupManualInstructions = nil
        presentedPluginUpdate = nil
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
            confirmButtonTitle: "Update Host"
        )
        Log.claudeContext.info("Claude remote host update confirmation requested")
    }

    public func requestHostSetup() {
        guard let presentation = presentedPlan,
              presentation.canRunRemoteSetup,
              !isEnrollmentBusy,
              !presentation.isPreview
        else { return }
        verificationChecks = []
        setupRun = nil
        setupManualInstructions = nil
        enrollmentConfirmation = EnrollmentConfirmation(
            action: .setupHost,
            title: hostSetupConsentSentence(sshHostAlias: presentation.sshHostAlias),
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
        case .setupHost, .updateHost:
            await performSetupRun(confirmation)
        case .configureLocalHerdrPanel:
            await performLocalHerdrPanelConfiguration(confirmation)
        }
    }

    public func cancelSetupRun() {
        guard setupRun != nil, isPerformingEnrollmentAction else { return }
        setupCancellationRequested = true
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

    /// The alert body. `subject` names the work in the user's terms — an alert
    /// that says "SSH setup" after a herdr step failed reads as a different
    /// failure than the one they are looking at.
    static func enrollmentFailureDetail(
        _ failure: ClaudeEnrollmentActionFailure,
        subject: String
    ) -> String {
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
