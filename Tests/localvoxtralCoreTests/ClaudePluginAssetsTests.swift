import Foundation
import XCTest
@testable import localvoxtralCore

// MARK: - Packaged resource lookup

/// The lookup this exercises is the one #87 broke: a packaged app resolving a
/// resource that only exists at the builder's absolute `.build` path launches
/// fine on the build machine and nowhere else. These tests pin both arms —
/// packaged first, dev checkout second — and that a partial copy does not
/// resolve.
final class ClaudePluginAssetsTests: XCTestCase {
    func testDevelopmentFallbackFindsTheRepoMarketplace() throws {
        let url = try XCTUnwrap(ClaudePluginAssets.developmentMarketplaceURL())
        XCTAssertTrue(url.path.hasSuffix("integrations/claude-code"))
        XCTAssertTrue(
            ClaudePluginAssets.isMarketplace(url),
            "swift test must resolve the in-repo marketplace at \(url.path)"
        )
    }

    func testDevelopmentFallbackWalksUpFromSourceFileNotBuildPath() {
        // Deriving the repo root from #filePath is what keeps this working on a
        // machine that is not the builder.
        let url = ClaudePluginAssets.developmentMarketplaceURL(
            sourceFile: "/checkout/Sources/localvoxtral/ClaudeContext/ClaudePluginAssets.swift"
        )
        XCTAssertEqual(url?.path, "/checkout/integrations/claude-code")
    }

    func testIsMarketplaceRequiresTheManifestNotJustTheDirectory() throws {
        // A partial copy in package_app.sh must not resolve: it would fail
        // later, inside `claude plugin marketplace add`, with a worse message.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mkt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(ClaudePluginAssets.isMarketplace(root), "empty directory is not a marketplace")

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true
        )
        XCTAssertFalse(
            ClaudePluginAssets.isMarketplace(root),
            ".claude-plugin without marketplace.json is not a marketplace"
        )

        try Data("{}".utf8).write(to: root.appendingPathComponent(".claude-plugin/marketplace.json"))
        XCTAssertTrue(ClaudePluginAssets.isMarketplace(root))
    }

    func testPackagedLocationWinsOverDevelopmentFallback() throws {
        // Simulate Contents/Resources/claude-code-marketplace.
        let resources = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resources-\(UUID().uuidString)")
        let packaged = resources.appendingPathComponent(ClaudePluginAssets.packagedDirectoryName)
        try FileManager.default.createDirectory(
            at: packaged.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: packaged.appendingPathComponent(".claude-plugin/marketplace.json"))
        defer { try? FileManager.default.removeItem(at: resources) }

        let resolved = ClaudePluginAssets.marketplaceURL(resourcesURL: resources)
        XCTAssertEqual(resolved?.path, packaged.path)
    }

    func testFallsBackToRepoWhenPackagedCopyIsAbsent() throws {
        // A resources dir with no marketplace in it: dev checkout wins.
        let resources = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }

        let resolved = try XCTUnwrap(ClaudePluginAssets.marketplaceURL(resourcesURL: resources))
        XCTAssertTrue(resolved.path.hasSuffix("integrations/claude-code"))
    }

    func testPublisherLookupRequiresAnExecutable() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(ClaudePluginAssets.publisherURL(executableDirectory: directory))

        let binary = directory.appendingPathComponent(ClaudePluginAssets.publisherExecutableName)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: binary.path,
            contents: Data(),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        ))
        XCTAssertEqual(
            ClaudePluginAssets.publisherURL(executableDirectory: directory)?.path, binary.path
        )
    }

    func testPackagedNamesMatchWhatPackagingAndTheCLIExpect() {
        // package_app.sh copies to this directory name; the install service
        // passes the resolved path to `claude plugin marketplace add`.
        XCTAssertEqual(ClaudePluginAssets.packagedDirectoryName, "claude-code-marketplace")
        XCTAssertEqual(ClaudePluginAssets.repositoryRelativePath, "integrations/claude-code")
        XCTAssertEqual(ClaudePluginAssets.pluginName, "localvoxtral")
        XCTAssertEqual(ClaudePluginAssets.marketplaceName, "localvoxtral")
    }

    func testLocalPluginVersionReadsThePluginManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugver-\(UUID().uuidString)")
        let pluginDir = root.appendingPathComponent("plugins/localvoxtral/.claude-plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(ClaudePluginAssets.localPluginVersion(marketplaceURL: root))
        // The marketplace's metadata.version is a different number and must
        // not be picked up.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true
        )
        try Data("{\"metadata\":{\"version\":\"1.4.0\"}}".utf8).write(
            to: root.appendingPathComponent(".claude-plugin/marketplace.json")
        )
        XCTAssertNil(ClaudePluginAssets.localPluginVersion(marketplaceURL: root))
        try Data("{\"version\":\"1.0.0\"}".utf8).write(
            to: pluginDir.appendingPathComponent("plugin.json")
        )
        XCTAssertEqual(ClaudePluginAssets.localPluginVersion(marketplaceURL: root), "1.0.0")
    }

    func testTheBundledLocalPluginFreshlyInstalledIsNotAnUpdate() throws {
        // `claude plugin list --json` names the version from the plugin's own
        // plugin.json, not the marketplace's metadata.version. A fresh install
        // of the bundled plugin must read as installed.
        let url = try XCTUnwrap(ClaudePluginAssets.developmentMarketplaceURL())
        let manifest = url.appendingPathComponent(
            "plugins/\(ClaudePluginAssets.pluginName)/.claude-plugin/plugin.json"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        )
        let listed = try XCTUnwrap(json["version"] as? String)
        let listing = """
        [{"id":"localvoxtral@localvoxtral","version":"\(listed)","scope":"user","enabled":true}]
        """

        let status = ClaudePluginStatus.derive(
            listOutput: listing,
            bundledVersion: ClaudePluginAssets.localPluginVersion(marketplaceURL: url)
        )

        XCTAssertEqual(status, .installed(version: listed))
    }

    func testOpencodePluginResolvesPackagedBeforeCheckout() throws {
        let resources = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocres-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }

        // Packaged copy wins when present (this is what package_app.sh ships).
        let packaged = resources.appendingPathComponent(ClaudePluginAssets.opencodePackagedFileName)
        try Data("packaged".utf8).write(to: packaged)
        XCTAssertEqual(
            ClaudePluginAssets.opencodePluginURL(resourcesURL: resources)?.path, packaged.path
        )

        // Otherwise the repo checkout serves dev builds and tests.
        try FileManager.default.removeItem(at: packaged)
        let resolved = try XCTUnwrap(
            ClaudePluginAssets.opencodePluginURL(resourcesURL: resources)
        )
        XCTAssertTrue(resolved.path.hasSuffix("integrations/opencode/localvoxtral.js"))
    }
}
