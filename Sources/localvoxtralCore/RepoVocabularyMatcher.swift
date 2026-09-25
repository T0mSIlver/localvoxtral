import Foundation

// MARK: - 3. Transcript matching

/// Matches spoken transcript n-grams against repo vocabulary and emits
/// `ReplacementEntry`s (exact spelling -> the spoken form) for the polish
/// prompt. Pure functions, mirroring `PolishTokenGuard` / `TextMergingAlgorithms`.
package enum RepoVocabularyMatcher {
    /// Hard cap on emitted entries — grounding hints, not an index dump.
    package static let maxEntries = 12
    /// Minimum normalized length on BOTH sides. Drops collision-prone short
    /// forms (`app`, `src`) as standalone entries while still letting them count
    /// inside longer n-grams (`app.tsx`).
    package static let minNormalizedLength = 4
    /// Minimum normalized length (both sides) for the edit-distance-1 fuzzy
    /// tier — short forms would collide constantly.
    package static let fuzzyMinNormalizedLength = 8
    /// A single word needs more evidence than a multi-word phrase before
    /// pronunciation alone may nominate it. Short homophones such as
    /// `pane`/`pain` therefore remain ordinary prose unless another tier owns
    /// them, while a phrase like `terminal pane` is eligible.
    package static let phoneticMinSingleWordNormalizedLength = 8
    /// Ranking grade, not a rewrite: since the 2026-09-18 rework no phonetic
    /// hit is pre-applied, and hits meeting these thresholds are only offered
    /// to the model AHEAD of weaker ones. The thresholds were set when the
    /// grade did mean a silent rewrite, which demanded more evidence than a
    /// verification suggestion, for every window shape: the heard span must
    /// carry as many normalized characters as a single-word candidate needs,
    /// and the agreeing key must carry enough consonant structure that the
    /// agreement is unlikely to be a short-homophone accident. Otherwise a
    /// multi-word term gluing a stopword onto a short homophone (`thePane`
    /// heard as "the pain") would silently rewrite ordinary prose. Weaker
    /// exact-key hits remain verification candidates.
    package static let phoneticMinPreApplyNormalizedLength = 8
    package static let phoneticMinPreApplyKeyLength = 6
    /// Bounds both index expansion (at most 2^4 key variants) and transcript
    /// n-grams. Longer identifiers are better served by the character tiers.
    package static let phoneticMaxWordUnits = 4
    /// Weak phonetic evidence is prompt-only and deliberately scarce: it
    /// should help verification, not become a vocabulary dump.
    package static let phoneticMaxVerificationCandidates = 4

    /// How many sound-alike terms one dictation may be offered. A fixed four
    /// starved long dictations (five damaged file names in a 300-word prompt
    /// lost one) while already being generous for a sentence, so the cap keeps
    /// roughly the same density instead: four up to 60 words, one more per 15
    /// words after that, never above `maxEntries` — broad lists regressed the
    /// 4B model in the 2026-07-21 context eval.
    package static func nominationCap(forTranscript transcript: String) -> Int {
        min(maxEntries, max(phoneticMaxVerificationCandidates, tokenize(transcript).count / 15))
    }
    /// The aligned fallback is intentionally narrower than the exact matcher:
    /// short strings collide too easily in normal prose.
    package static let alignedMinNormalizedLength = 8
    package static let alignedMinimumScore = 0.60
    package static let alignedMinimumMargin = 0.05
    package static let alignedVerificationMinimumScore = 0.55
    package static let alignedMaxWords = 7
    /// A span whose rarest shared n-gram still fans out beyond this cap is not
    /// distinctive enough for deterministic grounding. This also bounds work
    /// in large same-language monorepos.
    package static let alignedMaxCandidatesPerSpan = 512

    /// Spoken separator words map to the symbols the file side already strips,
    /// so "use auth dot t s" normalizes identically to `useAuth.ts`.
    static let spokenSeparators: Set<String> =
        ["dot", "point", "slash", "dash", "hyphen", "underscore"]

    /// Small stopword set: an n-gram made up entirely of these (or spoken
    /// separators) can never be a file/identifier and is skipped.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "to", "in", "of", "and", "or", "for", "on", "at",
        "is", "it", "file", "this", "that", "with", "my", "please",
    ]

    /// Normalizes for comparison: lowercase, drop spoken separator words, strip
    /// `.`/`/`/`_`/`-` and whitespace. "use auth dot t s" -> "useauthts";
    /// "useAuth.ts" -> "useauthts".
    package static func normalize(_ text: String) -> String {
        let tokens = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        var output = ""
        for token in tokens {
            let stripped = stripJoiners(String(token))
            if spokenSeparators.contains(stripped) { continue }
            output += stripped
        }
        return output
    }

    /// Splits a local spelling into the word units a speaker can pronounce.
    /// Repository joiners and whitespace are boundaries, as are the two
    /// identifier transitions that reliably introduce a spoken unit:
    /// lower-to-upper camel case and letter-to-digit. Units containing no
    /// letters are discarded because Double Metaphone cannot add evidence for
    /// punctuation or a bare numeric component.
    package static func phoneticWordUnits(of term: String) -> [String] {
        var units: [String] = []
        var current = ""
        var previous: Character?

        func finishUnit() {
            guard !current.isEmpty else { return }
            if current.contains(where: { $0.isLetter }) {
                units.append(current)
            }
            current.removeAll(keepingCapacity: true)
        }

        for character in term {
            if character.isWhitespace || "./_-".contains(character) {
                finishUnit()
                previous = nil
                continue
            }
            if let previous,
               (previous.isLowercase && character.isUppercase)
                    || (previous.isLetter && character.isNumber)
            {
                finishUnit()
            }
            current.append(character)
            previous = character
        }
        finishUnit()
        return units
    }

    /// Enumerates primary/secondary choices without duplicate variants. With
    /// the four-unit cap this produces at most sixteen strings per term or
    /// heard span, keeping both indexing and matching strictly bounded.
    package static func phoneticVariants(for wordUnits: [String]) -> [String] {
        guard !wordUnits.isEmpty, wordUnits.count <= phoneticMaxWordUnits else { return [] }
        var variants = [""]
        for unit in wordUnits {
            let key = DoubleMetaphone.encode(unit)
            var choices: [String] = []
            if !key.primary.isEmpty { choices.append(key.primary) }
            if !key.secondary.isEmpty, key.secondary != key.primary {
                choices.append(key.secondary)
            }
            guard !choices.isEmpty else { return [] }
            variants = variants.flatMap { prefix in
                choices.map { prefix + $0 }
            }
        }
        var seen = Set<String>()
        return variants.filter { seen.insert($0).inserted }
    }

    /// Result of the phonetic tier over one transcript. `preApply` contains
    /// only an unambiguous exact-key guess; weaker evidence is retained solely
    /// for a later prompt verification channel.
    package struct PhoneticOutcome: Equatable, Sendable {
        package let preApply: [ReplacementEntry]
        package let verification: [ReplacementEntry]

        package static let empty = PhoneticOutcome(preApply: [], verification: [])
    }

    /// Matches transcript word n-grams through the prebuilt phonetic indexes.
    /// Exact/fuzzy character ownership is checked before recording a hit, so
    /// phonetics never duplicate stronger evidence. Exact pronunciation is a
    /// pre-apply guess only when one distinct local term owns the heard key;
    /// ambiguity, distance-one pronunciation, and unspoken extensions remain
    /// prompt-only suggestions.
    package static func phoneticCandidates(
        transcript: String,
        vocabulary: RepoVocabulary
    ) -> PhoneticOutcome {
        let words = tokenize(transcript)
        guard !words.isEmpty, !vocabulary.phoneticCandidates.isEmpty else { return .empty }

        var bestPreApplyByTerm: [String: PhoneticHit] = [:]
        var bestVerificationByTerm: [String: PhoneticHit] = [:]

        func record(_ hit: PhoneticHit, preApply: Bool) {
            if preApply {
                if let existing = bestPreApplyByTerm[hit.term],
                   !phoneticHit(hit, isBetterThan: existing)
                {
                    return
                }
                bestPreApplyByTerm[hit.term] = hit
            } else {
                if let existing = bestVerificationByTerm[hit.term],
                   !phoneticHit(hit, isBetterThan: existing)
                {
                    return
                }
                bestVerificationByTerm[hit.term] = hit
            }
        }

        // A repeated phrase re-derives the same key variants; its first
        // transcript position is already its best rank, so each (window
        // length, variant) pair is swept for near keys at most once —
        // mirrors `fuzzySweptGrams` in the character tier.
        var phoneticSweptVariants = Set<String>()

        for start in words.indices {
            let maxWindow = min(phoneticMaxWordUnits, words.count - start)
            for length in 1...maxWindow {
                let window = Array(words[start..<(start + length)])
                if window.allSatisfy({ isCommon($0) }) { continue }
                let spoken = window.joined(separator: " ")
                let normalizedGram = normalize(spoken)
                guard normalizedGram.count >= minNormalizedLength else { continue }

                let gramVariants = phoneticVariants(for: window)
                guard !gramVariants.isEmpty else { continue }

                var exactIndexes = Set<Int>()
                for variant in gramVariants {
                    exactIndexes.formUnion(vocabulary.phoneticIndex[variant] ?? [])
                }
                exactIndexes = Set(exactIndexes.filter { candidateIndex in
                    let candidate = vocabulary.phoneticCandidates[candidateIndex]
                    return candidate.wordUnitCount == length
                        && !characterTierOwns(
                            heardNormalized: normalizedGram,
                            candidateNormalized: candidate.normalized
                        )
                })

                if !exactIndexes.isEmpty {
                    let distinctTerms = Set(exactIndexes.map {
                        vocabulary.phoneticCandidates[$0].term
                    })
                    let ambiguous = distinctTerms.count > 1
                    for candidateIndex in exactIndexes {
                        let candidate = vocabulary.phoneticCandidates[candidateIndex]
                        let hit = PhoneticHit(
                            term: candidate.term,
                            normalizedLength: candidate.normalized.count,
                            position: start,
                            spoken: spoken,
                            exactKey: true
                        )
                        let carriesUnspokenExtension: Bool
                        if let fileExtension = shortFileExtension(in: candidate.term) {
                            carriesUnspokenExtension = !spoken.lowercased().contains(
                                ".\(fileExtension)"
                            )
                        } else {
                            carriesUnspokenExtension = false
                        }
                        let carriesPreApplyEvidence =
                            normalizedGram.count >= phoneticMinPreApplyNormalizedLength
                            && gramVariants.contains { variant in
                                variant.count >= phoneticMinPreApplyKeyLength
                                    && (vocabulary.phoneticIndex[variant] ?? [])
                                        .contains(candidateIndex)
                            }
                        record(
                            hit,
                            preApply: !ambiguous && !carriesUnspokenExtension
                                && carriesPreApplyEvidence
                        )
                    }
                    // An exact pronunciation already owns this heard span.
                    // Distance-one neighbors would add noise, not evidence.
                    continue
                }

                var nearIndexes = Set<Int>()
                for variant in gramVariants where variant.count >= 4 {
                    guard phoneticSweptVariants.insert("\(length):\(variant)").inserted
                    else { continue }
                    let variantCharacters = Array(variant)
                    for bucketLength in (variant.count - 1)...(variant.count + 1) {
                        for indexed in vocabulary.phoneticBuckets[bucketLength] ?? [] {
                            guard isEditDistanceAtMostOne(
                                variantCharacters, indexed.variant
                            ) else { continue }
                            nearIndexes.insert(indexed.candidateIndex)
                        }
                    }
                }
                for candidateIndex in nearIndexes {
                    let candidate = vocabulary.phoneticCandidates[candidateIndex]
                    guard candidate.wordUnitCount == length,
                          !characterTierOwns(
                              heardNormalized: normalizedGram,
                              candidateNormalized: candidate.normalized
                          )
                    else { continue }
                    record(PhoneticHit(
                        term: candidate.term,
                        normalizedLength: candidate.normalized.count,
                        position: start,
                        spoken: spoken,
                        exactKey: false
                    ), preApply: false)
                }
            }
        }

        // One term cannot be both rewritten and suggested. An exact,
        // unambiguous key is the better evidence regardless of where a weaker
        // near-key appeared in the transcript.
        for term in bestPreApplyByTerm.keys {
            bestVerificationByTerm.removeValue(forKey: term)
        }
        let rank: (PhoneticHit, PhoneticHit) -> Bool = { lhs, rhs in
            if lhs.normalizedLength != rhs.normalizedLength {
                return lhs.normalizedLength > rhs.normalizedLength
            }
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.term < rhs.term
        }
        let preApply = bestPreApplyByTerm.values.sorted(by: rank).prefix(maxEntries).map {
            ReplacementEntry(replaceWith: $0.term, matches: [$0.spoken])
        }
        let verification = bestVerificationByTerm.values.sorted(by: rank)
            .prefix(nominationCap(forTranscript: transcript)).map {
                ReplacementEntry(replaceWith: $0.term, matches: [$0.spoken])
            }
        return PhoneticOutcome(preApply: Array(preApply), verification: Array(verification))
    }

    /// The candidate replacement entries for `transcript` grounded in
    /// `vocabulary`, ranked (longer normalized match first, then earlier
    /// transcript position) and capped. One entry per matched exact term.
    ///
    /// Complexity: the exact tier is one `exactIndex` lookup per n-gram; the
    /// fuzzy tier (grams >= `fuzzyMinNormalizedLength`, skipped entirely when
    /// the exact tier hit) sweeps only the ±1-length `fuzzyBuckets` with an
    /// early-exit distance-1 check, and each distinct normalized gram is swept
    /// at most once (its first transcript position is already its best rank).
    package static func candidateEntries(
        transcript: String,
        vocabulary: RepoVocabulary
    ) -> [ReplacementEntry] {
        rankedHits(transcript: transcript, vocabulary: vocabulary).map {
            ReplacementEntry(replaceWith: $0.term, matches: [$0.spoken])
        }
    }

    /// `candidateEntries` with each hit's tier retained: `exact` separates
    /// "the speaker said this term" from "the speaker said something one edit
    /// away from it", which decides whether the hit may rewrite the transcript.
    private static func rankedHits(
        transcript: String,
        vocabulary: RepoVocabulary
    ) -> [Hit] {
        let words = tokenize(transcript)
        guard !words.isEmpty, !vocabulary.exactIndex.isEmpty else { return [] }

        var bestByTerm: [String: Hit] = [:]
        func record(_ hit: Hit) {
            if let existing = bestByTerm[hit.term], !isBetter(hit, than: existing) { return }
            bestByTerm[hit.term] = hit
        }
        var fuzzySweptGrams = Set<String>()

        for start in 0..<words.count {
            let maxWindow = min(6, words.count - start)
            for length in 1...maxWindow {
                let window = Array(words[start..<(start + length)])
                if window.allSatisfy({ isCommon($0) }) { continue }
                let spoken = window.joined(separator: " ")
                let normalizedGram = normalize(spoken)
                guard normalizedGram.count >= minNormalizedLength else { continue }

                if let term = vocabulary.exactIndex[normalizedGram] {
                    record(Hit(
                        term: term,
                        normalizedLength: normalizedGram.count,
                        position: start,
                        spoken: spoken,
                        exact: true
                    ))
                    continue
                }

                guard normalizedGram.count >= fuzzyMinNormalizedLength,
                      fuzzySweptGrams.insert(normalizedGram).inserted
                else { continue }
                let gramCharacters = Array(normalizedGram)
                for bucketLength in (normalizedGram.count - 1)...(normalizedGram.count + 1) {
                    for candidate in vocabulary.fuzzyBuckets[bucketLength] ?? [] {
                        guard isEditDistanceAtMostOne(
                            gramCharacters, candidate.normalizedCharacters
                        ) else { continue }
                        record(Hit(
                            term: candidate.term,
                            normalizedLength: candidate.normalizedCharacters.count,
                            position: start,
                            spoken: spoken,
                            exact: false
                        ))
                    }
                }
            }
        }

        let ranked = bestByTerm.values.sorted { lhs, rhs in
            if lhs.normalizedLength != rhs.normalizedLength {
                return lhs.normalizedLength > rhs.normalizedLength
            }
            return lhs.position < rhs.position
        }
        return Array(ranked.prefix(maxEntries))
    }

    /// The spans the production matcher REWRITES: exact-tier hits only (a lone
    /// word may change letter case and nothing else). Sound-alike hits are in
    /// `groundedCandidates(...).verificationCandidates`. Historical notes on
    /// the tiers: a heard span that maps to multiple terms abstains.
    /// Exact-index hits are single-valued; multiple terms for the same span are
    /// therefore tied distance-one fuzzy hits and must all abstain. Only when
    /// those tiers leave NOTHING, try one broader aligned match (which applies
    /// its own score margin) and otherwise abstain.
    package static func groundedCandidateEntries(
        transcript: String,
        vocabulary: RepoVocabulary
    ) -> [ReplacementEntry] {
        groundedCandidates(transcript: transcript, vocabulary: vocabulary).entries
    }

    /// One source's grounding decision, carrying HOW it was reached.
    ///
    /// `entries` holds only spans that normalize to the term itself, so
    /// `isFallbackOnly` is always false here; `PolishContextGrounding` keeps
    /// the grade for callers that build candidates by hand.
    package struct GroundingOutcome: Equatable, Sendable {
        package let entries: [ReplacementEntry]
        package let isFallbackOnly: Bool
        /// Always empty from `groundedCandidates`: phonetic hits nominate now
        /// (see there). Kept because the cross-source merge and the dogfood
        /// record still carry the grade.
        package let phoneticEntries: [ReplacementEntry]
        /// Every sound-alike hit, strongest tier first. The transcript bytes
        /// stay untouched; the prompt renderer offers the terms to the model.
        package let verificationCandidates: [ReplacementEntry]

        package init(
            entries: [ReplacementEntry],
            isFallbackOnly: Bool,
            phoneticEntries: [ReplacementEntry] = [],
            verificationCandidates: [ReplacementEntry] = []
        ) {
            self.entries = entries
            self.isFallbackOnly = isFallbackOnly
            self.phoneticEntries = phoneticEntries
            self.verificationCandidates = verificationCandidates
        }

        /// Not `none`: a static of that name on a non-Optional type shadows
        /// `Optional.none` at any use site that wraps it.
        package static let empty = GroundingOutcome(
            entries: [],
            isFallbackOnly: false,
            phoneticEntries: [],
            verificationCandidates: []
        )
    }

    /// `groundedCandidateEntries` with its provenance retained.
    package static func groundedCandidates(
        transcript: String,
        vocabulary: RepoVocabulary
    ) -> GroundingOutcome {
        let hits = rankedHits(transcript: transcript, vocabulary: vocabulary)
        // A lone word that merely normalizes to a term is not evidence the
        // speaker said the term: French "Sans" equals the flag `--sans` once
        // dashes are ignored (field, 2026-09-18). One word may change its
        // letter case and nothing else; spoken forms ("use auth dot ts") are
        // several words and keep the full rewrite.
        let exactTerms = Set(hits.filter { hit in
            hit.exact && (
                hit.spoken.contains(" ")
                    || hit.spoken.lowercased() == hit.term.lowercased()
            )
        }.map(\.term))
        let approved = hits.map {
            ReplacementEntry(replaceWith: $0.term, matches: [$0.spoken])
        }
        var termsByHeard: [String: Set<String>] = [:]
        for entry in approved {
            for heard in entry.matches {
                termsByHeard[heard, default: []].insert(entry.replaceWith)
            }
        }
        let ambiguousHeard = Set(
            termsByHeard.compactMap { heard, terms in
                terms.count > 1 ? heard : nil
            }
        )
        let unambiguous = approved.compactMap { entry -> ReplacementEntry? in
            let matches = entry.matches.filter { !ambiguousHeard.contains($0) }
            guard !matches.isEmpty else { return nil }
            return ReplacementEntry(replaceWith: entry.replaceWith, matches: matches)
        }
        let solidHeardKeys = Set(unambiguous.flatMap(\.matches).map(normalize))
        let solidTerms = Set(unambiguous.map(\.replaceWith))
        let phonetic = phoneticCandidates(transcript: transcript, vocabulary: vocabulary)

        // A stronger character hit owns both the local term and the literal
        // span. Keeping a phonetic suggestion beside it would either duplicate
        // the answer or refer to bytes pre-application is about to replace.
        func withoutSolidCollisions(_ entries: [ReplacementEntry]) -> [ReplacementEntry] {
            entries.compactMap { entry in
                guard !solidTerms.contains(entry.replaceWith) else { return nil }
                let matches = entry.matches.filter { !solidHeardKeys.contains(normalize($0)) }
                guard !matches.isEmpty else { return nil }
                return ReplacementEntry(replaceWith: entry.replaceWith, matches: matches)
            }
        }
        var phoneticPreApply = withoutSolidCollisions(phonetic.preApply)
        var phoneticVerification = withoutSolidCollisions(phonetic.verification)

        // The character tiers abstained on these spans because two terms
        // tied. A phonetic guess must not silently rewrite bytes the
        // strongest tier already declared contested — it survives only as a
        // verification choice.
        let contestedKeys = Set(ambiguousHeard.map(normalize))
        if !contestedKeys.isEmpty {
            let contested = phoneticPreApply.filter { entry in
                entry.matches.contains { contestedKeys.contains(normalize($0)) }
            }
            if !contested.isEmpty {
                let contestedTerms = Set(contested.map(\.replaceWith))
                phoneticPreApply.removeAll { contestedTerms.contains($0.replaceWith) }
                phoneticVerification.append(contentsOf: contested)
            }
        }

        // Preserve the old fallback trigger exactly: it is considered only
        // when the solid character tiers approved nothing. Phonetic evidence
        // is guess grade and does not suppress that independent check.
        let aligned = unambiguous.isEmpty
            ? alignedFallbackOutcome(transcript: transcript, vocabulary: vocabulary)
            : (approved: nil, verification: [])
        var fallback = aligned.approved
        var alignedVerification = aligned.verification

        // Two independent guesses assigning different local spellings to the
        // same bytes are not safe to pre-apply. Retain both as verification
        // choices because abstention leaves those bytes intact.
        if let approvedFallback = fallback {
            let fallbackKeys = Set(approvedFallback.matches.map(normalize))
            let samePhoneticEvidence = (phoneticPreApply + phoneticVerification).contains {
                $0.replaceWith == approvedFallback.replaceWith
                    && $0.matches.contains { fallbackKeys.contains(normalize($0)) }
            }
            // The narrower pronunciation tier owns an agreeing span. In
            // particular, a near phonetic key must not be promoted merely
            // because the broader character-alignment fallback also likes it;
            // that would turn a prompt-only confidence grade into a rewrite.
            if samePhoneticEvidence {
                fallback = nil
            }
            let conflicting = phoneticPreApply.filter { entry in
                entry.replaceWith != approvedFallback.replaceWith
                    && entry.matches.contains { fallbackKeys.contains(normalize($0)) }
            }
            if !conflicting.isEmpty {
                let conflictingTerms = Set(conflicting.map(\.replaceWith))
                phoneticPreApply.removeAll { conflictingTerms.contains($0.replaceWith) }
                phoneticVerification.append(contentsOf: conflicting)
                alignedVerification.append(approvedFallback)
                fallback = nil
            }
        }

        // Only a span that normalizes to the term itself rewrites the
        // transcript. Every sound-alike tier — edit distance one, phonetic
        // key, aligned fallback — nominates its term to the model instead:
        // field history (2026-09-18) showed those tiers writing code terms
        // over ordinary prose ("on peut" -> `toolInput`).
        let primaryEntries = unambiguous.filter { exactTerms.contains($0.replaceWith) }
        let demoted = unambiguous.filter { !exactTerms.contains($0.replaceWith) }
            + phoneticPreApply
            + (fallback.map { [$0] } ?? [])

        // Conflict demotion can append formerly-high hits after already-weak
        // hits. Restore the phonetic tier's documented global rank before the
        // combined verification cap is applied.
        phoneticVerification.sort { lhs, rhs in
            let lhsLength = normalize(lhs.replaceWith).count
            let rhsLength = normalize(rhs.replaceWith).count
            if lhsLength != rhsLength { return lhsLength > rhsLength }
            let lhsPosition = lhs.matches.first.flatMap { transcript.range(of: $0) }
                .map { transcript.distance(from: transcript.startIndex, to: $0.lowerBound) }
                ?? Int.max
            let rhsPosition = rhs.matches.first.flatMap { transcript.range(of: $0) }
                .map { transcript.distance(from: transcript.startIndex, to: $0.lowerBound) }
                ?? Int.max
            if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
            if lhs.replaceWith != rhs.replaceWith { return lhs.replaceWith < rhs.replaceWith }
            return (lhs.matches.first ?? "") < (rhs.matches.first ?? "")
        }

        let offerLimit = nominationCap(forTranscript: transcript)
        var verificationCandidates: [ReplacementEntry] = []
        var seenVerification = Set<VerificationKey>()
        for entry in demoted + phoneticVerification + alignedVerification {
            for heard in entry.matches where !addsUnspokenExtension(
                term: entry.replaceWith, heard: heard, transcript: transcript
            ) {
                let key = VerificationKey(heardKey: normalize(heard), term: entry.replaceWith)
                guard seenVerification.insert(key).inserted else { continue }
                verificationCandidates.append(ReplacementEntry(
                    replaceWith: entry.replaceWith,
                    matches: [heard]
                ))
                if verificationCandidates.count == offerLimit { break }
            }
            if verificationCandidates.count == offerLimit { break }
        }

        return GroundingOutcome(
            entries: primaryEntries,
            isFallbackOnly: false,
            phoneticEntries: [],
            verificationCandidates: verificationCandidates
        )
    }

    /// A nominated file name whose extension the speaker never said. Shown to
    /// the model, "local Voxtral" came back as `localvoxtral.js` on every model
    /// tried, so the nomination is withheld rather than left to judgment —
    /// unless the speaker was plainly naming a file ("regarde dictation view
    /// model"), the same cue the aligned fallback already honours.
    package static func addsUnspokenExtension(
        term: String,
        heard: String,
        transcript: String
    ) -> Bool {
        guard let fileExtension = shortFileExtension(in: term) else { return false }
        let spoken = heard.lowercased()
        let spokenWords = tokenize(spoken)
        if spoken.contains(".\(fileExtension)") { return false }
        if spokenWords.last.map(normalize) == fileExtension { return false }
        // "use auth dot t s": the letters arrive as separate words, so look
        // for the extension at the end of everything after a spoken separator.
        if let separator = spokenWords.lastIndex(where: { ["dot", "point"].contains($0) }),
           normalize(spokenWords[(separator + 1)...].joined()) == fileExtension
        {
            return false
        }

        func isCue(_ word: String) -> Bool {
            fileReferenceCues.contains(word.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ))
        }
        if spokenWords.contains(where: isCue) { return false }
        // The matcher may have matched any occurrence of the span; a cue
        // before one of them is enough.
        var searchStart = transcript.startIndex
        while let range = transcript.range(of: heard, range: searchStart..<transcript.endIndex) {
            if tokenize(String(transcript[..<range.lowerBound])).suffix(3).contains(where: isCue) {
                return false
            }
            searchStart = range.upperBound
        }
        return true
    }

    /// Places exact vocabulary bytes into only the literal ASR spans already
    /// selected by the matcher. Longest aliases run first; technical-token
    /// boundaries prevent a short alias from rewriting inside another path or
    /// identifier. Punctuation remains outside the replaced range.
    package static func preapplying(
        entries: [ReplacementEntry],
        to text: String
    ) -> String {
        let mappings = entries.flatMap { entry in
            entry.matches.map { (exact: entry.replaceWith, heard: $0) }
        }.sorted { lhs, rhs in
            if lhs.heard.count != rhs.heard.count {
                return lhs.heard.count > rhs.heard.count
            }
            return lhs.exact.count > rhs.exact.count
        }

        var output = text
        for mapping in mappings {
            guard !mapping.exact.isEmpty, !mapping.heard.isEmpty,
                  sanitizedTerm(mapping.exact) == mapping.exact,
                  sanitizedTerm(mapping.heard) == mapping.heard,
                  mapping.exact != mapping.heard
            else { continue }

            var searchStart = output.startIndex
            while searchStart < output.endIndex,
                  let range = output.range(
                    of: mapping.heard,
                    range: searchStart..<output.endIndex
                  )
            {
                if hasTechnicalBoundaries(in: output, range: range) {
                    output.replaceSubrange(range, with: mapping.exact)
                    break
                }
                searchStart = range.upperBound
            }
        }
        return output
    }

    /// Evaluation-proven fallback for phonetic damage beyond edit distance 1.
    /// It searches only candidates sharing a character n-gram with the ASR
    /// span, requires a strong best score and an unambiguous runner-up margin,
    /// and approves at most one mapping.
    ///
    /// The aligned matcher has one deterministic approval channel and a small
    /// demotion channel for evidence that narrowly misses confidence. Only
    /// score ambiguity, a near score, or an unspoken extension can be useful
    /// to the model; a single glued word inflated far beyond the candidate is
    /// a structural mismatch and remains a hard drop.
    package static func alignedFallbackOutcome(
        transcript: String,
        vocabulary: RepoVocabulary
    ) -> (approved: ReplacementEntry?, verification: [ReplacementEntry]) {
        let tokens = fallbackTokens(in: transcript)
        guard !tokens.isEmpty, !vocabulary.alignedCandidates.isEmpty else {
            return (nil, [])
        }

        var bestByCandidate: [Int: AlignedHit] = [:]
        for start in tokens.indices {
            let maxLength = min(alignedMaxWords, tokens.count - start)
            for length in 1...maxLength {
                let rawRange = tokens[start].lowerBound..<tokens[start + length - 1].upperBound
                let rawSpan = String(transcript[rawRange])
                let heard = rawSpan.trimmingCharacters(in: fallbackEdgeCharacters)
                let normalizedHeard = alignedNormalize(heard)
                // The exact local term must be long; its damaged ASR span may
                // be shorter (the field `uzoft.ts` -> `useAuth.ts` case is 7
                // normalized characters). The score and ambiguity margin do
                // the remaining safety work.
                guard normalizedHeard.count >= minNormalizedLength else { continue }

                let postingLists = characterNGrams(normalizedHeard).compactMap {
                    vocabulary.alignedNGramIndex[$0]
                }.sorted { $0.count < $1.count }
                var candidateIndexes = Set<Int>()
                for postings in postingLists {
                    let additions = postings.filter { !candidateIndexes.contains($0) }
                    guard candidateIndexes.count + additions.count
                            <= alignedMaxCandidatesPerSpan
                    else { continue }
                    candidateIndexes.formUnion(additions)
                }
                guard !candidateIndexes.isEmpty else { continue }

                let heardCharacters = Array(normalizedHeard)
                for candidateIndex in candidateIndexes {
                    let candidate = vocabulary.alignedCandidates[candidateIndex]
                    guard normalizedHeard.count * 2 >= candidate.normalized.count,
                          candidate.normalized.count * 2 >= normalizedHeard.count
                    else { continue }
                    var score = longestCommonSubsequenceRatio(
                        heardCharacters,
                        candidate.normalizedCharacters
                    )
                    if let fileExtension = shortFileExtension(in: candidate.term),
                       heard.lowercased().contains(".\(fileExtension)")
                    {
                        score = min(1, score + 0.1)
                    }
                    let hit = AlignedHit(
                        candidateIndex: candidateIndex,
                        heard: heard,
                        score: score,
                        lengthDelta: abs(normalizedHeard.count - candidate.normalized.count),
                        startWord: start,
                        wordCount: length
                    )
                    if let previous = bestByCandidate[candidateIndex],
                       !alignedHit(hit, isBetterThan: previous)
                    {
                        continue
                    }
                    bestByCandidate[candidateIndex] = hit
                }
            }
        }

        let ranked = bestByCandidate.values.sorted { lhs, rhs in
            if alignedHit(lhs, isBetterThan: rhs) { return true }
            if alignedHit(rhs, isBetterThan: lhs) { return false }
            let lhsTerm = vocabulary.alignedCandidates[lhs.candidateIndex].term
            let rhsTerm = vocabulary.alignedCandidates[rhs.candidateIndex].term
            if lhsTerm != rhsTerm { return lhsTerm < rhsTerm }
            return lhs.candidateIndex < rhs.candidateIndex
        }
        guard let best = ranked.first else { return (nil, []) }
        let bestCandidate = vocabulary.alignedCandidates[best.candidateIndex]
        let runnerUp = ranked.dropFirst().first
        let margin = best.score - (runnerUp?.score ?? 0)

        func entry(for hit: AlignedHit) -> ReplacementEntry {
            ReplacementEntry(
                replaceWith: vocabulary.alignedCandidates[hit.candidateIndex].term,
                matches: [hit.heard]
            )
        }

        func isInflatedSingleWord(_ hit: AlignedHit) -> Bool {
            let candidate = vocabulary.alignedCandidates[hit.candidateIndex]
            let normalizedHeard = alignedNormalize(hit.heard)
            return !hit.heard.contains(where: { $0.isWhitespace })
                && Double(normalizedHeard.count) > Double(candidate.normalized.count) * 1.2
        }

        // This check intentionally precedes every demotion rule. The old
        // matcher rejected this shape outright; exposing it as a suggestion
        // would merely move the unsafe deletion risk into the prompt.
        guard !isInflatedSingleWord(best) else { return (nil, []) }

        if best.score >= alignedMinimumScore, margin < alignedMinimumMargin {
            var verification = [entry(for: best)]
            if let runnerUp,
               runnerUp.score >= alignedMinimumScore,
               !isInflatedSingleWord(runnerUp)
            {
                verification.append(entry(for: runnerUp))
            }
            return (nil, Array(verification.prefix(2)))
        }

        if best.score >= alignedVerificationMinimumScore,
           best.score < alignedMinimumScore,
           margin >= alignedMinimumMargin
        {
            return (nil, [entry(for: best)])
        }

        guard best.score >= alignedMinimumScore,
              margin >= alignedMinimumMargin
        else { return (nil, []) }

        // A filename extension that was not spoken is a semantic choice, not
        // merely a spelling correction. Require a nearby file-oriented verb /
        // noun before deterministic grounding; otherwise leave the exact term
        // as clipboard context for the LLM to interpret. This prevents
        // `fix the user session manager` from becoming a `.swift` filename,
        // while `look at dictation view model` remains eligible.
        if let fileExtension = shortFileExtension(in: bestCandidate.term),
           !best.heard.lowercased().contains(".\(fileExtension)"),
           !hasFileReferenceCue(tokens: tokens, hit: best, transcript: transcript)
        {
            return (nil, [entry(for: best)])
        }
        return (entry(for: best), [])
    }

    // MARK: - Internals

    /// One matched (term, transcript n-gram) pairing.
    private struct Hit {
        package let term: String
        package let normalizedLength: Int
        package let position: Int
        package let spoken: String
        package let exact: Bool
    }

    private struct PhoneticHit {
        package let term: String
        package let normalizedLength: Int
        package let position: Int
        package let spoken: String
        package let exactKey: Bool
    }

    private struct VerificationKey: Hashable {
        package let heardKey: String
        package let term: String
    }

    private struct FallbackToken {
        package let lowerBound: String.Index
        package let upperBound: String.Index
    }

    private struct AlignedHit {
        package let candidateIndex: Int
        package let heard: String
        package let score: Double
        package let lengthDelta: Int
        package let startWord: Int
        package let wordCount: Int
    }

    private static let nonAlphanumericEdges = CharacterSet.alphanumerics.inverted
    private static let fallbackEdgeCharacters = CharacterSet(
        charactersIn: "`'\"“”‘’()[]{}<>.,;:!?"
    )

    /// Splits on whitespace and trims each word of leading/trailing
    /// non-alphanumerics (STT-sprinkled commas/periods) so the normalized form
    /// and the "as spoken" match string are both clean.
    static func tokenize(_ transcript: String) -> [String] {
        transcript
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: nonAlphanumericEdges) }
            .filter { !$0.isEmpty }
    }

    private static func fallbackTokens(in transcript: String) -> [FallbackToken] {
        let regex = try! NSRegularExpression(pattern: #"\S+"#)
        return regex.matches(
            in: transcript,
            range: NSRange(transcript.startIndex..., in: transcript)
        ).compactMap { match in
            guard let range = Range(match.range, in: transcript) else { return nil }
            return FallbackToken(lowerBound: range.lowerBound, upperBound: range.upperBound)
        }
    }

    /// Comparison-only normalization used by the broader fallback. Diacritics
    /// are folded so French ASR remains comparable; the emitted term and heard
    /// span always retain their original bytes.
    package static func alignedNormalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(String.init).joined()
    }

    package static func characterNGrams(_ value: String, width: Int = 2) -> Set<String> {
        let characters = Array(value)
        guard characters.count >= width else { return [] }
        return Set((0...(characters.count - width)).map {
            String(characters[$0..<($0 + width)])
        })
    }

    private static func longestCommonSubsequenceRatio(
        _ lhs: [Character],
        _ rhs: [Character]
    ) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = Array(repeating: 0, count: rhs.count + 1)
        for left in lhs {
            var current = Array(repeating: 0, count: rhs.count + 1)
            for (offset, right) in rhs.enumerated() {
                current[offset + 1] = left == right
                    ? previous[offset] + 1
                    : max(previous[offset + 1], current[offset])
            }
            previous = current
        }
        return Double(2 * previous[rhs.count]) / Double(lhs.count + rhs.count)
    }

    private static func alignedHit(
        _ candidate: AlignedHit,
        isBetterThan existing: AlignedHit
    ) -> Bool {
        if candidate.score != existing.score { return candidate.score > existing.score }
        if candidate.lengthDelta != existing.lengthDelta {
            return candidate.lengthDelta < existing.lengthDelta
        }
        if candidate.wordCount != existing.wordCount {
            return candidate.wordCount < existing.wordCount
        }
        if candidate.startWord != existing.startWord {
            return candidate.startWord < existing.startWord
        }
        return candidate.heard.count < existing.heard.count
    }

    private static func shortFileExtension(in term: String) -> String? {
        let lastComponent = term.split(separator: "/").last.map(String.init) ?? term
        guard let dot = lastComponent.lastIndex(of: ".") else { return nil }
        let suffix = String(lastComponent[lastComponent.index(after: dot)...]).lowercased()
        guard (1...8).contains(suffix.count),
              suffix.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
        else { return nil }
        return suffix
    }

    private static let fileReferenceCues: Set<String> = [
        "open", "ouvre", "ouvrir", "edit", "edite", "édite", "update",
        "look", "regard", "regarde", "corrige", "file", "filename", "fichier",
    ]

    private static func hasFileReferenceCue(
        tokens: [FallbackToken],
        hit: AlignedHit,
        transcript: String
    ) -> Bool {
        let lower = max(0, hit.startWord - 3)
        let upper = min(tokens.count, hit.startWord + hit.wordCount)
        return tokens[lower..<upper].contains { token in
            let value = String(transcript[token.lowerBound..<token.upperBound])
                .trimmingCharacters(in: nonAlphanumericEdges)
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
            return fileReferenceCues.contains(value)
        }
    }

    static func hasTechnicalBoundaries(
        in text: String,
        range: Range<String.Index>
    ) -> Bool {
        if let first = text[range].first, first.isLetter || first.isNumber,
           range.lowerBound > text.startIndex
        {
            let previous = text[text.index(before: range.lowerBound)]
            if previous.isLetter || previous.isNumber || "._/-".contains(previous) {
                return false
            }
        }
        if let last = text[range].last, last.isLetter || last.isNumber,
           range.upperBound < text.endIndex
        {
            let next = text[range.upperBound]
            if next.isLetter || next.isNumber || "_/-".contains(next) {
                return false
            }
        }
        return true
    }

    private static func stripJoiners(_ token: String) -> String {
        token.filter { $0 != "." && $0 != "/" && $0 != "_" && $0 != "-" }
    }

    private static func isCommon(_ word: String) -> Bool {
        let normalized = stripJoiners(word.lowercased())
        return stopwords.contains(normalized) || spokenSeparators.contains(normalized)
    }

    /// Within one term, prefer an exact match over a fuzzy one, then the earlier
    /// transcript position, then the more specific (longer spoken) n-gram.
    private static func isBetter(_ candidate: Hit, than existing: Hit) -> Bool {
        if candidate.exact != existing.exact { return candidate.exact }
        if candidate.position != existing.position { return candidate.position < existing.position }
        return candidate.spoken.count > existing.spoken.count
    }

    /// Within one phonetic term, exact pronunciation outranks a near key, then
    /// the earlier and more specific literal span wins. Final cross-term order
    /// is applied separately after this per-term best-hit reduction.
    private static func phoneticHit(
        _ candidate: PhoneticHit,
        isBetterThan existing: PhoneticHit
    ) -> Bool {
        if candidate.exactKey != existing.exactKey { return candidate.exactKey }
        if candidate.position != existing.position { return candidate.position < existing.position }
        return candidate.spoken.count > existing.spoken.count
    }

    /// Exact equality and character edit distance one already have stronger,
    /// established owners. Checking the bounded distance only when lengths are
    /// within one avoids unnecessary character work.
    private static func characterTierOwns(
        heardNormalized: String,
        candidateNormalized: String
    ) -> Bool {
        if heardNormalized == candidateNormalized { return true }
        guard abs(heardNormalized.count - candidateNormalized.count) <= 1 else { return false }
        return isEditDistanceAtMostOne(
            Array(heardNormalized), Array(candidateNormalized)
        )
    }

    /// Specialized distance-1 check (all the fuzzy tier needs): two-pointer
    /// single pass with early exit — no O(n²) matrix, no per-pair count
    /// recomputation (callers pass precomputed character arrays).
    private static func isEditDistanceAtMostOne(_ a: [Character], _ b: [Character]) -> Bool {
        let lengthDelta = a.count - b.count
        if abs(lengthDelta) > 1 { return false }
        var i = 0
        var j = 0
        var edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                i += 1
                j += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if lengthDelta == 0 {
                i += 1  // substitution
                j += 1
            } else if lengthDelta > 0 {
                i += 1  // deletion from a
            } else {
                j += 1  // insertion into a
            }
        }
        edits += (a.count - i) + (b.count - j)
        return edits <= 1
    }

    // MARK: - Prompt rendering

    /// Defense-in-depth for prompt rendering: `git ls-files -z` preserves
    /// newlines/tabs and other control characters in file names, and a raw
    /// interpolation could break a `- key: aliases` line into stray prompt
    /// lines. Reuses the shared clipboard sanitizer (drops control chars) and
    /// additionally removes the newline/tab it deliberately keeps — a rendered
    /// dictionary line must stay single-line. Double quotes are dropped too:
    /// the verification pairs render both sides inside `"..."`, and a quote
    /// inside a term would close that quoting early and smuggle its own
    /// prose into the instruction line.
    package static func sanitizedTerm(_ term: String) -> String {
        term.sanitizedControlCharacters
            .filter { $0 != "\n" && $0 != "\t" && $0 != "\"" }
            .trimmingCharacters(in: .whitespaces)
    }

    /// A sanitized term is renderable when something meaningful remains: not
    /// empty, and not a bare dash run (`---` would read as a section divider).
    package static func isRenderableTerm(_ term: String) -> Bool {
        !term.isEmpty && !term.allSatisfy { $0 == "-" }
    }

    /// Headers of the vocabulary lists. Each is a short label; what the list
    /// is and how to use it is explained once in the system prompt
    /// (`PolishReferenceGuide`), which the helper keeps cached, instead of on
    /// every request.
    ///
    /// Entries harvested from the focused terminal's git repo.
    package static let repositoryVocabularyHeader = "[Repository vocabulary]"

    /// Entries harvested from the user's clipboard excerpt (the clipboard
    /// polish-context feature): same rendering, honest provenance.
    package static let clipboardVocabularyHeader = "[Clipboard vocabulary]"

    /// Entries harvested from the terminal screen the speaker was looking at.
    /// Used for BOTH the `render` and `vocabularyOnly` reconciliation
    /// outcomes — in the latter the excerpt itself is withheld, but these
    /// entries are still terms the user could see while speaking.
    package static let terminalScreenVocabularyHeader = "[Terminal screen vocabulary]"

    /// Entries harvested from the joined Claude Code session's own state — the
    /// request the speaker previously sent that agent and the files it touched.
    package static let claudeSessionVocabularyHeader = "[Coding agent session vocabulary]"

    /// Entries the app remembers from this project's earlier dictations
    /// (`LearnedTerms`): the speaker has said these words before and something
    /// on their machine spelled them this way at the time.
    package static let learnedVocabularyHeader = "[Learned vocabulary]"

    /// The terms the sound-alike tiers nominated. The matcher only knows that
    /// something in the transcript sounds like one of them; whether the speaker
    /// meant it depends on the sentence, which is the model's call. The heard
    /// span is deliberately NOT rendered: shown as `"heard" -> "term"` pairs,
    /// models applied the pair as an instruction (replay 2026-09-18: five wrong
    /// insertions with pairs, three with this list, none without). The rule for
    /// using them is `PolishReferenceGuide.candidateTerms`, kept word for word;
    /// the label repeats its gist next to the terms, where a small model reads
    /// it, so the list never passes for spellings to apply.
    package static let verificationCandidatesHeader =
        "[Candidate terms: maybe said, use one only where it fits better]"


    /// Renders matched entries as a prompt section mirroring
    /// `ReplacementDictionary.renderedPromptSection`'s `- key: aliases` shape,
    /// under the given header. Every key/alias is sanitized first; an entry
    /// whose key or every alias becomes unrenderable is dropped. Empty entries
    /// render nothing.
    package static func promptSection(
        entries: [ReplacementEntry],
        header: String = repositoryVocabularyHeader
    ) -> String {
        let lines: [String] = entries.compactMap { entry in
            let key = sanitizedTerm(entry.replaceWith)
            guard isRenderableTerm(key) else { return nil }
            let aliases = entry.matches.map(sanitizedTerm).filter(isRenderableTerm)
            guard !aliases.isEmpty else { return nil }
            return "- \(key): \(aliases.joined(separator: ", "))"
        }
        guard !lines.isEmpty else { return "" }
        return "\(header)\n\(lines.joined(separator: "\n"))"
    }

    /// Appends the vocabulary section to an existing replacement-dictionary
    /// prompt string. When the base is empty (dictionary disabled) the section
    /// stands alone; when there are no entries the base is returned unchanged.
    package static func appendedPromptSection(
        base: String,
        entries: [ReplacementEntry],
        header: String = repositoryVocabularyHeader
    ) -> String {
        let section = promptSection(entries: entries, header: header)
        guard !section.isEmpty else { return base }
        guard !base.isEmpty else { return section }
        return base + "\n\n" + section
    }
}
