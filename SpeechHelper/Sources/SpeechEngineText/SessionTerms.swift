/// The terms a client expects to hear in its dictation, sent as `context_bias`
/// in `session.update` (Mistral's name for the same list). An engine that can
/// bias its decoding toward them does; one that cannot ignores the list. Only
/// counts ever reach the helper log, never the terms.
public struct SessionTerms: Equatable, Sendable {
    /// Beyond this many terms, later ones are dropped. The app sends its most
    /// specific terms first, and every listed term is a chance to write it
    /// where it was not said.
    public static let maxTerms = 100
    /// Longer entries are dropped: a sentence is not a term.
    public static let maxTermCharacters = 64

    /// Whitespace-collapsed, non-empty, case-insensitively unique, in the
    /// client's order.
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

    public static let empty = SessionTerms([])
}
