import Foundation

/// Which streaming engine the bundled `localvoxtral-speechd` drives for a model.
/// The helper infers the same mapping from the repo id it is launched with
/// (`SpeechASREngineKind`); this is the app-side declaration, used by the picker
/// and pinned by a test on both sides.
package enum SpeechEngineKind: String, Equatable, Sendable {
    case voxtral
    case nemotron
}

package struct SpeechModelOption: Equatable, Sendable {
    package let repoID: String
    /// Exact commit downloaded by the app and loaded by speechd. The upstream
    /// loader otherwise resolves `main`, which would let a model-repo edit
    /// change strict weight keys beneath an installed app.
    package let revision: String
    package let displayName: String
    package let engine: SpeechEngineKind
    /// DECIMAL GB of the files the downloader actually fetches, matching the
    /// download bar's ByteCountFormatter units — HF model cards quote GiB,
    /// don't copy them (same trap as `PolishModelOption.sizeOnDiskGB`).
    package let sizeOnDiskGB: Double
    /// Whether the Engines pane shows Memory limit for this model. `--cache-limit-mb`
    /// caps MLX's buffer cache; measure the model with `speechd-bench` before
    /// claiming the limit binds (#486).
    package let showsMemoryLimit: Bool
}

package enum SpeechModelCatalog {
    package static let options: [SpeechModelOption] = [
        // Same mistralai/Voxtral-Mini-4B-Realtime-2602 4-bit conversion as the previous
        // mlx-community pin, plus a 4-bit/g64-quantized tied embedding/LM head — the
        // decode loop's dominant per-token cost (~30 ms -> ~3 ms on M1 Pro). Loading it
        // requires the quantized-tied-embedding loader fix pinned in
        // SpeechHelper/Package.swift (upstreamed in Blaizzy/mlx-audio-swift#232).
        SpeechModelOption(
            repoID: "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead",
            revision: "247f2eeccf962fbcaf85e361731a5e75b2d8cac1",
            displayName: "Voxtral Mini 4B Realtime (4-bit, quantized head)",
            engine: .voxtral,
            sizeOnDiskGB: 2.6,
            // Its cache fills to whatever limit is set: 4.9 GB total at 2 GB, 10.9 GB at 8 GB.
            showsMemoryLimit: true
        ),
        // NVIDIA's cache-aware streaming RNN-T, 8-bit. A third of Voxtral's weights,
        // which is what matters on an 8 or 16 GB Mac where the speech model and the
        // polish model compete for memory. It is less accurate: on FLEURS English with
        // language auto-detect the model card reports 8.84 WER at the chunk size we
        // run, against Voxtral's stronger published numbers.
        //
        // LICENCE: OpenMDW 1.1, NVIDIA's licence for this model since 2026-06-05. The
        // mlx-community conversion was made a day earlier and still tags the NVIDIA Open
        // Model License; NVIDIA's card is the one we follow. The app downloads the
        // weights at runtime and never bundles them.
        SpeechModelOption(
            repoID: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit",
            revision: "7279359e4481b5e9e185a318bd618e429c6d86cd",
            displayName: "Nemotron 3.5 ASR Streaming 0.6B (8-bit)",
            engine: .nemotron,
            sizeOnDiskGB: 0.8,
            // Its cache never passes ~10 MB, so every limit gives the same 0.75 GB.
            showsMemoryLimit: false
        ),
    ]

    package static let defaultOption: SpeechModelOption = {
        guard let option = option(
            forRepoID: "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead"
        ) else {
            preconditionFailure("Default speech model missing from the catalog.")
        }
        return option
    }()

    package static func option(forRepoID repoID: String) -> SpeechModelOption? {
        options.first { $0.repoID == repoID }
    }
}

package enum SpeechModelPickerSupport {
    /// The picker's menu item: the model and what it costs on disk. Whether
    /// it is downloaded shows on the Status row.
    package static func menuLabel(for option: SpeechModelOption) -> String {
        "\(option.displayName) — \(ModelSizeLabel.gigabytes(option.sizeOnDiskGB))"
    }
}

package enum ModelSizeLabel {
    package static func gigabytes(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) GB"
    }
}
