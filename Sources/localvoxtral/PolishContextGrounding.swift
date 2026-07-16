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
///
/// Pure and deterministic — decisions depend only on the candidates and the
/// fixed `PolishContextSource` order.
enum PolishContextGrounding {
    /// One source's proposal.
    struct Candidate {
        let source: PolishContextSource
        let entries: [ReplacementEntry]
        /// True when `entries` came from the bounded aligned fallback rather
        /// than the exact / edit-distance-one tiers — a guess, admissible only
        /// while no better-grounded source covers the same heard span.
        let isFallbackOnly: Bool

        init(source: PolishContextSource, entries: [ReplacementEntry], isFallbackOnly: Bool) {
            self.source = source
            self.entries = entries
            self.isFallbackOnly = isFallbackOnly
        }
    }

    /// The merged grounding, retaining which source each surviving entry came
    /// from so each one can still render under its own honest prompt header.
    struct Merged: Equatable {
        /// Every surviving entry, in source order — what gets pre-applied.
        let all: [ReplacementEntry]
        private let bySource: [PolishContextSource: [ReplacementEntry]]

        init(all: [ReplacementEntry], bySource: [PolishContextSource: [ReplacementEntry]]) {
            self.all = all
            self.bySource = bySource
        }

        /// The surviving entries attributed to `source`. A term two sources
        /// agreed on is attributed to the earlier `allocationRank` — it appears
        /// exactly once across all sources, never duplicated into both.
        func entries(from source: PolishContextSource) -> [ReplacementEntry] {
            bySource[source] ?? []
        }
    }

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
                        isFallbackOnly: candidate.isFallbackOnly
                    ))
                }
            }
        }
        guard !pairs.isEmpty else { return Merged(all: [], bySource: [:]) }

        // Spans are compared NORMALIZED: two sources describing the same span
        // may have heard it written slightly differently ("use auth dot ts" vs
        // "useauth dot ts"), and those must corroborate/conflict rather than
        // pass each other by. The literal span is what survives into the entry,
        // because pre-application matches literal transcript bytes.
        let solidKeys = Set(pairs.filter { !$0.isFallbackOnly }.map(\.heardKey))
        let grounded = pairs.filter { !$0.isFallbackOnly || !solidKeys.contains($0.heardKey) }

        var termsByKey: [String: Set<String>] = [:]
        for pair in grounded {
            termsByKey[pair.heardKey, default: []].insert(pair.exact)
        }
        let ambiguousKeys = Set(termsByKey.compactMap { key, terms in
            terms.count > 1 ? key : nil
        })
        let surviving = grounded.filter { !ambiguousKeys.contains($0.heardKey) }
        guard !surviving.isEmpty else { return Merged(all: [], bySource: [:]) }

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
        return Merged(all: all, bySource: bySource)
    }

    private struct Pair {
        let source: PolishContextSource
        let exact: String
        let heard: String
        let heardKey: String
        let isFallbackOnly: Bool
    }
}
