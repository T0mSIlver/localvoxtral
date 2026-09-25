/// Terms a client expects to hear in its dictation, sent as `vocabulary` in
/// `session.update`. An engine that can bias its decoding toward them does
/// (Nemotron's term boost, #521); one that cannot ignores the list. Only
/// counts ever reach the helper log, never the terms.
public struct SessionVocabulary: Equatable, Sendable {
    /// Beyond this many terms, later ones are dropped. A short list of terms
    /// the recognizer misses beats a long one: every listed term is a chance
    /// to write it where it was not said.
    public static let maxTerms = 100
    /// Longer entries are dropped: a sentence is no term.
    public static let maxTermCharacters = 64

    /// Trimmed, non-empty, case-insensitively unique, in the client's order.
    public let terms: [String]

    public init(_ rawTerms: [String]) {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in rawTerms {
            let term = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !term.isEmpty, term.count <= Self.maxTermCharacters,
                  seen.insert(term.lowercased()).inserted
            else { continue }
            terms.append(term)
            if terms.count == Self.maxTerms { break }
        }
        self.terms = terms
    }

    public static let empty = SessionVocabulary([])
}

/// Bonus sizes for engines that boost vocabulary terms, in logits; see
/// `NemotronASRTermBoostConfig` upstream. `--term-boost` overrides them for
/// tuning runs; the app never passes it.
public struct TermBoostSettings: Equatable, Sendable {
    public var firstTokenBoost: Float
    public var continuationBoost: Float
    public var margin: Float

    public init(firstTokenBoost: Float, continuationBoost: Float, margin: Float) {
        self.firstTokenBoost = firstTokenBoost
        self.continuationBoost = continuationBoost
        self.margin = margin
    }

    /// `first,continuation,margin`, e.g. `1.5,3,4`. Nil unless all three are
    /// finite and non-negative.
    public init?(parsing value: String) {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map { Float($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil && $0!.isFinite && $0! >= 0 }) else {
            return nil
        }
        self.init(firstTokenBoost: parts[0]!, continuationBoost: parts[1]!, margin: parts[2]!)
    }
}
