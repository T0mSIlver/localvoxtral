import Foundation

package struct PolishSamplingDefaults: Equatable, Sendable {
    package let temperature: Double?
    package let topP: Double?
    package let topK: Int?
    package let minP: Double?
    package let presencePenalty: Double?

    package init(
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

package struct PolishModelOption: Equatable, Sendable {
    package let repoID: String
    /// Exact commit the app downloads and the helper loads. A repo id alone
    /// tracks `main`, and upstream rewrites reach every install the moment
    /// the cache re-resolves: on 2026-07-14 the OptiQ repos registered their
    /// bf16 vision tower in model.safetensors.index.json, so the indexed
    /// weight_map suddenly named optiq/optiq_vision.safetensors — a file our
    /// include patterns never fetch — and the helper died on load
    /// ("[load_safetensors] Failed to open file …/optiq/optiq_vision.safetensors").
    /// Pin, don't chase: bumping a pin is a reviewed change that reruns the
    /// eval lanes.
    package let revision: String
    package let displayName: String
    package let sizeOnDiskGB: Double
    package let estimatedRAMGB: Double
    package let samplingDefaults: PolishSamplingDefaults?
    package let chatTemplateArguments: [String: Bool]?
}

package enum PolishModelCatalog {
    /// The 4B and 9B decode greedily (temperature 0): greedy output repeats
    /// exactly, which the evals and learning from edits rely on, and on the
    /// polish eval lane neither lost a case to it (#533, #563). The 0.8B
    /// keeps the 0.3 request default: at 0 it lost a required case
    /// (fr-colon-missing-space) and two known-hard ones. Mistral and External
    /// URL keep 0.3 too.
    package static let options: [PolishModelOption] = [
        // sizeOnDiskGB is DECIMAL GB of the files the downloader actually
        // fetches (weights + tokenizer + configs; the include patterns skip
        // optiq_vision/mtp extras), matching the download bar's
        // ByteCountFormatter units — HF model cards quote GiB, don't copy
        // them (field finding: picker said 6.6, bar said 7.1).
        PolishModelOption(
            repoID: "mlx-community/Qwen3.5-0.8B-8bit",
            revision: "87e768fbfa03994095f3d14527c80c5ae70c5758",
            displayName: "Qwen3.5 0.8B (fastest)",
            sizeOnDiskGB: 1.0,
            estimatedRAMGB: 1.2,
            samplingDefaults: nil,
            chatTemplateArguments: nil
        ),
        PolishModelOption(
            repoID: "mlx-community/Qwen3.5-4B-OptiQ-4bit",
            // Last revision whose index maps every weight into
            // model.safetensors; the next one (6cb5bdf) added the vision
            // tower to the weight_map.
            revision: "41eccc3316fd4bf4b27cedf4924fe23ce44e77d9",
            displayName: "Qwen3.5 4B (better quality, default)",
            sizeOnDiskGB: 3.3,
            estimatedRAMGB: 3.8,
            samplingDefaults: PolishSamplingDefaults(temperature: 0),
            chatTemplateArguments: ["enable_thinking": false]
        ),
        PolishModelOption(
            repoID: "mlx-community/Qwen3.5-9B-OptiQ-4bit",
            // Same cut-off as the 4B (804d898 is the 9B's equivalent commit).
            revision: "804d898651e45f0478323cd30ffebcb3c8e6714d",
            displayName: "Qwen3.5 9B (best quality)",
            sizeOnDiskGB: 7.1,
            estimatedRAMGB: 7.5,
            samplingDefaults: PolishSamplingDefaults(temperature: 0),
            chatTemplateArguments: ["enable_thinking": false]
        ),
    ]

    /// Owner decision 2026-07-11: the 4B is the default for ALL users (14/14
    /// on the punctuation eval vs the 0.8B's 10/14) — no RAM-based fallback;
    /// the 0.8B stays selectable in the picker for constrained Macs.
    package static let defaultOption: PolishModelOption = {
        guard let option = option(forRepoID: "mlx-community/Qwen3.5-4B-OptiQ-4bit") else {
            preconditionFailure("Default polishing model missing from the catalog.")
        }
        return option
    }()

    package static func option(forRepoID repoID: String) -> PolishModelOption? {
        options.first { $0.repoID == repoID }
    }
}

package struct PolishModelPickerEntry: Equatable, Identifiable, Sendable {
    package let repoID: String
    package let label: String
    package let option: PolishModelOption?

    package var id: String { repoID }
}

package enum PolishModelPickerSupport {
    package static func entries(storedRepoID: String) -> [PolishModelPickerEntry] {
        var entries = PolishModelCatalog.options.map {
            PolishModelPickerEntry(
                repoID: $0.repoID,
                label: "\($0.displayName) — \(ModelSizeLabel.gigabytes($0.sizeOnDiskGB))",
                option: $0
            )
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
}
