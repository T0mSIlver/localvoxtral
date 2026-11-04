import Foundation

/// What the app knows about each of Mistral's realtime transcription models
/// that changes what goes on the wire.
///
/// Voxtral Mini Transcribe Realtime 3 (`voxtral-mini-transcribe-realtime-3-0`,
/// alias `voxtral-mini-transcribe-realtime-3`, public preview since
/// 2026-10-20, no open weights) takes a `context_bias` array in
/// `session.update`, before the first audio chunk, with phrases holding
/// spaces allowed. Its stop is 2602's: the docs name only
/// `input_audio.end`, but they leave `input_audio.flush` out for 2602 too,
/// which has always taken it.
/// Docs, checked 2026-10-21: docs.mistral.ai/studio/audio/speech-to-text/
/// transcribe-in-realtime ("Session fields"), .../bias-context-and-vocabulary,
/// and docs.mistral.ai/studio/audio/migrate-from-voxtral-2.
package enum MistralRealtimeModels {
    package static let voxtral3 = "voxtral-mini-transcribe-realtime-3-0"
    package static let voxtral3Alias = "voxtral-mini-transcribe-realtime-3"

    /// The hosted Voxtral Realtime 2602 ids. Mistral's models page marks the
    /// model deprecated on 2026-10-31, retired on 2027-04-30; `GET /v1/models`
    /// still lists it without a deprecation (2026-11-04), so the picker keeps
    /// its row. `voxtral-mini-realtime-latest` is left out: the alias may move.
    package static let deprecated2602 = [
        "voxtral-mini-transcribe-realtime-2602", "voxtral-mini-realtime-2602",
    ]

    /// The dictation model to keep stored, once, when the default moved to
    /// Realtime 3: a 2602 id becomes empty, the stored form of the default,
    /// so the user follows the default from then on. Anything else is kept.
    package static func storedDictationModel(migrating stored: String) -> String {
        deprecated2602.contains(stored.trimmed.lowercased()) ? "" : stored
    }

    /// Whether `model` names Voxtral Realtime 3, by its id or its alias
    /// exactly: a later 3.x may differ on the wire, and gets 2602's frames
    /// until it is added here.
    package static func isVoxtral3(_ model: String) -> Bool {
        let id = model.trimmed.lowercased()
        return id == voxtral3 || id == voxtral3Alias
    }

    /// Only Voxtral 3 lists `context_bias` among its session fields; the docs
    /// do not say 2602 accepts it, and a field it refused would end the
    /// session. The docs set no fixed count, but a list over the model's limit
    /// is a 400 and the terms share its context with the audio. The batch
    /// model's 100 is the cap until a live check finds the realtime one.
    package static func capabilities(for model: String) -> DictationModelCapabilities {
        isVoxtral3(model) ? DictationModelCapabilities(termBias: .sessionList(maxTerms: 100)) : .audioOnly
    }
}
