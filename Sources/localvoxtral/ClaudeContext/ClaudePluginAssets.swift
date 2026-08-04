import Foundation

/// Locates the bundled Claude Code marketplace directory.
///
/// The marketplace lives at `integrations/claude-code/` in the repo and is
/// copied by `package_app.sh` to `Contents/Resources/claude-code-marketplace`.
/// It is NOT a SwiftPM resource: SwiftPM cannot declare a resource outside its
/// target directory, and duplicating the tree to satisfy it would give us two
/// sources of truth for a user-installable artifact.
///
/// Resolution mirrors `Bundle.localvoxtralResources` (AppResourceBundle.swift):
/// packaged location first, dev fallback second. The dev fallback walks up from
/// `#filePath` rather than using `Bundle.module`'s builder-absolute `.build`
/// path — the trap behind #87, where a same-machine CI smoke masked a lookup
/// that `fatalError`s on every other machine.
public enum ClaudePluginAssets {
    /// This declaration's path, captured here rather than in a default
    /// argument. `#filePath` in a default argument expands at the call site,
    /// where a test file at a different depth would walk past the repo root.
    static let assetsSourceFile = #filePath
    /// Directory name inside `Contents/Resources`.
    public static let packagedDirectoryName = "claude-code-marketplace"
    /// Repo-relative source of truth.
    public static let repositoryRelativePath = "integrations/claude-code"
    /// Plugin name, as it appears in marketplace.json. Installed on the machine
    /// running the app; publishes over the local AF_UNIX socket.
    public static let pluginName = "localvoxtral"
    /// The second plugin in the same marketplace, installed on a REMOTE host.
    ///
    /// Structurally separate from `pluginName` and not a mode of it: its shim
    /// curls the tunnelled loopback listener rather than running the publisher
    /// binary, it authenticates with a token instead of peer credentials, and
    /// the context it delivers is opaque. One plugin with a switch would put
    /// those two trust models one config typo apart.
    public static let remotePluginName = "localvoxtral-remote"
    /// Marketplace name, as it appears in marketplace.json.
    public static let marketplaceName = "localvoxtral"

    /// The marketplace root — the directory containing `.claude-plugin/`.
    /// Nil when neither location holds a valid marketplace.
    ///
    /// `resourcesURL` is a plain URL rather than a `Bundle` so the packaged arm
    /// is testable against a fixture directory. Constructing a `Bundle` around
    /// an arbitrary directory has murky `resourceURL` semantics, and a test
    /// that depended on them would be testing Foundation, not this lookup.
    public static func marketplaceURL(resourcesURL: URL? = Bundle.main.resourceURL) -> URL? {
        if let resourcesURL {
            let packaged = resourcesURL.appendingPathComponent(packagedDirectoryName)
            if isMarketplace(packaged) { return packaged }
        }
        if let development = developmentMarketplaceURL(), isMarketplace(development) {
            return development
        }
        return nil
    }

    /// A directory is a marketplace only if the manifest Claude Code reads is
    /// actually there. Existence of the directory proves nothing — a partial
    /// copy in `package_app.sh` would otherwise resolve and then fail at
    /// `claude plugin marketplace add` time with a worse message.
    public static func isMarketplace(_ url: URL) -> Bool {
        let manifest = url
            .appendingPathComponent(".claude-plugin")
            .appendingPathComponent("marketplace.json")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    /// Repo checkout fallback, for `swift run`/`swift test`.
    static func developmentMarketplaceURL(
        sourceFile: String = ClaudePluginAssets.assetsSourceFile
    ) -> URL? {
        repositoryRootURL(sourceFile: sourceFile)?
            .appendingPathComponent(repositoryRelativePath)
    }

    /// The repo root's own marketplace.
    ///
    /// A REMOTE host has no app bundle, so it cannot register a local directory
    /// the way the Mac does — it needs `claude plugin marketplace add
    /// T0mSIlver/localvoxtral`, and Claude Code looks for `.claude-plugin/` at
    /// the repository ROOT for that. Hence two manifests: the bundled one under
    /// `integrations/claude-code/` that the app registers by path, and this one
    /// that GitHub serves. They list the same two plugins with paths rewritten
    /// for their own depth; the manifest test pins them to each other so they
    /// cannot drift.
    static func rootMarketplaceURL(sourceFile: String = ClaudePluginAssets.assetsSourceFile) -> URL? {
        repositoryRootURL(sourceFile: sourceFile)
    }

    static func repositoryRootURL(sourceFile: String) -> URL? {
        // .../Sources/localvoxtral/ClaudeContext/ClaudePluginAssets.swift
        URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent() // ClaudeContext
            .deletingLastPathComponent() // localvoxtral
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
    }

    // MARK: opencode

    /// Repo-relative home of the opencode integration: one dependency-free JS
    /// file plus its README. Not packaged into the app bundle yet — install
    /// is manual (copy + a tui.json line) until the Settings row lands.
    public static let opencodeRepositoryRelativePath = "integrations/opencode"
    public static let opencodePluginFileName = "localvoxtral.js"

    /// Repo checkout location of the opencode plugin file, for the contract
    /// tests that pin it to the Swift wire constants.
    static func developmentOpencodePluginURL(
        sourceFile: String = ClaudePluginAssets.assetsSourceFile
    ) -> URL? {
        repositoryRootURL(sourceFile: sourceFile)?
            .appendingPathComponent(opencodeRepositoryRelativePath)
            .appendingPathComponent(opencodePluginFileName)
    }

    /// Name of the publisher binary, as packaged and as the shim looks for it.
    public static let publisherExecutableName = "localvoxtral-claude-hook"

    /// The publisher binary the plugin's shim execs. Packaged next to the main
    /// binary in `Contents/MacOS`; the shim finds it on its own at runtime, so
    /// this is for surfacing install state in diagnostics/UI.
    public static func publisherURL(
        executableDirectory: URL? = Bundle.main.executableURL?.deletingLastPathComponent()
    ) -> URL? {
        guard let executableDirectory else { return nil }
        let candidate = executableDirectory.appendingPathComponent(publisherExecutableName)
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }
}
