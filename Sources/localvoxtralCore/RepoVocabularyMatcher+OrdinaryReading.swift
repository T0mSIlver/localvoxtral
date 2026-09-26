import Foundation

// MARK: - Learned terms: the ordinary reading

/// A learned term is memory, not something on screen now: `toolInput` learned
/// last week says nothing about whether "log the tool input" today means the
/// field or the words. When its heard span is ordinary lowercase words and
/// nothing around them points at code, the ordinary reading is the likelier
/// one, so the term is not pre-applied. It goes to the model as a
/// verification pair instead, which sees the whole sentence (#522).
///
/// The evidence is what the transcript itself carries, because the exact tier
/// has no score to threshold: its hits normalize to the term, so every one of
/// them is equally sure of the letters and none says which reading was meant.
/// A user reverting a learned spelling is the other signal, and it deletes the
/// term outright (`LearnedTerms.forget`, #520).
extension RepoVocabularyMatcher {
    /// Code words that make a neighbouring span an identifier: "the session
    /// start hook", "la fonction use auth". They count on either side, since
    /// French puts the noun first and English usually after.
    package static let codeNounCues: Set<String> = [
        "hook", "hooks", "function", "functions", "fonction", "method",
        "methods", "méthode", "callback", "handler", "event", "events",
        "événement", "field", "fields", "champ", "property", "propriété",
        "prop", "props", "variable", "var", "param", "parameter", "paramètre",
        "argument", "arg", "class", "classe", "struct", "enum",
        "protocol", "interface", "component", "composant", "module", "package",
        "flag", "key", "clé", "constant", "constante", "macro", "endpoint",
        "route", "schema", "column", "colonne", "table", "test", "tests",
        "command", "commande", "script", "file", "fichier", "api", "sdk",
        "library", "lib", "crate", "modifier",
    ]

    /// Verbs that take a code name as their object: "call use auth",
    /// "run swift lint". Counted before the span only. Verbs that take
    /// ordinary objects as often ("open a new session", "type your user
    /// name") are left out, and so is "type" as a noun.
    package static let codeVerbCues: Set<String> = [
        "call", "calls", "called", "invoke", "invokes", "import", "imports",
        "rename", "renamed", "grep", "export", "exports", "run", "runs",
        "appelle", "appeler", "importe", "importer", "renomme", "renommer",
        "lance", "lancer",
    ]

    /// Longer spans are applied whatever the context: three ordinary words in
    /// a row that spell a learned identifier ("overlay buffer state machine")
    /// are rarely an accident.
    package static let ordinaryReadingMaxWords = 2

    /// Whether `heard`, where the transcript says it, reads as ordinary words
    /// rather than as `term`. Mirrors `preapplying`: the occurrence judged is
    /// the one it would rewrite, the first with technical boundaries.
    ///
    /// True only when all of these hold:
    /// - the span is 2 to `ordinaryReadingMaxWords` words. The exact tier
    ///   only changes the case of a single word, which leaves it as said;
    /// - `term` has a lowercase letter: an acronym ("API URL") has no
    ///   ordinary reading to protect;
    /// - the recognizer wrote the span as plain lowercase words, each with a
    ///   vowel. A capital, a digit, a joiner or a spoken separator ("dot")
    ///   already marks it as a name, and a vowelless word ("cpp") has no
    ///   ordinary reading. The capital a sentence starts with marks nothing;
    /// - no code word sits within two words before it or one word after it,
    ///   and no backtick or parenthesis touches it;
    /// - `term` differs from what was heard (otherwise there is nothing to
    ///   pre-apply).
    package static func ordinaryReadingIsLikelier(
        term: String,
        heard: String,
        transcript: String
    ) -> Bool {
        let wordCount = heard.split(separator: " ").count
        guard term != heard,
              (2...ordinaryReadingMaxWords).contains(wordCount),
              term.contains(where: \.isLowercase)
        else { return false }
        var searchStart = transcript.startIndex
        while searchStart < transcript.endIndex,
              let range = transcript.range(of: heard, range: searchStart..<transcript.endIndex)
        {
            if hasTechnicalBoundaries(in: transcript, range: range) {
                return isPlainWords(heard, atSentenceStart: isSentenceStart(range.lowerBound, in: transcript))
                    && !hasCodeContext(around: range, in: transcript)
            }
            searchStart = range.upperBound
        }
        return false
    }

    /// `outcome` with every entry whose ordinary reading is likelier moved
    /// from the pre-applied entries to the front of the verification pairs:
    /// the strongest evidence among them, and still capped at
    /// `nominationCap`. An entry keeps whichever of its spans still apply.
    package static func withholdingOrdinaryReadings(
        _ outcome: GroundingOutcome,
        transcript: String
    ) -> GroundingOutcome {
        var kept: [ReplacementEntry] = []
        var withheld: [ReplacementEntry] = []
        for entry in outcome.entries {
            let ordinary = entry.matches.filter {
                ordinaryReadingIsLikelier(term: entry.replaceWith, heard: $0, transcript: transcript)
            }
            let applied = entry.matches.filter { !ordinary.contains($0) }
            if !applied.isEmpty {
                kept.append(ReplacementEntry(replaceWith: entry.replaceWith, matches: applied))
            }
            withheld += ordinary.map { ReplacementEntry(replaceWith: entry.replaceWith, matches: [$0]) }
        }
        guard !withheld.isEmpty else { return outcome }
        let verification = Array(
            (withheld + outcome.verificationCandidates).prefix(nominationCap(forTranscript: transcript))
        )
        return GroundingOutcome(
            entries: kept,
            isFallbackOnly: outcome.isFallbackOnly,
            phoneticEntries: outcome.phoneticEntries,
            verificationCandidates: verification
        )
    }

    private static let vowels = Set("aeiouyàâäéèêëîïôöùûüÿæœ")

    private static func isPlainWords(_ heard: String, atSentenceStart: Bool) -> Bool {
        let words = heard.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        return words.enumerated().allSatisfy { index, word in
            let letters = index == 0 && atSentenceStart
                ? word.prefix(1).lowercased() + word.dropFirst()
                : word
            return !spokenSeparators.contains(letters)
                && letters.allSatisfy { $0.isLetter && $0.isLowercase }
                && letters.contains { vowels.contains($0) }
        }
    }

    private static func isSentenceStart(_ index: String.Index, in text: String) -> Bool {
        guard let previous = text[..<index].last(where: { !$0.isWhitespace }) else { return true }
        return ".!?:".contains(previous)
    }

    private static func hasCodeContext(around range: Range<String.Index>, in text: String) -> Bool {
        // Lowercased with accents kept: the French cues are spelled with them.
        let before = tokenize(String(text[..<range.lowerBound])).suffix(2).map { $0.lowercased() }
        let after = tokenize(String(text[range.upperBound...])).prefix(1).map { $0.lowercased() }
        if before.contains(where: { codeNounCues.contains($0) || codeVerbCues.contains($0) })
            || after.contains(where: { codeNounCues.contains($0) })
        {
            return true
        }
        let marks: Set<Character> = ["`", "(", ")"]
        if range.lowerBound > text.startIndex,
           marks.contains(text[text.index(before: range.lowerBound)])
        {
            return true
        }
        if range.upperBound < text.endIndex, marks.contains(text[range.upperBound]) {
            return true
        }
        return false
    }
}
