import Foundation

/// What the app knows about each of Mistral's realtime transcription models
/// that changes what goes on the wire.
///
/// Voxtral Mini Transcribe Realtime 3 (`voxtral-mini-transcribe-realtime-3-0`,
/// alias `voxtral-mini-transcribe-realtime-3`, public preview since
/// 2026-10-20, no open weights) takes a `context_bias` array in
/// `session.update`, before the first audio chunk, with phrases holding
/// spaces allowed. Its documented end of stream is `input_audio.end` alone.
/// Docs, checked 2026-10-21: docs.mistral.ai/studio/audio/speech-to-text/
/// transcribe-in-realtime ("Session fields"), .../bias-context-and-vocabulary,
/// and docs.mistral.ai/studio/audio/migrate-from-voxtral-2.
package enum MistralRealtimeModels {
    package static let voxtral3 = "voxtral-mini-transcribe-realtime-3-0"

    /// Whether `model` names Voxtral Realtime 3, by its id or its alias.
    package static func isVoxtral3(_ model: String) -> Bool {
        model.trimmed.lowercased().hasPrefix("voxtral-mini-transcribe-realtime-3")
    }

    /// Only Voxtral 3 lists `context_bias` among its session fields; the docs
    /// do not say 2602 accepts it, and a field it refused would end the session.
    package static func acceptsContextBias(_ model: String) -> Bool {
        isVoxtral3(model)
    }

    /// 2602's stop flushes, then ends. Voxtral 3 documents no flush event.
    package static func sendsFlushBeforeEnd(_ model: String) -> Bool {
        !isVoxtral3(model)
    }

    /// The docs set no count limit; the terms share the model's context with
    /// the audio. The batch model's 100 keeps a long dictation clear of it.
    package static let maxContextBiasTerms = 100

    /// The `context_bias` list for a realtime session: candidates in priority
    /// order, whitespace runs collapsed to one space, duplicates dropped by a
    /// case-insensitive key keeping the first spelling, and cut at 100.
    /// Unlike the batch list, phrases keep their spaces and commas.
    package static func contextBias(from candidates: [String]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for candidate in candidates {
            let words = candidate.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            guard !words.isEmpty else { continue }
            let term = words.joined(separator: " ")
            guard seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == maxContextBiasTerms { break }
        }
        return terms
    }
}
