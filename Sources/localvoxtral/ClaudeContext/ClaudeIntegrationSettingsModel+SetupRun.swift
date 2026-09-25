import ClaudeContextWire
import Foundation

#if canImport(Darwin)
import Darwin
import Synchronization
#endif

extension ClaudeIntegrationSettingsModel {
    func performSetupRun(_ confirmation: EnrollmentConfirmation) async {
        let hostID: String
        let alias: String
        let snippet: String?
        let token: String?
        switch confirmation.action {
        case .setupHost:
            guard let presentation = presentedPlan, !presentation.isPreview else { return }
            hostID = presentation.host.id
            alias = presentation.sshHostAlias
            snippet = presentation.plan.sshConfigSnippet
            token = presentation.token
        case .updateHost(let requestedHostID):
            guard let presentation = presentedPluginUpdate,
                  presentation.hostID == requestedHostID,
                  let presentationAlias = presentation.sshHostAlias
            else { return }
            hostID = requestedHostID
            alias = presentationAlias
            // Current when the panel opened is not current now: regenerate, and
            // let the fresh read below decide whether to write.
            snippet = presentation.sshConfigSnippet
                ?? registry?.host(id: requestedHostID).flatMap(expectedSSHConfigSnippet(for:))
            token = nil
        default:
            return
        }

        enrollmentConfirmation = nil
        isPerformingEnrollmentAction = true
        setupCancellationRequested = false
        setupManualInstructions = nil
        setupRun = RemoteHostSetupRun(hostID: hostID, startedAt: now())
        setupSummaries[hostID] = "Setup is running."
        // Steps this run leaves to the user, for the row's sentence once the
        // panel that explains them has closed.
        var manualSteps: [RemoteHostSetupRun.Step] = []
        refreshHosts()
        defer { isPerformingEnrollmentAction = false }

        let service = enrollmentService
        let port = remoteForwardPort
        // Skip the write only when the file already holds this exact block.
        let snippetToApply = snippet.flatMap {
            service.sshConfigBlockIsCurrent(snippet: $0, hostID: hostID) == true ? nil : $0
        }

        markSetup(.sshConfig, .running)
        let sshAttempt = await performEnrollmentAsync {
            if let snippetToApply {
                try service.insertSSHConfig(snippet: snippetToApply, hostID: hostID)
            }
            return []
        }
        if let failure = sshAttempt.failure {
            failSetup(
                .sshConfig,
                reason: "Could not update this Mac's SSH config.",
                remedy: Self.enrollmentFailureDetail(failure, subject: "SSH setup")
            )
            return
        }
        markSetup(
            .sshConfig,
            .done(
                snippetToApply == nil
                    ? "The SSH config block is already current."
                    : "The SSH config block is current."
            )
        )
        guard continueSetup(hostID: hostID) else { return }

        markSetup(.shellStartup, .running)
        if let shell = loginShell(), let writer = shellRCWriter(shell) {
            // Current, not merely present: an older block is rewritten here.
            if writer.isCurrent(shell: shell) == true {
                markSetup(.shellStartup, .done("The shell startup block is already applied."))
            } else {
                let shellFailure = await performAsync { try writer.apply(shell: shell) }
                if let shellFailure {
                    setupManualInstructions = "Open Details for manual shell setup."
                    manualSteps.append(.shellStartup)
                    markSetup(
                        .shellStartup,
                        .skipped("The shell startup file was left unchanged; see Details.")
                    )
                    Log.claudeContext.error(
                        "Claude remote setup skipped shell startup edit: \(shellFailure.describedError, privacy: .public)"
                    )
                } else {
                    markSetup(.shellStartup, .done("The shell startup block is applied."))
                }
            }
        } else {
            setupManualInstructions = "Open Details for manual shell setup."
            manualSteps.append(.shellStartup)
            markSetup(
                .shellStartup,
                .skipped("This login shell is not supported for automatic setup; configure it manually.")
            )
        }
        refreshShellSetupStatus()
        guard continueSetup(hostID: hostID) else { return }

        markSetup(.remotePlugin, .running)
        let pluginAttempt = await performEnrollmentAsync {
            let outcome = try service.setupRemotePlugin(
                sshHostAlias: alias, token: token, remoteForwardPort: port
            )
            return [.init(index: 0, command: "remote plugin", message: String(describing: outcome))]
        }
        if let failure = pluginAttempt.failure {
            failSetup(
                .remotePlugin,
                reason: "The remote plugin could not be installed or updated.",
                remedy: Self.enrollmentFailureDetail(failure, subject: "SSH setup")
            )
            return
        }
        // A successful `setupRemotePlugin` return already PROVED the installed
        // version by decoded read-back, so record it here: the row's update
        // indicator must clear on this run, not at the host's next hook (the
        // host may not run another hook for hours, and the user is looking at
        // the row right now).
        let claudeFound = pluginAttempt.steps.first?.message != "claudeNotFound"
        if claudeFound {
            hostsWithoutClaude.remove(hostID)
            registry?.notePluginVersion(
                hostID: hostID,
                .version(ClaudeRemoteEnrollmentService.remotePluginVersion)
            )
        } else {
            hostsWithoutClaude.insert(hostID)
        }
        switch pluginAttempt.steps.first?.message {
        case "claudeNotFound":
            markSetup(.remotePlugin, .skipped("Claude Code is not installed on the remote host."))
        case "installed": markSetup(.remotePlugin, .done("The remote plugin was installed and verified."))
        case "updated": markSetup(.remotePlugin, .done("The remote plugin was updated and verified."))
        default: markSetup(.remotePlugin, .done("The remote plugin is already current and verified."))
        }
        guard continueSetup(hostID: hostID) else { return }

        markSetup(.environmentCrossing, .running)
        let environmentAttempt = await performEnrollmentAsync {
            let outcome = try service.probeRemoteEnvironment(sshHostAlias: alias)
            return [.init(index: 0, command: "environment probe", message: String(describing: outcome))]
        }
        if let failure = environmentAttempt.failure {
            failSetup(
                .environmentCrossing,
                reason: "The terminal environment check could not run.",
                remedy: Self.enrollmentFailureDetail(failure, subject: "SSH setup")
            )
            return
        }
        switch environmentAttempt.steps.first?.message {
        case "crossed":
            markSetup(.environmentCrossing, .done("LC_LVX_TTY crossed the SSH connection."))
        case "localSendEnvMissing":
            failSetup(
                .environmentCrossing,
                reason: "This Mac is not sending LC_LVX_TTY for this SSH host.",
                remedy: "Open Details and follow the SSH environment setup."
            )
            return
        default:
            failSetup(
                .environmentCrossing,
                reason: "The remote SSH server did not accept LC_LVX_TTY.",
                remedy: "Open Details and follow the remote SSH server setup."
            )
            return
        }
        guard continueSetup(hostID: hostID) else { return }

        markSetup(.remoteHerdr, .running)
        let herdrAttempt = await performEnrollmentAsync {
            let outcome = try service.setupRemoteHerdr(sshHostAlias: alias)
            return [.init(index: 0, command: "remote herdr", message: String(describing: outcome))]
        }
        if let failure = herdrAttempt.failure {
            failSetup(
                .remoteHerdr,
                reason: "Remote herdr setup failed.",
                remedy: Self.enrollmentFailureDetail(failure, subject: "Herdr panel setup")
            )
            return
        }
        switch herdrAttempt.steps.first?.message {
        case "notFound":
            markSetup(.remoteHerdr, .skipped("herdr is not installed on the remote host."))
        case "customized":
            setupManualInstructions = "The remote herdr table is customized; open Details to update it manually."
            manualSteps.append(.remoteHerdr)
            markSetup(.remoteHerdr, .skipped("The existing herdr agents table was left unchanged."))
        default:
            markSetup(.remoteHerdr, .done("The remote herdr agents panel is configured."))
        }
        guard continueSetup(hostID: hostID) else { return }

        markSetup(.remoteVibe, .running)
        // Set up, and the host's own hooks (or the last run) reported this
        // build's version: leave it alone. Running anyway would replace a
        // working token under live Vibe sessions, and let a refusal that is
        // only about ~/.vibe fail an update the user started for the plugin.
        let vibeIsCurrent = registry?.host(id: hostID).map { host in
            host.reportedVibeHooksVersion != nil
                && VibeHostHooksState.derive(host: host, bundledVersion: vibeRemoteFiles()?.version) == .setUp
        } ?? false
        if vibeIsCurrent {
            markSetup(.remoteVibe, .done("The Vibe hooks are already current."))
        } else if let registry, let files = vibeRemoteFiles() {
            let found = Mutex(true)
            let vibeFailure = await performAsync {
                try ClaudeRemoteEnrollmentService.describingVibeFailures {
                    // Bound to the host's token as it is NOW: a Rotate token
                    // pressed while ssh runs makes the commit below refuse.
                    let pending = try registry.prepareCredential(hostID: hostID, purpose: .vibe)
                    let outcome = try service.setUpRemoteVibeHooks(
                        sshHostAlias: alias, token: pending.token,
                        remoteForwardPort: port, files: files,
                        beforeTokenActivation: { try registry.commitCredential(pending, hostID: hostID) }
                    )
                    guard outcome != .vibeNotFound else {
                        found.withLock { $0 = false }
                        return
                    }
                    try registry.retireOtherCredentials(hostID: hostID, keeping: pending)
                }
            }
            if let vibeFailure {
                failSetup(
                    .remoteVibe,
                    reason: "The Vibe hooks could not be installed or updated.",
                    remedy: vibeFailure.describedError
                )
                return
            }
            if found.withLock({ $0 }) {
                hostsWithoutVibe.remove(hostID)
                // The run read the installed version back, so the row settles
                // now rather than at the host's next Vibe hook.
                if let version = files.version { registry.noteVibeHooksVersion(hostID: hostID, version) }
                markSetup(.remoteVibe, .done("The Vibe hooks are installed and verified."))
            } else {
                hostsWithoutVibe.insert(hostID)
                guard claudeFound else {
                    failNoAgent(.remoteVibe)
                    return
                }
                markSetup(.remoteVibe, .skipped("Mistral Vibe is not installed on the remote host."))
            }
        } else {
            guard claudeFound else {
                failNoAgent(.remoteVibe)
                return
            }
            markSetup(.remoteVibe, .skipped("This build carries no Vibe hook files."))
        }
        guard continueSetup(hostID: hostID) else { return }

        markSetup(.checkSetup, .running)
        let listenerWasBound = listenerIsBound
        let checkAttempt = await performVerificationAsync {
            try service.executeVerification(
                sshHostAlias: alias,
                remoteForwardPort: port,
                listenerIsBound: listenerWasBound,
                includesPluginCheck: claudeFound
            )
        }
        if let failure = checkAttempt.failure {
            failSetup(
                .checkSetup,
                reason: "The final setup check could not run.",
                remedy: Self.verificationFailureDetail(failure)
            )
            return
        }
        verificationChecks = ClaudeRemoteEnrollmentService.reconciled(
            checkAttempt.checks,
            remoteForwardPort: port,
            listenerIsBound: listenerIsBound
        )
        if let failed = verificationChecks.first(where: { !$0.passed }) {
            failSetup(
                .checkSetup,
                reason: failed.summary,
                remedy: failed.hint ?? failed.detail
            )
            return
        }
        markSetup(
            .checkSetup,
            .done(claudeFound ? "The tunnel and remote plugin checks passed." : "The tunnel check passed.")
        )
        // A step the run left to the user outlives the panel in the row's
        // one sentence, since the panel is about to close.
        setupSummaries[hostID] = manualSteps.isEmpty
            ? "Setup complete."
            : "Setup complete. Still manual: \(manualSteps.map(\.title).joined(separator: ", ")). See Learn more."
        // A finished update has nothing left to show, so its panel closes and
        // the row is one line again. A failed one stays open: its reason and
        // remedy are in the steps. `setupRun` is kept for the record.
        if case .updateHost = confirmation.action { presentedPluginUpdate = nil }
        refreshHosts()
        Log.claudeContext.info("Claude remote host setup completed")
    }

    /// Neither agent is on the host, so the run has installed nothing that
    /// could ever send context.
    private func failNoAgent(_ step: RemoteHostSetupRun.Step) {
        // Not settled: the remedy is to install an agent and run this again,
        // so the row has to keep offering the run.
        if let hostID = setupRun?.hostID {
            hostsWithoutVibe.remove(hostID)
            hostsWithoutClaude.remove(hostID)
        }
        failSetup(
            step,
            reason: "No supported agent was found on the remote host.",
            remedy: "Install Claude Code or Mistral Vibe there, or put it on the non-interactive SSH PATH, "
                + "then run setup again."
        )
    }

    private func markSetup(_ step: RemoteHostSetupRun.Step, _ state: RemoteHostSetupRun.State) {
        guard let index = setupRun?.items.firstIndex(where: { $0.step == step }) else { return }
        setupRun?.items[index].state = state
    }

    private func failSetup(
        _ step: RemoteHostSetupRun.Step,
        reason: String,
        remedy: String
    ) {
        markSetup(step, .failed(reason: reason, remedy: remedy))
        if let hostID = setupRun?.hostID {
            setupSummaries[hostID] = "Setup stopped at \(step.title)."
        }
        refreshHosts()
        alert = DetailAlert(title: step.title, detail: "\(reason)\n\n\(remedy)")
        Log.claudeContext.error(
            "Claude remote host setup stopped at \(step.title, privacy: .public): \(reason, privacy: .public)"
        )
    }

    private func continueSetup(hostID: String) -> Bool {
        guard setupCancellationRequested else { return true }
        if var run = setupRun {
            for index in run.items.indices where run.items[index].state == .pending {
                run.items[index].state = .skipped("Setup was cancelled.")
            }
            setupRun = run
        }
        setupSummaries[hostID] = "Setup cancelled."
        refreshHosts()
        Log.claudeContext.info("Claude remote host setup cancelled")
        return false
    }
}
