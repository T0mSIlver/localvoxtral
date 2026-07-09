import Foundation

struct PolishSamplingDefaults: Equatable, Sendable {
    let temperature: Double?
    let topP: Double?
    let topK: Int?
    let minP: Double?
    let presencePenalty: Double?

    init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        presencePenalty: Double? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.presencePenalty = presencePenalty
    }
}

struct PolishModelOption: Equatable, Sendable {
    let repoID: String
    let displayName: String
    let sizeOnDiskGB: Double
    let estimatedRAMGB: Double
    let samplingDefaults: PolishSamplingDefaults?
    let chatTemplateArguments: [String: Bool]?
    let summary: String
}

enum PolishModelCatalog {
    static let options: [PolishModelOption] = [
        // sizeOnDiskGB is DECIMAL GB of the files the downloader actually
        // fetches (weights + tokenizer + configs; the include patterns skip
        // optiq_vision/mtp extras), matching the download bar's
        // ByteCountFormatter units — HF model cards quote GiB, don't copy
        // them (field finding: picker said 6.6, bar said 7.1).
        PolishModelOption(
            repoID: "mlx-community/Qwen3.5-0.8B-8bit",
            displayName: "Qwen3.5 0.8B (fastest, default)",
            sizeOnDiskGB: 1.0,
            estimatedRAMGB: 1.2,
            samplingDefaults: nil,
            chatTemplateArguments: nil,
            summary: "For any Apple Silicon Mac"
        ),
        PolishModelOption(
            repoID: "mlx-community/Qwen3.5-4B-OptiQ-4bit",
            displayName: "Qwen3.5 4B (better quality)",
            sizeOnDiskGB: 3.3,
            estimatedRAMGB: 3.8,
            samplingDefaults: nil,
            chatTemplateArguments: ["enable_thinking": false],
            summary: "For 16 GB+ Macs"
        ),
        PolishModelOption(
            repoID: "mlx-community/Qwen3.5-9B-OptiQ-4bit",
            displayName: "Qwen3.5 9B (best quality)",
            sizeOnDiskGB: 7.1,
            estimatedRAMGB: 7.5,
            samplingDefaults: nil,
            chatTemplateArguments: ["enable_thinking": false],
            summary: "For 32 GB+ Macs"
        ),
    ]

    static let defaultOption = options[0]

    static func option(forRepoID repoID: String) -> PolishModelOption? {
        options.first { $0.repoID == repoID }
    }
}

struct PolishModelPickerEntry: Equatable, Identifiable, Sendable {
    let repoID: String
    let label: String
    let option: PolishModelOption?

    var id: String { repoID }
}

enum PolishModelPickerSupport {
    static func entries(storedRepoID: String) -> [PolishModelPickerEntry] {
        var entries = PolishModelCatalog.options.map {
            PolishModelPickerEntry(repoID: $0.repoID, label: $0.displayName, option: $0)
        }
        if PolishModelCatalog.option(forRepoID: storedRepoID) == nil {
            entries.append(
                PolishModelPickerEntry(
                    repoID: storedRepoID,
                    label: "Custom: \(storedRepoID)",
                    option: nil
                )
            )
        }
        return entries
    }

    static func helpText(
        for entry: PolishModelPickerEntry,
        isDownloaded: Bool
    ) -> String {
        let downloadState = isDownloaded ? "downloaded" : "downloads on first use"
        guard let option = entry.option else {
            return "Custom managed model. \(downloadState)."
        }
        return
            "\(option.summary). \(option.sizeOnDiskGB.formatted(.number.precision(.fractionLength(1)))) GB · \(downloadState)"
    }
}

enum PolishModelCache {
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

    static func isDownloaded(
        repoID: String,
        cacheRoot: URL = defaultCacheRoot(),
        fileManager: FileManager = .default
    ) -> Bool {
        let repoDirectory = cacheRoot.appending(
            path: "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        )
        let snapshotsDirectory = repoDirectory.appending(path: "snapshots")

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
