import Foundation

/// Merges the grounding entries proposed by several context sources into the
/// single set that gets pre-applied to the transcript before the polish call.
///
/// Each source matches independently and knows nothing about the others, so a
/// merge has to answer three questions the per-source matchers cannot:
///
/// - Two sources propose the SAME exact term for a heard span. That is not a
///   conflict, it is corroboration — keep one entry.
/// - Two sources propose DIFFERENT exact terms for the same heard span. Nothing
///   here can tell which is right, and pre-applying the wrong bytes edits the
///   user's words into something they did not say. Abstain on that span
///   entirely — the same rule `RepoVocabularyMatcher.groundedCandidateEntries`
///   already applies to tied fuzzy hits within one source.
/// - One source has only a FALLBACK guess for a span (its exact and
///   edit-distance-one tiers found nothing and the bounded aligned matcher
///   guessed) while another has a solid hit on that span. The solid hit wins;
///   the guess is dropped rather than allowed to compete.
/// - Weak evidence never rewrites text. Explicit verification candidates and
///   conflicting guess-grade readings remain bounded prompt suggestions only
///   while their literal heard bytes have not been pre-applied by another hit.
///
/// Pure and deterministic — decisions depend only on the candidates and the
/// fixed `PolishContextSource` order.
enum PolishContextGrounding {
    /// One source's proposal.
    struct Candidate: Sendable {
        let source: PolishContextSource
        let entries: [ReplacementEntry]
        /// True when `entries` came from the bounded aligned fallback rather
        /// than the exact / edit-distance-one tiers — a guess, admissible only
        /// while no better-grounded source covers the same heard span.
        let isFallbackOnly: Bool
        /// Exact, unambiguous phonetic evidence is pre-apply eligible inside a
        /// source, but remains guess grade when sources are reconciled.
        let phoneticEntries: [ReplacementEntry]
        /// Prompt-only possible-mishearing suggestions. They never enter the
        /// pre-application vote directly.
        let verificationEntries: [ReplacementEntry]

        init(
            source: PolishContextSource,
            entries: [ReplacementEntry],
            isFallbackOnly: Bool,
            phoneticEntries: [ReplacementEntry] = [],
            verificationEntries: [ReplacementEntry] = []
        ) {
            self.source = source
            self.entries = entries
            self.isFallbackOnly = isFallbackOnly
            self.phoneticEntries = phoneticEntries
            self.verificationEntries = verificationEntries
        }
    }

    struct VerificationPair: Equatable {
        let heard: String
        let exact: String
    }

    /// The merged grounding, retaining which source each surviving entry came
    /// from so each one can still render under its own honest prompt header.
    struct Merged: Equatable {
        /// Every surviving entry, in source order — what gets pre-applied.
        let all: [ReplacementEntry]
        private let bySource: [PolishContextSource: [ReplacementEntry]]
        /// Bounded prompt-only suggestions whose literal heard bytes survived
        /// pre-application unchanged.
        let verificationPairs: [VerificationPair]

        init(
            all: [ReplacementEntry],
            bySource: [PolishContextSource: [ReplacementEntry]],
            verificationPairs: [VerificationPair] = []
        ) {
            self.all = all
            self.bySource = bySource
            self.verificationPairs = verificationPairs
        }

        /// The surviving entries attributed to `source`. A term two sources
        /// agreed on is attributed to the earlier `allocationRank` — it appears
        /// exactly once across all sources, never duplicated into both.
        func entries(from source: PolishContextSource) -> [ReplacementEntry] {
            bySource[source] ?? []
        }
    }

    static let maxVerificationPairs = 4

    /// Merges `candidates` under the rules documented on this type.
    static func merge(_ candidates: [Candidate]) -> Merged {
        // Fixed order, stably: rank first, then the caller's order among equal
        // ranks. `sorted(by:)` is not guaranteed stable, so the original index
        // is part of the key.
        let ordered = candidates.enumerated().sorted { lhs, rhs in
            if lhs.element.source.allocationRank != rhs.element.source.allocationRank {
                return lhs.element.source.allocationRank < rhs.element.source.allocationRank
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var pairs: [Pair] = []
        for candidate in ordered {
            for entry in candidate.entries {
                for heard in entry.matches {
                    pairs.append(Pair(
                        source: candidate.source,
                        exact: entry.replaceWith,
                        heard: heard,
                        heardKey: RepoVocabularyMatcher.normalize(heard),
                        isGuess: candidate.isFallbackOnly
                    ))
                }
            }
            for entry in candidate.phoneticEntries {
                for heard in entry.matches {
                    pairs.append(Pair(
                        source: candidate.source,
                        exact: entry.replaceWith,
                        heard: heard,
                        heardKey: RepoVocabularyMatcher.normalize(heard),
                        isGuess: true
                    ))
                }
            }
        }

        // Spans are compared NORMALIZED: two sources describing the same span
        // may have heard it written slightly differently ("use auth dot ts" vs
        // "useauth dot ts"), and those must corroborate/conflict rather than
        // pass each other by. The literal span is what survives into the entry,
        // because pre-application matches literal transcript bytes.
        let solidKeys = Set(pairs.filter { !$0.isGuess }.map(\.heardKey))
        let grounded = pairs.filter { !$0.isGuess || !solidKeys.contains($0.heardKey) }

        var termsByKey: [String: Set<String>] = [:]
        for pair in grounded {
            termsByKey[pair.heardKey, default: []].insert(pair.exact)
        }
        let ambiguousKeys = Set(termsByKey.compactMap { key, terms in
            terms.count > 1 ? key : nil
        })
        let surviving = grounded.filter { !ambiguousKeys.contains($0.heardKey) }

        // Group by exact term, first appearance wins the term (and with it the
        // source attribution), so agreement collapses to one entry instead of
        // two identical ones.
        var order: [String] = []
        var heardByTerm: [String: [String]] = [:]
        var seenHeardByTerm: [String: Set<String>] = [:]
        var sourceByTerm: [String: PolishContextSource] = [:]
        for pair in surviving {
            if sourceByTerm[pair.exact] == nil {
                sourceByTerm[pair.exact] = pair.source
                order.append(pair.exact)
            }
            if seenHeardByTerm[pair.exact, default: []].insert(pair.heard).inserted {
                heardByTerm[pair.exact, default: []].append(pair.heard)
            }
        }

        var all: [ReplacementEntry] = []
        var bySource: [PolishContextSource: [ReplacementEntry]] = [:]
        for term in order {
            guard let matches = heardByTerm[term], let source = sourceByTerm[term] else { continue }
            let entry = ReplacementEntry(replaceWith: term, matches: matches)
            all.append(entry)
            bySource[source, default: []].append(entry)
        }

        let preAppliedKeys = Set(surviving.map(\.heardKey))
        var verificationPairs: [VerificationPair] = []
        var seenVerification = Set<VerificationKey>()
        func appendVerification(heard: String, exact: String) {
            guard verificationPairs.count < maxVerificationPairs,
                  heard != exact
            else { return }
            let heardKey = RepoVocabularyMatcher.normalize(heard)
            guard !preAppliedKeys.contains(heardKey) else { return }
            let key = VerificationKey(heardKey: heardKey, exact: exact)
            guard seenVerification.insert(key).inserted else { return }
            verificationPairs.append(VerificationPair(heard: heard, exact: exact))
        }

        // Explicit weak evidence retains source rank ordering. It precedes
        // conflict demotions so each matcher gets first claim on the small
        // verification budget it deliberately emitted.
        for candidate in ordered {
            for entry in candidate.verificationEntries {
                for heard in entry.matches {
                    appendVerification(heard: heard, exact: entry.replaceWith)
                }
            }
        }

        // Only ambiguous GUESS keys become suggestions. Solid-vs-solid
        // disagreement remains a plain abstention, while guesses that yielded
        // to a solid were removed before ambiguity and cannot be resurrected.
        let ambiguousGuessKeys = ambiguousKeys.subtracting(solidKeys)
        for pair in grounded where ambiguousGuessKeys.contains(pair.heardKey) {
            appendVerification(heard: pair.heard, exact: pair.exact)
        }

        return Merged(
            all: all,
            bySource: bySource,
            verificationPairs: verificationPairs
        )
    }

    private struct Pair {
        let source: PolishContextSource
        let exact: String
        let heard: String
        let heardKey: String
        let isGuess: Bool
    }

    private struct VerificationKey: Hashable {
        let heardKey: String
        let exact: String
    }
}
