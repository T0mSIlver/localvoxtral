import ClaudeContextWire
import Foundation

/// The plugin half of the Settings surface, as a seam.
///
/// `ClaudePluginInstallService` is a struct that shells out to `claude`; this
/// protocol is what the Settings model actually depends on, so a test can drive
/// every branch — success, CLI absent, command failed — without a Claude Code
/// install on the machine. On CI the build host HAS Claude Code, which is
/// exactly what makes "reports when the CLI is missing" untestable against the
/// real thing.
public protocol ClaudePluginInstalling: Sendable {
    func installPlugin() throws
    func updatePlugin() throws
    /// Update an installed plugin in place, never uninstalling it.
    func updateInstalledPlugin() throws
    func uninstallPlugin() throws
    /// stdout of `claude plugin list`, or nil when the listing is unavailable.
    /// Default nil so test doubles that only exercise install paths keep
    /// working; the pane then reports `.unknown` rather than guessing.
    func pluginListOutput() throws -> String?
    /// stdout of `claude plugin marketplace list --json`, or nil when it is
    /// unavailable. Same default, same reason.
    func marketplaceListOutput() throws -> String?
    /// Re-point the marketplace registration at this app's own copy, without
    /// touching the installed plugin.
    func repairMarketplaceRegistration() throws
}

extension ClaudePluginInstalling {
    public func pluginListOutput() throws -> String? { nil }
    public func marketplaceListOutput() throws -> String? { nil }
    /// A double that does not model the registration cannot repair one. The
    /// launch path only calls this after a listing said repair is needed, and
    /// a double that answers no listing never gets there.
    public func repairMarketplaceRegistration() throws {}
}

extension ClaudePluginInstallService: ClaudePluginInstalling {}
