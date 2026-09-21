import CryptoKit
import Foundation
import XCTest
@testable import localvoxtral

/// A plugin's files may change only together with its version.
///
/// Claude Code caches an installed plugin by version, and the app decides
/// whether to update the local plugin by comparing versions alone. A change
/// shipped under an unchanged version never reaches an installed plugin, and
/// the Settings row calls the stale install current.
final class ClaudePluginVersionHistoryTests: XCTestCase {
    /// Content hash of each plugin at each released version. After changing a
    /// plugin, bump the version in its `plugin.json` and add the hash this
    /// test prints. Keep the old entries.
    static let knownContentHashes: [String: [String: String]] = [
        "localvoxtral": [
            "1.1.0": "ae24b8495881e48dd5f5b684b2c8a24a98ee0e2f9c901644a83998e3b91a9eef",
        ],
        "localvoxtral-remote": [
            "1.11.0": "b60ad882518a1daac7a1c5f527fc0d856fa836d2358c687f011bbd12a3ca9834",
            "1.12.0": "0d209db3fd83c2742f0d70bb3abd109d05ec2ca7ffff1bd9551d01ce98d1dcc6",
        ],
    ]

    func testEveryPluginChangeCarriesANewVersion() throws {
        let marketplace = try XCTUnwrap(ClaudePluginAssets.developmentMarketplaceURL())
        for plugin in [ClaudePluginAssets.pluginName, ClaudePluginAssets.remotePluginName] {
            let root = marketplace.appendingPathComponent("plugins/\(plugin)")
            let manifest = try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent(".claude-plugin/plugin.json"))
            ) as? [String: Any]
            let version = try XCTUnwrap(manifest?["version"] as? String)
            let hash = try Self.contentHash(of: root)
            let known = Self.knownContentHashes[plugin, default: [:]]

            if let recorded = known[version] {
                XCTAssertEqual(
                    hash, recorded,
                    "\(plugin) changed but still claims version \(version). Bump the version in "
                        + "its plugin.json, then record the new hash."
                )
            } else {
                XCTFail("Record \(plugin) \(version): \"\(version)\": \"\(hash)\"")
            }
            if let reused = known.first(where: { $0.key != version && $0.value == hash }) {
                XCTFail("\(plugin) \(version) has the same files as \(reused.key)")
            }
        }
    }

    /// SHA-256 over every file's relative path and bytes, in byte order of
    /// the path.
    static func contentHash(of root: URL) throws -> String {
        let fileManager = FileManager.default
        let paths = (fileManager.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
            .filter { path in
                var isDirectory: ObjCBool = false
                fileManager.fileExists(
                    atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory
                )
                return !isDirectory.boolValue && (path as NSString).lastPathComponent != ".DS_Store"
            }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var hasher = SHA256()
        for path in paths {
            hasher.update(data: Data(path.utf8) + [0])
            hasher.update(data: try Data(contentsOf: root.appendingPathComponent(path)) + [0])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
