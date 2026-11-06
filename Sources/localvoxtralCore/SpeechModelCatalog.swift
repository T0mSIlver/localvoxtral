import Foundation

/// Which streaming engine the bundled `localvoxtral-speechd` drives for a model.
/// The app passes it to the helper as `--engine <rawValue>`, which
/// `SpeechASREngineKind` parses; the picker reads it too.
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
    /// What the model takes besides audio. Neither shipped engine biases its
    /// decoding yet (#316, #521).
    package let capabilities: DictationModelCapabilities
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
            capabilities: .audioOnly
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
            capabilities: .audioOnly
        ),
        // NVIDIA's Nemotron Unified, the same RNN-T family, 8-bit. It streams buffered:
        // each step re-encodes 5.6 s of left context, not cached state, so it costs about
        // four times 3.5's GPU per step. In exchange it is more accurate (NVIDIA's card:
        // 6.27 English WER at 320 ms, against 7.97 for 3.5) and covers 25 European
        // languages. Converted by us; the speech helper picks its layout and float16
        // compute (`NemotronUnifiedLayout`).
        //
        // LICENCE: OpenMDW 1.1, as the source model. The app downloads the weights at
        // runtime and never bundles them.
        SpeechModelOption(
            repoID: "T0mSIlver/nemotron-labs-unified-asr-0.6b-8bit",
            revision: "b7108f135cd732fbdf86af5fa7bc8a30f38cb069",
            displayName: "Nemotron Unified ASR 0.6B (8-bit)",
            engine: .nemotron,
            sizeOnDiskGB: 0.7,
            // The 25 languages of NVIDIA's model card. Each is a key of the
            // checkpoint's `prompt_dictionary`, which also holds other locales
            // the model was not trained on.
            capabilities: DictationModelCapabilities(
                termBias: .none,
                languages: [
                    "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
                    "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
                ]
            )
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

    /// The Language picker's items: each code with its name in `locale`, sorted
    /// by name. Auto comes first in the view, outside this list.
    package static func languageEntries(
        _ codes: [String], locale: Locale = .current
    ) -> [(code: String, name: String)] {
        codes.map { code in
            let name = locale.localizedString(forLanguageCode: code).map { $0.capitalized(with: locale) } ?? code
            return (code: code, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

package enum ModelSizeLabel {
    package static func gigabytes(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) GB"
    }
}
