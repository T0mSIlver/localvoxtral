import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: - Shell setup for the plain-ssh join

    /// Re-read both halves. Cheap: one `lstat`+read of one rc file, and one
    /// registry query. Called with the rest of the pane's refresh.
    public func refreshShellSetupStatus() {
        guard let shell = loginShell() else {
            shellSetupStatus = ClaudeShellSetupStatus(
                rc: .unsupportedShell, crossing: liveLocalTTYReport()
            )
            return
        }
        let writer = shellRCWriter(shell)
        let reading = writer?.reading(shell: shell)
        let rc: ClaudeShellSetupStatus.RCState
        switch reading?.block {
        case .current?: rc = .applied
        case .outdated?: rc = .outdated
        case .absent?: rc = .notApplied
        case nil: rc = .unknown
        }
        shellSetupStatus = ClaudeShellSetupStatus(
            rc: rc,
            isSymlinked: reading?.isSymlinked ?? false,
            crossing: liveLocalTTYReport(),
            relativeRCPath: ClaudeShellRCSetup.relativeRCPath(for: shell) { relative in
                FileManager.default.fileExists(
                    atPath: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(relative).path
                )
            }
        )
    }

    /// Generated shell text retained for the writer and its test seam.
    public var shellSetupPreview: String? {
        guard let shell = loginShell() else { return nil }
        return ClaudeShellRCSetup.snippet(for: shell)
    }

    public var canApplyShellSetup: Bool { loginShell() != nil }

    public var shellSetupConsentSentence: String {
        "localvoxtral will edit \(shellRCPathForConsent()) on this Mac."
    }

    public func hostSetupConsentSentence(sshHostAlias: String) -> String {
        "localvoxtral will edit ~/.ssh/config and \(shellRCPathForConsent()) on this Mac "
            + "and install its Claude Code plugin on \(sshHostAlias), plus its Mistral Vibe hooks "
            + "if Vibe is installed there."
    }

    /// Write the block. Consent is the CALLER's to obtain, immediately before.
    public func applyShellSetup() async {
        guard let shell = loginShell(), let writer = shellRCWriter(shell) else { return }
        await performShellRCEdit { try writer.apply(shell: shell) }
    }

    public func removeShellSetup() async {
        guard let shell = loginShell(), let writer = shellRCWriter(shell) else { return }
        await performShellRCEdit { try writer.remove() }
    }

    private func performShellRCEdit(_ body: @escaping @Sendable () throws -> Void) async {
        let failure = await performAsync { try body() }
        if let failure {
            // The pane shows one short line; the detail belongs in the alert
            // (owner rule), and this is the one place the symlink refusal
            // becomes visible to a dotfiles user.
            alert = DetailAlert(
                title: "Could not update your shell startup file",
                detail: failure.describedError
            )
        }
        refreshShellSetupStatus()
    }
}
