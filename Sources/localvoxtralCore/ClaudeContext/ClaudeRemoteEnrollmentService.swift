import Foundation

/// Generates and, after a separate UI confirmation, applies the setup for a
/// remote Claude Code host. Both mutation paths are injected so tests cannot
/// reach the real home directory or a real SSH host.
public struct ClaudeRemoteEnrollmentService: Sendable {

    /// Invocation in, result out. The stdin field is load-bearing: the bearer
    /// token must never be placed in argv.
    public typealias Runner = @Sendable (Invocation) throws -> RunResult

    public static let defaultRemoteSetupTimeout: TimeInterval = 60
    package static let maxCapturedOutputBytes = 64 * 1024

    /// Marketplace reference for a remote host, which has no app bundle to
    /// register a local directory from. `claude plugin marketplace add` accepts
    /// an `owner/repo` shorthand, and the repo root carries a
    /// `.claude-plugin/marketplace.json` listing both plugins for exactly this.
    public static let repositoryMarketplaceReference = "T0mSIlver/localvoxtral"

    /// Kept next to the installer that verifies it. A manifest contract test
    /// pins this value to the remote plugin's plugin.json, and another pins
    /// the shim's `X-Lvx-Plugin-Version` header to the same number.
    public static let remotePluginVersion = "1.13.0"

    /// The plugin's sensitive userConfig key. Claude Code exposes it to the
    /// plugin's COMMAND-hook shim as `CLAUDE_PLUGIN_OPTION_TOKEN`; the shim
    /// hands it to curl through a private header file, never an argv. (It is
    /// NOT available to declarative http hooks — Claude Code expands their
    /// header `${VAR}`s from the process environment only, which is why the
    /// plugin uses a command shim at all; verified on 2.1.220.)
    public static let tokenConfigKey = "token"

    /// The plugin's non-sensitive userConfig key: which loopback port on the
    /// REMOTE host the shim posts to. Reaches the shim as
    /// `CLAUDE_PLUGIN_OPTION_PORT` exactly like the token does (both are
    /// command-hook environment; verified end to end on Claude Code 2.1.220 —
    /// a hook run with `--config port=28777` dialed 127.0.0.1:28777).
    ///
    /// It must equal the listen port of this Mac's `RemoteForward`. The plan
    /// always emits both halves together for that reason; changing one alone
    /// fails open, which looks exactly like nothing happening.
    public static let portConfigKey = "port"

    public static let herdrPanelConfigSnippet = """
        [ui.sidebar.agents]
        rows = [["state_icon", "workspace", "tab"], ["agent"], [{ token = "$lvmark", dim = true }]]
        """

    package let runner: Runner?
    /// Whether remote actions can run at all. A row whose button could only
    /// fail should not be drawn.
    public var canExecuteRemotely: Bool { runner != nil }
    package let sshConfigFileSystem: (any ClaudeRemoteSSHConfigFileSystem)?
    /// The LOCAL herdr config writer, for the federated client's panel row.
    /// Nil (the default) disables `configureLocalHerdrPanel`, exactly as a nil
    /// runner disables every remote action.
    package let localHerdrConfigFileSystem: (any ClaudeLocalHerdrConfigFileSystem)?
    package let environmentProbeValue: @Sendable () -> String

    public init(
        runner: Runner? = nil,
        sshConfigFileSystem: (any ClaudeRemoteSSHConfigFileSystem)? = nil,
        localHerdrConfigFileSystem: (any ClaudeLocalHerdrConfigFileSystem)? = nil,
        environmentProbeValue: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.runner = runner
        self.sshConfigFileSystem = sshConfigFileSystem
        self.localHerdrConfigFileSystem = localHerdrConfigFileSystem
        self.environmentProbeValue = environmentProbeValue
    }

    public static var remotePluginReference: String {
        "\(ClaudePluginAssets.remotePluginName)@\(ClaudePluginAssets.marketplaceName)"
    }
}
