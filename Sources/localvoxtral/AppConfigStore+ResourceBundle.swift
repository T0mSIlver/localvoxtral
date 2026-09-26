import Foundation

extension AppConfigStore {
    /// The store the app uses: bundled defaults come from the app's resource
    /// bundle. The store itself lives in `localvoxtralCore`, which has no
    /// resources.
    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .localvoxtralResources,
        configDirectoryOverride: URL? = nil,
        knownDefaultHashes: [String: Set<String>] = BundledConfigDefaultHistory.knownDefaultHashes,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            fileManager: fileManager,
            bundledResourceURL: { fileName in
                bundle.url(
                    forResource: fileName.replacingOccurrences(of: ".toml", with: ""),
                    withExtension: "toml"
                )
            },
            configDirectoryOverride: configDirectoryOverride,
            knownDefaultHashes: knownDefaultHashes,
            now: now
        )
    }
}
