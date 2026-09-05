import Foundation
import XCTest
@testable import localvoxtral

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
}
