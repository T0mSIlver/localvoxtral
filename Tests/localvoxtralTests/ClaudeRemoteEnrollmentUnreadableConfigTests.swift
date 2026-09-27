import Foundation
import XCTest
@testable import localvoxtral

/// The one `ClaudeRemoteEnrollmentServiceTests` case that needs a file its
/// own process cannot read. The Linux CI job runs as root, which reads a
/// mode-000 file anyway, so it stays in the app suite, which runs only on the
/// Mac as a regular user.
final class ClaudeRemoteEnrollmentUnreadableConfigTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "herdr-local-config-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true
        )
        return home
    }

    func testLiveLocalHerdrConfigReportsAnUnreadableFileAsUnknownNotAbsent() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fileSystem = LiveClaudeLocalHerdrConfigFileSystem(homeDirectoryURL: home)
        try fileSystem.createConfigDirectory(permissions: 0o755)
        try fileSystem.atomicWriteConfig(
            Data("[ui]\n".utf8), permissions: 0o644, expectedConfigPresent: false
        )
        let configPath = home.appendingPathComponent(".config/herdr/config.toml").path
        // Restore the mode so the temporary tree can be removed.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: configPath
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)], ofItemAtPath: configPath
        )
        XCTAssertThrowsError(try fileSystem.readState(), "an unreadable file is not an absent one")
        XCTAssertEqual(
            ClaudeRemoteEnrollmentService(localHerdrConfigFileSystem: fileSystem)
                .localHerdrPanelStatus(),
            .unknown
        )
    }
}
