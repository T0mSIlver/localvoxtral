import Foundation
import XCTest
@testable import localvoxtral

/// `AppConfigStore`'s own tests run in the core and read the bundled
/// defaults from the source tree. This checks the app's store finds every one
/// of them in its resource bundle, byte for byte.
final class AppConfigResourceBundleTests: XCTestCase {
    private static let sourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/localvoxtral/Resources/Config", isDirectory: true)

    func testTheAppStoreSeedsEveryConfigFileFromTheResourceBundle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvoxtral-config-bundle-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let seeded = AppConfigStore(configDirectoryOverride: directory).configDirectoryURL()

        for fileName in AppConfigStore.debugAllConfigFileNames {
            let resourceName = fileName.replacingOccurrences(of: ".toml", with: "")
            let bundledURL = try XCTUnwrap(
                Bundle.localvoxtralResources.url(forResource: resourceName, withExtension: "toml"),
                "Missing bundled resource \(fileName)"
            )
            let source = try Data(contentsOf: Self.sourceDirectory.appendingPathComponent(fileName))
            XCTAssertEqual(try Data(contentsOf: bundledURL), source, fileName)
            XCTAssertEqual(try Data(contentsOf: seeded.appendingPathComponent(fileName)), source, fileName)
        }
    }
}
