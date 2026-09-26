import Foundation

// MARK: - Verification prompt section

extension RepoVocabularyMatcher {
    /// Renders the merge's prompt-only nominations as a plain term list. Terms
    /// pass through the same single-line defense as vocabulary terms.
    package static func verificationPromptSection(
        pairs: [PolishContextGrounding.VerificationPair]
    ) -> String {
        var seen = Set<String>()
        let lines: [String] = pairs.compactMap { pair in
            let heard = sanitizedTerm(pair.heard)
            let exact = sanitizedTerm(pair.exact)
            guard isRenderableTerm(heard),
                  isRenderableTerm(exact),
                  heard != exact,
                  seen.insert(exact).inserted
            else { return nil }
            return "- \(exact)"
        }
        guard !lines.isEmpty else { return "" }
        return "\(verificationCandidatesHeader)\n\(lines.joined(separator: "\n"))"
    }

    /// Appends prompt-only verification suggestions beside the replacement-
    /// dictionary sections. An empty base leaves the section standing alone;
    /// if sanitization removes every pair, the existing base stays byte-exact.
    package static func appendedVerificationSection(
        base: String,
        pairs: [PolishContextGrounding.VerificationPair]
    ) -> String {
        let section = verificationPromptSection(pairs: pairs)
        guard !section.isEmpty else { return base }
        guard !base.isEmpty else { return section }
        return base + "\n\n" + section
    }
}
