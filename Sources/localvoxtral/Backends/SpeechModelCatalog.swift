import Foundation

struct SpeechModelOption: Equatable, Sendable {
    let repoID: String
    /// Exact commit downloaded by the app and loaded by speechd. The upstream
    /// loader otherwise resolves `main`, which would let a model-repo edit
    /// change strict weight keys beneath an installed app.
    let revision: String
    let displayName: String
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
            displayName: "Voxtral Mini 4B Realtime (4-bit, quantized head)"
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
