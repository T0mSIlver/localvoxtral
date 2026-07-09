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
    let summary: String
}

enum PolishModelCatalog {
    static let options: [PolishModelOption] = [
        PolishModelOption(
            repoID: "mlx-community/Qwen3.5-0.8B-8bit",
            displayName: "Qwen3.5 0.8B (fastest, default)",
            sizeOnDiskGB: 0.9,
            estimatedRAMGB: 1.0,
            samplingDefaults: nil,
            summary: "Cleans up transcripts with negligible overhead"
        )
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
            fileManager.fileExists(
                atPath: snapshotsDirectory.appending(path: revision)
                    .appending(path: "config.json").path
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
            fileManager.fileExists(atPath: $0.appending(path: "config.json").path)
        }
    }
}
