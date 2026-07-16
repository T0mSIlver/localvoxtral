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
    /// Directory name inside `Contents/Resources`.
    public static let packagedDirectoryName = "claude-code-marketplace"
    /// Repo-relative source of truth.
    public static let repositoryRelativePath = "integrations/claude-code"
    /// Plugin name, as it appears in marketplace.json.
    public static let pluginName = "localvoxtral"
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
    static func developmentMarketplaceURL(sourceFile: String = #filePath) -> URL? {
        // .../Sources/localvoxtral/ClaudeContext/ClaudePluginAssets.swift
        var directory = URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent() // ClaudeContext
            .deletingLastPathComponent() // localvoxtral
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        directory.appendPathComponent(repositoryRelativePath)
        return directory
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
