import ClaudeContextWire
import Foundation

/// The bundled Claude Code marketplace, as the remote plugin setup writes it
/// onto an ssh host.
///
/// The host installs from this copy, never from the GitHub repository: a
/// GitHub marketplace tracks the default branch, so the day main raised the
/// plugin's version every shipped app failed its own read-back on every host
/// (#836). The copy holds this build's manifest and both plugin trees, so a
/// host that also runs the app keeps its local plugin resolvable after the
/// `localvoxtral` marketplace is re-pointed here.
public struct ClaudeRemoteMarketplaceFiles: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        /// Relative to the marketplace root; `[A-Za-z0-9._/-]` only, no `..`.
        public var relativePath: String
        public var content: String
        public var executable: Bool

        public init(relativePath: String, content: String, executable: Bool) {
            self.relativePath = relativePath
            self.content = content
            self.executable = executable
        }
    }

    public var files: [File]

    public init(files: [File]) {
        self.files = files
    }

    /// The remote plugin's own `plugin.json` version in this copy.
    public var remotePluginVersion: String? {
        let path = "plugins/\(ClaudePluginAssets.remotePluginName)/.claude-plugin/plugin.json"
        guard let manifest = files.first(where: { $0.relativePath == path }),
              let json = try? JSONSerialization.jsonObject(with: Data(manifest.content.utf8)) as? [String: Any],
              let version = json["version"] as? String,
              ClaudeRemotePluginVersionCodec.isAcceptableVersion(version)
        else { return nil }
        return version
    }

    /// `.claude-plugin/marketplace.json` and every file under `plugins/`,
    /// sorted. Nil when the marketplace is missing or holds a file this setup
    /// cannot carry (a name outside the path alphabet, bytes that are not UTF-8).
    public static func bundled(
        marketplaceURL: URL? = ClaudePluginAssets.marketplaceURL(),
        fileManager: FileManager = .default
    ) -> ClaudeRemoteMarketplaceFiles? {
        guard let root = marketplaceURL else { return nil }
        let pluginsURL = root.appendingPathComponent("plugins")
        guard let pluginPaths = try? fileManager.subpathsOfDirectory(atPath: pluginsURL.path) else { return nil }
        var files: [File] = []
        for relative in [".claude-plugin/marketplace.json"] + pluginPaths.sorted().map({ "plugins/\($0)" }) {
            let url = root.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
            if isDirectory.boolValue || url.lastPathComponent == ".DS_Store" { continue }
            guard isCarriablePath(relative),
                  let data = fileManager.contents(atPath: url.path),
                  let content = String(data: data, encoding: .utf8)
            else { return nil }
            let permissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
                .intValue ?? 0
            files.append(File(relativePath: relative, content: content, executable: permissions & 0o111 != 0))
        }
        return ClaudeRemoteMarketplaceFiles(files: files)
    }

    /// A path goes into a double-quoted shell word, so it is held to an
    /// alphabet in which nothing expands.
    package static func isCarriablePath(_ path: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        return !path.isEmpty
            && !path.hasPrefix("/")
            && path.unicodeScalars.allSatisfy(allowed.contains)
            && !path.split(separator: "/").contains("..")
    }
}
