import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    public var isRemoteAvailable: Bool { registry != nil }

    // MARK: - Remote hosts

    public func refreshHosts() {
        // One clock reading for the whole list, so two rows of the same age
        // cannot disagree about what "now" was.
        let timestamp = now()
        let enrolledHosts = registry?.hosts() ?? []
        // Whether the update run's shell step would skip. It skips an applied
        // block, and a shell or writer it has none for.
        // Read only when there is a host row to decide for.
        let shellStepSettled: Bool = {
            guard !enrolledHosts.isEmpty else { return true }
            guard let shell = loginShell(), let writer = shellRCWriter(shell) else { return true }
            return writer.isApplied() == true
        }()
        let bundledVibeVersion = vibeRemoteFiles()?.version
        // No ssh runner or no bundled files: the run has no Vibe step, so Vibe
        // never makes it worth offering.
        let vibeStepCanRun = enrollmentService.canExecuteRemotely && bundledVibeVersion != nil
        let withoutVibe = hostsWithoutVibe
        let withoutClaude = hostsWithoutClaude
        hosts = enrolledHosts.map { host in
            let forwardState = forwards?.states[host.id]
            let vibe = vibeStepCanRun
                ? VibeHostHooksState.derive(host: host, bundledVersion: bundledVibeVersion)
                : nil
            // Settled when the last run found no Vibe there, or the host's own
            // hooks reported this build's version. Set up and never heard from
            // is unknown, exactly as for the plugin.
            let vibeSettled = vibe == nil || withoutVibe.contains(host.id)
                || (vibe == .setUp && host.reportedVibeHooksVersion != nil)
            return HostRow(
                id: host.id,
                label: host.label,
                sshHostAlias: host.sshHostAlias,
                isRevoked: host.isRevoked,
                lastSeenAt: host.lastSeenAt,
                statusText: Self.hostStatusText(
                    isRevoked: host.isRevoked, lastSeenAt: host.lastSeenAt, now: timestamp
                ),
                persistentForwardEnabled: host.persistentForwardEnabled,
                // Nil when this host has no forward running, which is not the
                // same as a forward that is off: a row with the toggle off has
                // nothing to report, and a status line saying so would be noise
                // in a list of hosts.
                forwardStatusText: forwardState?.text,
                forwardIsFailure: forwardState?.isFailure ?? false,
                canHoldForward: forwards != nil
                    && !host.isRevoked
                    && host.sshHostAlias.map(ClaudeRemoteEnrollmentService.isValidHostAlias) == true,
                setupStatusText: setupSummaries[host.id],
                // A revoked host cannot authenticate, so its recorded report
                // is stale by construction — and its status position has to
                // keep saying "Revoked", the fact that matters for it.
                pluginNeedsUpdate: !host.isRevoked && (
                    Self.pluginNeedsUpdate(
                        reported: host.reportedPluginVersion,
                        expected: ClaudeRemoteEnrollmentService.remotePluginVersion
                    )
                    || vibe == .updateAvailable
                ),
                offersUpdate: !host.isRevoked && (
                    !(withoutClaude.contains(host.id) || Self.pluginIsCurrent(
                        reported: host.reportedPluginVersion,
                        expected: ClaudeRemoteEnrollmentService.remotePluginVersion
                    ))
                    || expectedSSHConfigSnippet(for: host).flatMap {
                        enrollmentService.sshConfigBlockIsCurrent(snippet: $0, hostID: host.id)
                    } != true
                    || !shellStepSettled
                    || !vibeSettled
                )
            )
        }
        herdrMachines = Self.herdrMachineSection(
            reading: herdrMachineCatalogReading(), enrolledHosts: enrolledHosts
        )
        refreshRejectionHint()
    }

    /// Enroll, then bind — in that order, and both before returning.
    ///
    /// The listener starts here rather than at next launch. "Enroll a host, then
    /// quit and reopen the app" is not a setup step anyone would guess, and the
    /// failure it produces is silent: the tunnel connects to a closed port, the
    /// hook fails open, and the user concludes the feature does not work.
    public func enroll() async {
        guard let registry else { return }
        let label = enrollLabel
        let alias = enrollSSHAlias
        guard ClaudeRemoteEnrollmentService.isValidHostAlias(alias) else {
            alert = DetailAlert(
                title: "Invalid SSH host",
                detail: "\"\(alias)\" is not an SSH host alias. Use the name from your ~/.ssh/config. "
                    + "letters, digits, dots, dashes and underscores only."
            )
            return
        }
        do {
            let enrollment = try registry.enroll(label: label, sshHostAlias: alias)
            let plan = try ClaudeRemoteEnrollmentService.plan(
                host: enrollment.host,
                sshHostAlias: alias,
                token: enrollment.token,
                listenerPort: listener?.boundPort ?? ClaudeRemoteListenerLimits.default.port,
                remoteForwardPort: remoteForwardPort
            )
            // A fresh sheet must not inherit a previous host's step results —
            // a still-running earlier action can repopulate the statuses after
            // dismissPlan() cleared them.
            enrollmentConfirmation = nil
            enrollmentStepStatuses = []
            enrollmentResultsAction = nil
            verificationChecks = []
            presentedPlan = EnrollmentPresentation(
                host: enrollment.host,
                token: enrollment.token,
                sshHostAlias: alias,
                plan: plan,
                isRotation: false,
                remoteForwardPort: remoteForwardPort
            )
            enrollLabel = ""
            enrollSSHAlias = ""
            refreshHosts()
            reconcileListener()
        } catch {
            presentRegistryFailure(error, verb: "enroll")
        }
    }

    /// Issue a new token for an existing host and show it once.
    public func rotate(hostID: String) async {
        guard let registry else { return }
        do {
            let enrollment = try registry.rotateToken(hostID: hostID)
            // The alias the user enrolled with, or nothing. The label is NOT a
            // fallback: name and alias are separate fields, so `prod` named
            // over alias `builder` would have sent the new token to whatever
            // answers to `prod` (review finding, PR #197). A host enrolled
            // before the alias was persisted gets the placeholder and cannot
            // run setup until it is re-enrolled with an explicit alias.
            let alias = enrollment.host.sshHostAlias
            let plan = try ClaudeRemoteEnrollmentService.plan(
                host: enrollment.host,
                sshHostAlias: alias ?? Self.unknownAliasPlaceholder,
                token: enrollment.token,
                listenerPort: listener?.boundPort ?? ClaudeRemoteListenerLimits.default.port,
                remoteForwardPort: remoteForwardPort
            )
            enrollmentConfirmation = nil
            enrollmentStepStatuses = []
            enrollmentResultsAction = nil
            verificationChecks = []
            presentedPlan = EnrollmentPresentation(
                host: enrollment.host,
                token: enrollment.token,
                sshHostAlias: alias ?? Self.unknownAliasPlaceholder,
                plan: plan,
                isRotation: true,
                canRunRemoteSetup: alias != nil,
                remoteForwardPort: remoteForwardPort
            )
            refreshHosts()
            // Rotation reinstates a revoked host, so it can be a 0→1 transition.
            reconcileListener()
        } catch {
            presentRegistryFailure(error, verb: "rotate the token for")
        }
    }

    /// Turn the app-held forward on or off for one host.
    ///
    /// Order matters and is the same as everywhere else in this feature: the
    /// registry is the source of truth, so it is written FIRST and the
    /// coordinator reconciles against what was actually persisted. A coordinator
    /// started before the write could be left running a forward for a flag that
    /// never made it to disk.
    public func setPersistentForward(_ enabled: Bool, hostID: String) {
        guard let registry else { return }
        do {
            try registry.setPersistentForwardEnabled(enabled, hostID: hostID)
            forwards?.reconcile()
            refreshHosts()
        } catch {
            presentRegistryFailure(error, verb: enabled ? "enable the tunnel for" : "disable the tunnel for")
        }
    }

    /// Retry one host's failed forward — the move after freeing the port.
    public func retryPersistentForward(hostID: String) {
        forwards?.retry(hostID: hostID)
        refreshHosts()
    }

    public func revoke(hostID: String) async {
        guard let registry else { return }
        do {
            try registry.revoke(hostID: hostID)
            refreshHosts()
            reconcileListener()
        } catch {
            presentRegistryFailure(error, verb: "revoke")
        }
    }

    /// Remove reverses the Mac side of enrollment — this host's ssh-config
    /// block, and the shell startup block only when no other host remains —
    /// and then revokes.
    ///
    /// Reversal NEVER blocks the revocation: the registry entry is the off
    /// switch, and a host whose block could not be edited (a symlinked
    /// `~/.ssh/config`, an unwritable rc) is exactly a host the user must be
    /// able to turn off. A failed reversal is reported in the alert with the
    /// manual cleanup instead; the remote uninstall commands ride along, as
    /// the sheet and docs always offered them.
    public func remove(hostID: String) async {
        guard let registry else { return }
        let isLastHost = registry.hosts().allSatisfy { $0.id == hostID }
        var manualNotes: [String] = []

        if enrollmentService.canEditSSHConfig {
            let service = enrollmentService
            let attempt = await performEnrollmentAsync {
                try service.removeSSHConfig(hostID: hostID)
                return []
            }
            if let failure = attempt.failure {
                Log.claudeContext.error(
                    "Claude remote host removal could not rewrite ~/.ssh/config: \(failure.describedError, privacy: .public)"
                )
                manualNotes.append(
                    "This host's block is still in ~/.ssh/config.\n\n"
                        + Self.enrollmentFailureDetail(failure, action: .insertSSHConfig)
                )
            }
        }

        if isLastHost, let shell = loginShell(), let writer = shellRCWriter(shell) {
            if let failure = await performAsync({ try writer.remove() }) {
                Log.claudeContext.error(
                    "Claude remote host removal could not rewrite the shell startup file: \(failure.describedError, privacy: .public)"
                )
                manualNotes.append(
                    "The LC_LVX_TTY block is still in your shell startup file.\n\n"
                        + failure.describedError
                )
            }
        }

        do {
            try registry.remove(hostID: hostID)
            // The row is going away; its open update panel must not outlive it.
            if presentedPluginUpdate?.hostID == hostID { dismissPluginUpdate() }
            refreshHosts()
            reconcileListener()
            if !manualNotes.isEmpty {
                alert = DetailAlert(
                    title: "Remote host removed",
                    detail: (manualNotes + ["Remove those blocks by hand to finish the cleanup."])
                        .joined(separator: "\n\n")
                )
            }
        } catch {
            presentRegistryFailure(error, verb: "remove")
        }
    }

    private func presentRegistryFailure(_ error: any Error, verb: String) {
        alert = DetailAlert(
            title: "Remote Claude Code context",
            detail: "Could not \(verb) the host.\n\n\(Self.registryFailureDetail(error))"
        )
        Log.claudeContext.error(
            "Claude remote host \(verb, privacy: .public) failed: \(String(describing: error), privacy: .public)"
        )
    }

    static func registryFailureDetail(_ error: any Error) -> String {
        if let pathFailure = error as? ClaudeSocketGuard.PreconditionFailure {
            switch pathFailure {
            case .permissive(let path, _):
                return "The private host-list folder at \(path) has unsafe permissions."
            case .isSymlink(let path):
                return "The host-list path at \(path) is a symbolic link and was refused."
            case .wrongOwner(let path, _, _):
                return "The host-list path at \(path) is owned by another user."
            case .notADirectory(let path):
                return "The host-list folder path at \(path) is not a directory."
            case .cannotCreate(let path, _):
                return "localvoxtral could not prepare the private host-list folder at \(path)."
            }
        }
        switch error as? ClaudeRemoteHostRegistry.StoreError {
        case .invalidLabel:
            return "The name needs at least one letter or digit."
        case .tooManyHosts(let limit):
            return "You have reached the limit of \(limit) enrolled hosts. Remove one first."
        case .writeFailed(let path):
            return "localvoxtral could not save the host list to \(path)."
        case .unreadable(let path):
            return "The host list at \(path) could not be read."
        case .unsupportedVersion:
            return "The host list was written by a newer version of localvoxtral."
        case .hostRevoked:
            return "This host is revoked. Rotate its token first."
        case .hostCredentialChanged:
            return "This host's token was rotated during setup. Run the Vibe hooks setup again."
        case .unknownHost, .idAllocationFailed, .none:
            return String(describing: error)
        }
    }
}
