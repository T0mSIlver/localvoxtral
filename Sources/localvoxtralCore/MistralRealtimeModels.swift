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
