import Foundation

/// Resolves app-prepared Hugging Face snapshots from the shared hub cache.
/// The managed helper never resolves a pinned model through `main`: the exact
/// catalog revision must be present or startup fails with an actionable error.
public enum SpeechHFCacheModelLocator {
    public enum LocatorError: Error, CustomStringConvertible {
        case modelNotCached(repoID: String, searched: URL)
        case pinnedRevisionNotCached(repoID: String, revision: String, searched: URL)

        public var description: String {
            switch self {
            case .modelNotCached(let repoID, let searched):
                return "model \(repoID) not found in HF cache at \(searched.path); download it first"
            case .pinnedRevisionNotCached(let repoID, let revision, let searched):
                return "model \(repoID) has no snapshot for pinned revision \(revision) under \(searched.path); download it first"
            }
        }
    }

    /// Mirrors huggingface_hub: HF_HUB_CACHE, then HF_HOME/hub, then the
    /// default ~/.cache/huggingface/hub directory.
    public static func defaultCacheRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let hubCache = environment["HF_HUB_CACHE"], !hubCache.isEmpty {
            return URL(filePath: hubCache)
        }
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            return URL(filePath: hfHome).appending(path: "hub")
        }
        return home.appending(path: ".cache/huggingface/hub")
    }

    public static func locate(repoID: String, revision: String, cacheRoot: URL) throws -> URL {
        let snapshots = cacheRoot
            .appending(path: "models--" + repoID.replacingOccurrences(of: "/", with: "--"))
            .appending(path: "snapshots")
        guard FileManager.default.fileExists(atPath: snapshots.path) else {
            throw LocatorError.modelNotCached(repoID: repoID, searched: cacheRoot)
        }

        let pinned = snapshots.appending(path: revision)
        guard FileManager.default.fileExists(atPath: pinned.appending(path: "config.json").path) else {
            throw LocatorError.pinnedRevisionNotCached(
                repoID: repoID,
                revision: revision,
                searched: snapshots
            )
        }
        return pinned
    }
}
