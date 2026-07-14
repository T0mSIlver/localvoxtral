import Foundation

/// Resolves a Hugging Face repo id (e.g. "mlx-community/Qwen3.5-0.8B-8bit")
/// to a local snapshot directory in the shared HF hub cache. The app
/// pre-downloads models there via `HFModelDownloader` (which deliberately
/// leaves the HF cache env unset so weights are shared with other tools);
/// this helper never downloads — a missing model is a hard, actionable error.
public enum HFCacheModelLocator {
    public enum LocatorError: Error, CustomStringConvertible {
        case modelNotCached(repoID: String, searched: URL)
        case noUsableSnapshot(repoID: String, searched: URL)
        case pinnedRevisionNotCached(repoID: String, revision: String, searched: URL)

        public var description: String {
            switch self {
            case .modelNotCached(let repoID, let searched):
                "model \(repoID) not found in HF cache at \(searched.path); download it first"
            case .noUsableSnapshot(let repoID, let searched):
                "model \(repoID) has no snapshot containing config.json under \(searched.path)"
            case .pinnedRevisionNotCached(let repoID, let revision, let searched):
                "model \(repoID) has no snapshot for pinned revision \(revision) under \(searched.path); download it first"
            }
        }
    }

    /// Mirrors huggingface_hub's cache-root resolution: HF_HUB_CACHE, then
    /// HF_HOME/hub, then ~/.cache/huggingface/hub.
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

    /// `revision` is the app's catalog pin. When set, ONLY that snapshot is
    /// acceptable: falling back to the main ref is what let an upstream index
    /// rewrite reach the loader (2026-07-14), and silently loading a revision
    /// the app never downloaded is worse than a clear error.
    public static func locate(repoID: String, revision: String? = nil, cacheRoot: URL) throws -> URL {
        let repoDir = cacheRoot.appending(path: "models--" + repoID.replacingOccurrences(of: "/", with: "--"))
        let snapshotsDir = repoDir.appending(path: "snapshots")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: snapshotsDir.path) else {
            throw LocatorError.modelNotCached(repoID: repoID, searched: cacheRoot)
        }

        if let revision {
            let pinned = snapshotsDir.appending(path: revision)
            guard fileManager.fileExists(atPath: pinned.appending(path: "config.json").path) else {
                throw LocatorError.pinnedRevisionNotCached(
                    repoID: repoID,
                    revision: revision,
                    searched: snapshotsDir
                )
            }
            return pinned
        }

        // Prefer the revision recorded for the main ref; otherwise fall back
        // to the most recently modified snapshot that actually has a config.
        let mainRef = repoDir.appending(path: "refs/main")
        if let revision = try? String(contentsOf: mainRef, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !revision.isEmpty
        {
            let candidate = snapshotsDir.appending(path: revision)
            if fileManager.fileExists(atPath: candidate.appending(path: "config.json").path) {
                return candidate
            }
        }

        let snapshots = (try? fileManager.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let usable = snapshots
            .filter { fileManager.fileExists(atPath: $0.appending(path: "config.json").path) }
            .sorted { lhs, rhs in
                let lhsDate =
                    (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                let rhsDate =
                    (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
        guard let newest = usable.first else {
            throw LocatorError.noUsableSnapshot(repoID: repoID, searched: snapshotsDir)
        }
        return newest
    }
}
