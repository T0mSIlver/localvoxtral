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
            "1.2.0": "0ccb162898e10564bbb1403064e6459891dcd09d8cc598b660087e78eb311d60",
        ],
        "localvoxtral-remote": [
            "1.11.0": "b60ad882518a1daac7a1c5f527fc0d856fa836d2358c687f011bbd12a3ca9834",
            "1.12.0": "0d209db3fd83c2742f0d70bb3abd109d05ec2ca7ffff1bd9551d01ce98d1dcc6",
            "1.13.0": "8b0c083a2abd8c4ae78c122d9a7118ad0789eb0c5ed7e3ed7018a33715ed92c1",
            "1.14.0": "c1f13481db51a478c348ce7404f95c63ba02b47932b71a2f473e69fdca0900ef",
            "1.15.0": "b7d619c3ee88baf334e3803cbed2108473dd5e9b59892c1ce635ec7822ded568",
            "1.16.0": "e236c46904c8fb36886b649a380762afe4cbaceb87e9bbedae280012f226571b",
            "1.17.0": "dce32194413631c6164e9476fb12e69e3234b0a951ed7763a719ececefd91b7f",
            "1.18.0": "6839ab1bb47b8faeefe731dfe13d287244366befe0661616da706ffa1c5bca37",
            "1.19.0": "79f9a5f1d056e28a1667a461fa6f8e1e62af0b6d0adeae72e343351d99e7aebd",
            "1.20.0": "0c9d137524c8b9dc5f325bb25d234c54718f1ddda5a28fbe78ed24c32e92633f",
            "1.21.0": "f92df0a8d9f20e6c1f984ea022ed2ceb667db78781e569d58cfdbcbde044f27d",
            "1.22.0": "20dfaf8893eb137baaec5ec58c6a2a72d2fb8891ae09e905b987df0acb6be6a1",
            "1.23.0": "f3825765cc2802474563a9eeeb0107a73b5ceb4a0cc38c446a24a18be7d44037",
            "1.24.0": "485540eba530e80df4426c89ff9ab1e5a6ef84e4eabe5734530c0686a608c6f6",
            "1.25.0": "714968c3a52c5d0568cf8ad7206f5a0e97421b30acd93ad1ccac610d71b456b0",
            "1.26.0": "c1a9a554ee20090bef85c2830740272b2b2ebcc7823a1473769eef50cf4106f6",
            "1.27.0": "1b936b1680b4c1003293f0a6897b18eb6f42e1f2f4016d4a76a588fca1b27ea0",
            "1.28.0": "a6531300427372827f59f1034af76e1b49156f70173ba940f9e0df6f606c3dbd",
            "1.29.0": "15e5529b87394530d642463916dde130bea14c7526464749350179e7aedd5ccc",
            "1.30.0": "896fcb9f489b13f8f5f06dd5cb4c1f4e3e58eeff9c152295a993cdcc6da489e6",
            "1.31.0": "e9df8ede023183918b8a0d63d35d9b3063cecef1a09bc66784eddbf9e45b4e89",
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
