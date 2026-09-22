import Foundation

/// Which streaming engine the bundled `localvoxtral-speechd` drives for a model.
/// The helper infers the same mapping from the repo id it is launched with
/// (`SpeechASREngineKind`); this is the app-side declaration, used by the picker
/// and pinned by a test on both sides.
enum SpeechEngineKind: String, Equatable, Sendable {
    case voxtral
    case nemotron
}

struct SpeechModelOption: Equatable, Sendable {
    let repoID: String
    /// Exact commit downloaded by the app and loaded by speechd. The upstream
    /// loader otherwise resolves `main`, which would let a model-repo edit
    /// change strict weight keys beneath an installed app.
    let revision: String
    let displayName: String
    let engine: SpeechEngineKind
    /// DECIMAL GB of the files the downloader actually fetches, matching the
    /// download bar's ByteCountFormatter units — HF model cards quote GiB,
    /// don't copy them (same trap as `PolishModelOption.sizeOnDiskGB`).
    let sizeOnDiskGB: Double
    /// One clause for the picker's help line, before the size and download state.
    let summary: String
}

enum SpeechModelCatalog {
    static let options: [SpeechModelOption] = [
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
            summary: "Most accurate"
        ),
        // NVIDIA's cache-aware streaming RNN-T, 8-bit. A third of Voxtral's weights,
        // which is what matters on an 8 or 16 GB Mac where the speech model and the
        // polish model compete for memory. It is less accurate: on FLEURS English with
        // language auto-detect the model card reports 8.84 WER at the chunk size we
        // run, against Voxtral's stronger published numbers.
        //
        // LICENCE: the NVIDIA model card has been OpenMDW 1.1 since 2026-06-05, but
        // this mlx-community conversion was made a day earlier and still carries the
        // NVIDIA Open Model License tag. Confirm which one governs the conversion
        // before a signed build offers it (#463).
        SpeechModelOption(
            repoID: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit",
            revision: "7279359e4481b5e9e185a318bd618e429c6d86cd",
            displayName: "Nemotron 3.5 ASR Streaming 0.6B (8-bit)",
            engine: .nemotron,
            sizeOnDiskGB: 0.8,
            summary: "Lowest memory, less accurate"
        ),
    ]

    static let defaultOption: SpeechModelOption = {
        guard let option = option(
            forRepoID: "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead"
        ) else {
            preconditionFailure("Default speech model missing from the catalog.")
        }
        return option
    }()

    static func option(forRepoID repoID: String) -> SpeechModelOption? {
        options.first { $0.repoID == repoID }
    }
}

enum SpeechModelPickerSupport {
    /// Same shape as the polishing picker's help line: what the model is for,
    /// what it costs on disk, and whether it is already there.
    static func helpText(for option: SpeechModelOption, isDownloaded: Bool) -> String {
        let downloadState = isDownloaded ? "downloaded" : "downloads on first use"
        let size = option.sizeOnDiskGB.formatted(.number.precision(.fractionLength(1)))
        return "\(option.summary). \(size) GB, \(downloadState)"
    }
}
