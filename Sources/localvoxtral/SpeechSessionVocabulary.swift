import Foundation

/// The term list a dictation sends the bundled speech helper as `vocabulary`
/// in `session.update` (#521). Nemotron boosts these terms while it decodes;
/// Voxtral ignores the list until its decoder has a logits hook (#316).
///
/// Short and high-precision on purpose: every listed term is a chance to write
/// it where it was not said. So only spellings the user vouched for go in: the
/// hand-written list first, then learned terms that polish confirmed across
/// several dictations, strongest evidence first.
enum SpeechSessionVocabulary {
    /// The helper keeps at most this many (`SessionVocabulary.maxTerms`).
    static let maxTerms = 100

    static func terms(speakerTerms: [String], learnedTerms: [String]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in speakerTerms + learnedTerms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.caseFoldedForMatching).inserted else { continue }
            terms.append(term)
            if terms.count == maxTerms { break }
        }
        return terms
    }
}
