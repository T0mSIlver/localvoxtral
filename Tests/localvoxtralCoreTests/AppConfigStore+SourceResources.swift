import Foundation
@testable import localvoxtralCore

/// The core has no resource bundle, so its tests read the bundled defaults
/// from the source tree they are copied from.
/// `AppConfigResourceBundleTests` (app suite) checks the app bundle holds the
/// same bytes.
enum BundledConfigSources {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/localvoxtral/Resources/Config", isDirectory: true)

    static func url(for fileName: String) -> URL? {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

extension AppConfigStore {
    init(
        configDirectoryOverride: URL? = nil,
        knownDefaultHashes: [String: Set<String>] = BundledConfigDefaultHistory.knownDefaultHashes,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            bundledResourceURL: BundledConfigSources.url(for:),
            configDirectoryOverride: configDirectoryOverride,
            knownDefaultHashes: knownDefaultHashes,
            now: now
        )
    }
}
