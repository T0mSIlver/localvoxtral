import Foundation

/// What a dictation model takes besides audio, whichever backend serves it:
/// the bundled helper's catalog (`SpeechModelOption.capabilities`) or a hosted
/// model (`MistralRealtimeModels.capabilities(for:)`). A session asks the model
/// it dictates with, never which vendor serves it, so a new model that takes
/// terms is a catalog change.
package struct DictationModelCapabilities: Equatable, Sendable {
    /// The terms a model takes when a session starts.
    package enum TermBias: Equatable, Sendable {
        /// The model takes no terms.
        case none
        /// A list in the session's opening message, in priority order, cut at
        /// `maxTerms`. Terms keep their spaces: Voxtral Realtime 3 takes
        /// phrases, unlike the batch model's single words.
        case sessionList(maxTerms: Int)
    }

    package let termBias: TermBias

    package init(termBias: TermBias) {
        self.termBias = termBias
    }

    /// A model that takes audio and nothing else: Voxtral locally,
    /// and an External URL server, whose model the app can't vouch for.
    package static let audioOnly = DictationModelCapabilities(termBias: .none)

    /// The list a session sends at start: `candidates` in priority order,
    /// whitespace runs collapsed to one space, duplicates dropped by a
    /// case-insensitive key keeping the first spelling, cut at the model's
    /// cap. Empty for a model that takes no terms.
    package func sessionTerms(from candidates: [String]) -> [String] {
        guard case .sessionList(let maxTerms) = termBias else { return [] }
        var seen = Set<String>()
        var terms: [String] = []
        for candidate in candidates {
            guard terms.count < maxTerms else { break }
            let words = candidate.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            guard !words.isEmpty else { continue }
            let term = words.joined(separator: " ")
            guard seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        return terms
    }
}
