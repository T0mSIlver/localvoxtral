import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: - Step 3: check the setup

    /// Run the read-only checks and publish their verdicts.
    ///
    /// This replaced three copy-paste commands wrapped in a dozen comment lines
    /// telling the user how to read their output. It needs no confirmation
    /// step, unlike step 1 and step 2: it writes nothing, on either machine.
    ///
    /// The local half of the tunnel verdict is decided HERE, because it is a
    /// fact about this Mac: a 401 arriving through the forward proves only that
    /// something on this side answered, and when our own bind failed that
    /// something is the squatter holding the port (review finding, round 1).
    public func runVerification() async {
        guard let presentation = presentedPlan,
              !isEnrollmentBusy,
              !presentation.isPreview,
              // Same gate as one-click setup, for the same reason: with no
              // alias on file the sheet shows a placeholder, and checking
              // `your-ssh-host` would report on whatever machine happens to
              // answer to that name — a wrong answer that looks like an answer
              // (review finding, round 2).
              presentation.canRunRemoteSetup
        else { return }
        isPerformingVerification = true
        verificationChecks = []
        defer { isPerformingVerification = false }

        let service = enrollmentService
        let alias = presentation.sshHostAlias
        // Probe the tunnel that EXISTS, not the one the plan describes.
        //
        // The plan names this install's current allocation, but `~/.ssh/config`
        // may still forward what an earlier install — or the pre-#215 shared
        // 8473 — wrote there, and that is the port the user's live sessions are
        // actually binding. Probing the plan's port in that state answers "no
        // tunnel is live" about a tunnel that is perfectly alive, turning a
        // one-step fix into a mystery (review finding, round 3). A read-only
        // scan of this host's own block settles it; when the config is absent
        // or unreadable there is nothing better than the plan's port.
        let allocated = presentation.remoteForwardPort
        let configured = service.sshConfigForwardState(hostID: presentation.host.id)
        let port: UInt16
        let staleAllocatedPort: UInt16?
        switch configured {
        case .forwards(let configuredPort) where configuredPort != allocated:
            port = configuredPort
            staleAllocatedPort = allocated
        case .forwards, .absent, .unknown:
            port = allocated
            staleAllocatedPort = nil
        }
        let listenerWasBoundAtLaunch = listenerIsBound
        let attempt = await performVerificationAsync {
            try service.executeVerification(
                sshHostAlias: alias,
                remoteForwardPort: port,
                listenerIsBound: listenerWasBoundAtLaunch,
                staleAllocatedPort: staleAllocatedPort
            )
        }

        // The sheet can be dismissed — and replaced by a rotation that REUSES
        // the host id — while ssh is still running, so the whole presentation
        // must match, not just the host id.
        guard presentedPlan == presentation else { return }

        if let failure = attempt.failure {
            verificationChecks = []
            alert = DetailAlert(
                title: "Check setup",
                detail: Self.verificationFailureDetail(failure)
            )
            Log.claudeContext.error(
                "Claude remote verification failed: \(failure.describedError, privacy: .public)"
            )
            return
        }

        // No redaction step, and none is possible: after a rotation the token a
        // host still has configured is one this process no longer knows. The
        // service therefore never puts probe output in a check at all, which is
        // the only form of that guarantee that survives rotation.
        //
        // The listener fact is read again HERE, on the main actor, after the
        // probes returned: the value handed to the service is up to a full
        // timeout old, and a listener that died in the meantime leaves the port
        // to whoever takes it next — whose 401 is indistinguishable from ours
        // over the wire. The ✓ requires bound at both moments (review finding,
        // round 2).
        verificationChecks = ClaudeRemoteEnrollmentService.reconciled(
            attempt.checks,
            remoteForwardPort: port,
            listenerIsBound: listenerIsBound
        )

        let failed = verificationChecks.filter { !$0.passed }
        guard !failed.isEmpty else { return }
        // Owner rule: the sheet shows one short line per check; the diagnostics
        // belong in the alert and the log.
        alert = DetailAlert(
            title: "Check setup",
            detail: failed
                .map { check in
                    let hint = check.hint.map { " \($0)" } ?? ""
                    return check.detail.isEmpty
                        ? "\(check.title): \(check.summary)\(hint)"
                        : "\(check.title): \(check.summary)\(hint)\n\n\(check.detail)"
                }
                .joined(separator: "\n\n")
        )
        Log.claudeContext.error(
            "Claude remote verification reported \(failed.count, privacy: .public) failed check(s)"
        )
    }

    /// Why a check could not run at all.
    ///
    /// Deliberately NOT routed through `enrollmentFailureDetail`: that one is
    /// written for an action that writes ("SSH setup exited with…"), and it is
    /// keyed on an `EnrollmentAction` a check does not have. Verification can
    /// only throw two things, and everything else here is a "should not happen"
    /// that must still say something true.
    static func verificationFailureDetail(_ failure: ClaudeEnrollmentActionFailure) -> String {
        switch failure.serviceError {
        case .executionNotConfigured:
            return "Checking the setup is not available in this build."
        case .invalidHostAlias:
            return "This host has no usable SSH alias, so there is nothing to check."
        default:
            return "The check could not run."
        }
    }
}
