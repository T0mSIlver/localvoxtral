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
enum IntegrationsSidebarStatus {
    /// The Claude Code row, from the local plugin status. `updateAvailable`
    /// is green, not yellow: the installed plugin joins fine and the update
    /// is optional. `.notInstalled` is yellow — the CLI answered the listing,
    /// so Claude Code is detected and only setup is pending. `.unknown` is
    /// grey: nothing was detected, only the probe failed. `.failedToLoad` is
    /// yellow for the same reason `.notInstalled` is: Claude Code answered,
    /// and a setup step — re-pointing the marketplace — is pending. It is not
    /// green, because a plugin that loads nothing joins nothing.
    static func claudeDot(pluginStatus: ClaudePluginStatus) -> SettingsStatusDot {
        switch pluginStatus {
        case .installed, .updateAvailable: return .green
        case .notInstalled, .failedToLoad: return .yellow
        case .unknown: return .grey
        }
    }

    /// The opencode row, same shape as the Claude Code row. `.unknown` covers
    /// "no readable opencode config" — which includes "opencode is not
    /// installed" — so it is grey, never yellow.
    static func opencodeDot(status: OpencodePluginInstallService.Status) -> SettingsStatusDot {
        switch status {
        case .installed, .updateAvailable: return .green
        case .notInstalled, .installedUnlisted, .listedMissing: return .yellow
        case .unknown: return .grey
        }
    }

    /// The Mistral Vibe row, same shape as the opencode row: a half-installed
    /// state is a pending setup step, an unreadable config is grey.
    static func vibeDot(status: VibeHooksInstallService.Status) -> SettingsStatusDot {
        switch status {
        case .installed, .updateAvailable: return .green
        case .notInstalled, .hooksWithoutShim, .shimWithoutHooks: return .yellow
        case .unknown: return .grey
        }
    }

    /// The herdr row: green when found — herdr needs no setup, and the owner
    /// decision pins that "found but no host reported a pane yet" is NOT
    /// yellow. Grey when absent.
    static func herdrDot(isDetected: Bool) -> SettingsStatusDot {
        isDetected ? .green : .grey
    }

    /// The Remote hosts row: green while at least one enrolled host is not
    /// revoked, grey otherwise. No yellow: there is no detected-but-pending
    /// state for a host that was never enrolled.
    static func remoteHostsDot(activeHostCount: Int) -> SettingsStatusDot {
        activeHostCount > 0 ? .green : .grey
    }
}
