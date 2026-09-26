import Foundation

/// Sidebar status dots for the Integrations section rows (owner decision,
/// 2026-09-07, modelled on CodexBar's provider rows). Pure derivations over
/// state that already has an owner — the pane's own status sentences stay
/// where they are; these answer only "what colour is the row's dot".
///
/// The fixed meanings:
/// - green: detected and set up (dictation joins will work);
/// - yellow: detected, a setup step pending;
/// - grey: not installed / not detected.
package enum IntegrationsSidebarStatus {
    /// The Claude Code row, from the local plugin status. `updateAvailable`
    /// is green, not yellow: the installed plugin joins fine and the update
    /// is optional. `.notInstalled` is yellow — the CLI answered the listing,
    /// so Claude Code is detected and only setup is pending. `.unknown` is
    /// grey: nothing was detected, only the probe failed. `.failedToLoad` is
    /// yellow for the same reason `.notInstalled` is: Claude Code answered,
    /// and a setup step — re-pointing the marketplace — is pending. It is not
    /// green, because a plugin that loads nothing joins nothing.
    package static func claudeDot(pluginStatus: ClaudePluginStatus) -> SettingsStatusDot {
        switch pluginStatus {
        case .installed, .updateAvailable: return .green
        case .notInstalled, .failedToLoad: return .yellow
        case .unknown: return .grey
        }
    }

    /// The opencode row, same shape as the Claude Code row. `.unknown` covers
    /// "no readable opencode config" — which includes "opencode is not
    /// installed" — so it is grey, never yellow.
    package static func opencodeDot(status: OpencodePluginInstallService.Status) -> SettingsStatusDot {
        switch status {
        case .installed, .updateAvailable: return .green
        case .notInstalled, .installedUnlisted, .listedMissing: return .yellow
        case .unknown: return .grey
        }
    }

    /// The Mistral Vibe row, same shape as the opencode row: a half-installed
    /// state is a pending setup step, an unreadable config is grey.
    package static func vibeDot(status: VibeHooksInstallService.Status) -> SettingsStatusDot {
        switch status {
        case .installed, .updateAvailable: return .green
        case .notInstalled, .hooksWithoutShim, .shimWithoutHooks, .conflictingHooks: return .yellow
        case .unknown: return .grey
        }
    }

    /// The Codex row. Green only once a Codex hook has reached the app: Codex
    /// skips an untrusted hook without a word, so an installed plugin alone
    /// proves nothing. Installed but unheard is a pending step (trusting the
    /// hooks), and so is a plugin turned off in Codex.
    package static func codexDot(status: CodexPluginInstallService.Status, hookHeard: Bool) -> SettingsStatusDot {
        if status.joins(hookHeard: hookHeard) { return .green }
        return status == .unknown ? .grey : .yellow
    }

    /// The herdr row: green when found — herdr needs no setup, and the owner
    /// decision pins that "found but no host reported a pane yet" is NOT
    /// yellow. Grey when absent.
    package static func herdrDot(isDetected: Bool) -> SettingsStatusDot {
        isDetected ? .green : .grey
    }

    /// The Remote hosts row: green while at least one enrolled host is not
    /// revoked, grey otherwise. No yellow: there is no detected-but-pending
    /// state for a host that was never enrolled.
    package static func remoteHostsDot(activeHostCount: Int) -> SettingsStatusDot {
        activeHostCount > 0 ? .green : .grey
    }
}
