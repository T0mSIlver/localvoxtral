import Foundation

/// Is a pinned Hugging Face snapshot already on disk and complete? Shared by
/// both managed catalogs (`PolishModelCatalog`, `SpeechModelCatalog`): the app
/// downloads every managed model into the same shared cache.
enum ManagedModelCache {
    static func defaultCacheRoot(
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

    /// `revision` is the catalog pin (nil for a user's custom repo id, which
    /// we can only resolve through `main`). A pinned model is downloaded only
    /// when ITS snapshot is complete — an install that still holds some other
    /// revision, however complete, is not the model we run.
    static func isDownloaded(
        repoID: String,
        revision: String? = nil,
        cacheRoot: URL = defaultCacheRoot(),
        fileManager: FileManager = .default
    ) -> Bool {
        let repoDirectory = cacheRoot.appending(
            path: "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        )
        let snapshotsDirectory = repoDirectory.appending(path: "snapshots")

        if let revision {
            return snapshotIsComplete(
                snapshotsDirectory.appending(path: revision),
                fileManager: fileManager
            )
        }

        let mainReference = repoDirectory.appending(path: "refs/main")
        if let revision = try? String(contentsOf: mainReference, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !revision.isEmpty,
            snapshotIsComplete(
                snapshotsDirectory.appending(path: revision),
                fileManager: fileManager
            )
        {
            return true
        }

        let snapshots =
            (try? fileManager.contentsOfDirectory(
                at: snapshotsDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
        return snapshots.contains {
            snapshotIsComplete($0, fileManager: fileManager)
        }
    }

    /// True only when the WEIGHTS are complete, not just the metadata:
    /// config.json lands first in a download, and hf's cache only links a
    /// snapshot file once its blob finished — so "config.json exists" flips
    /// to "downloaded" the moment a download STARTS (field finding, PR #99).
    /// Sharded models are checked against their index's weight_map.
    private static func snapshotIsComplete(_ snapshot: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: snapshot.appending(path: "config.json").path) else {
            return false
        }

        let indexURL = snapshot.appending(path: "model.safetensors.index.json")
        if let data = try? Data(contentsOf: indexURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightMap = object["weight_map"] as? [String: String]
        {
            let shardNames = Set(weightMap.values)
            return !shardNames.isEmpty
                && shardNames.allSatisfy {
                    // fileExists resolves symlinks: a link to a still-partial
                    // (unlinked) blob does not count.
                    fileManager.fileExists(atPath: snapshot.appending(path: $0).path)
                }
        }

        let entries =
            (try? fileManager.contentsOfDirectory(atPath: snapshot.path)) ?? []
        return entries.contains {
            $0.hasSuffix(".safetensors")
                && fileManager.fileExists(atPath: snapshot.appending(path: $0).path)
        }
    }
}
