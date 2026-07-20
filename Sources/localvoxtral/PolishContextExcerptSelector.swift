import Foundation

/// Chooses WHICH lines of a context source render into the polish request when
/// the source is larger than the characters the budget granted it.
///
/// The old clipboard behavior was `prefix(2000)` — head-of-buffer, transcript-
/// blind. Copying a 40-line stack trace and dictating about the frame at the
/// bottom therefore attached 2000 characters of the wrong lines. This selector
/// keeps the lines that the transcript is actually talking about.
///
/// Pure and deterministic: same lines + same transcript + same cap ⇒ same
/// output, byte for byte. No I/O, no clock, no randomness, no dictionary
/// iteration order in any decision.
enum PolishContextExcerptSelector {
    /// Stands in for the lines dropped between two kept, non-adjacent lines, so
    /// the model cannot read a selection as contiguous text and infer a
    /// relationship (or a call order) that the source never had.
    static let elisionMarker = "[…]"

    /// Elision markers are NOT capped by count, deliberately.
    ///
    /// An earlier version stopped emitting them after a fixed number, which
    /// meant a long alternating selection silently rendered non-adjacent lines
    /// as contiguous — the excerpt asserting an adjacency the source never had,
    /// which is exactly what the marker exists to prevent. Faithfulness cannot
    /// be rationed: every gap is marked, or the excerpt lies.
    ///
    /// They stay bounded anyway, by the thing that already bounds everything
    /// here: markers consume characters from `characterCap` like any other
    /// content, so an excerpt full of gaps simply fits fewer lines. The budget
    /// does the limiting; the renderer does not have to.

    /// Upper bound on lines examined.
    ///
    /// Sized against the RETENTION cap, not guessed: a 2M-character paste is
    /// ~30k lines of real source, and a head-only `prefix(2000)` over that
    /// would reintroduce precisely the head-blindness this type exists to fix —
    /// the tail of a large copied log or diff, which is the feature's headline
    /// use case.
    ///
    /// Affordable because scoring a line is now a few linear scans, not nine
    /// `NSRegularExpression` passes — see `score(line:against:)`.
    static let maxConsideredLines = 50_000

    /// A line's score is dominated by the exact technical terms it shares with
    /// the transcript — those are the spellings this whole feature exists to
    /// ground. Loose word overlap only breaks ties among lines that carry no
    /// shared term.
    private static let entityMatchWeight = 8
    private static let wordOverlapWeight = 1

    /// The excerpt for `text` under `characterCap`.
    ///
    /// When the whole text fits, it is returned VERBATIM — no line filtering,
    /// no trimming, no markers. The common case (a short copied filename or
    /// error line) must reach the model exactly as the user copied it; the
    /// selection machinery below only earns its keep when something has to be
    /// left out.
    /// `groundingTerms` are the exact terms the whole-buffer matcher ALREADY
    /// found relevant to this transcript (`GroundingOutcome.entries`'
    /// `replaceWith` values). Passing them in is what lets scoring skip the
    /// recognizer entirely: the expensive extraction has happened once over the
    /// buffer, so a line only has to be checked for containment of a handful of
    /// known strings. Omit them and scoring degrades to word overlap.
    static func select(
        text: String,
        transcript: String,
        characterCap: Int,
        groundingTerms: [String] = []
    ) -> String {
        guard characterCap > 0 else { return "" }
        if text.count <= characterCap { return text }
        return select(
            lines: text.components(separatedBy: "\n"),
            transcript: transcript,
            characterCap: characterCap,
            groundingTerms: groundingTerms
        )
    }

    /// The excerpt for `lines` under `characterCap`, never exceeding the cap.
    ///
    /// Lines are sanitized and right-trimmed; blank padding is discarded. Each
    /// surviving line is scored against the transcript, the highest scoring are
    /// kept greedily, and the kept lines are rendered in SOURCE ORDER (a
    /// relevance-ordered excerpt would misrepresent the source) with elision
    /// markers standing in for the gaps.
    ///
    /// A line too long to fit is SKIPPED, not truncated and not treated as a
    /// stopping condition: one 5000-character minified line must not starve the
    /// ten relevant lines under it. With no transcript match anywhere, the
    /// fallback is deterministic head-of-source order — the old behavior,
    /// line-aligned.
    static func select(
        lines: [String],
        transcript: String,
        characterCap: Int,
        groundingTerms: [String] = []
    ) -> String {
        guard characterCap > 0 else { return "" }

        let candidates = self.candidates(from: lines)
        guard !candidates.isEmpty else { return "" }

        let transcriptSignal = TranscriptSignal(
            transcript: transcript,
            groundingTerms: groundingTerms
        )
        var scored: [ScoredLine] = []
        scored.reserveCapacity(candidates.count)
        for (offset, candidate) in candidates.enumerated() {
            // Cheap cancellation check between lines. A 50k-line buffer is the
            // one input where this loop is long enough to be worth abandoning,
            // and `select` is called from an async context that can be
            // cancelled when the user starts a new dictation. Checked per
            // batch, not per line: `isCancelled` is an atomic load, cheap but
            // not free, and 1024 lines is a few milliseconds of work.
            if offset & 0x3FF == 0, Task.isCancelled { return "" }
            scored.append(ScoredLine(
                index: candidate.index,
                text: candidate.text,
                score: score(line: candidate.text, against: transcriptSignal)
            ))
        }

        // Highest score first; source order breaks ties. With every score at
        // zero (no transcript match at all) this degrades exactly to
        // head-of-source order — the deterministic fallback.
        let ranked = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }

        var kept: [ScoredLine] = []
        var used = 0
        for line in ranked {
            let cost = line.text.count + (kept.isEmpty ? 0 : 1)  // + joining newline
            // Skip and keep going — never break. A line that does not fit says
            // nothing about whether the NEXT (shorter, lower-ranked) one does.
            guard used + cost <= characterCap else { continue }
            kept.append(line)
            used += cost
        }
        // A clipboard can legitimately be one enormous line (minified JSON,
        // SQL, or a compact log record). Skipping oversized lines is useful
        // while shorter alternatives exist, but returning no context when
        // every candidate is oversized is a regression from the old bounded
        // prefix behavior. Matching still uses the complete retained source;
        // this fallback only guarantees that the raw-context allocation is
        // not silently wasted.
        guard !kept.isEmpty else {
            guard let best = ranked.first else { return "" }
            // Truncation is the one place the excerpt cannot be faithful, so it
            // must SAY so: an unmarked cut reads as a complete line, and the
            // model would take a severed identifier for the real spelling. The
            // marker is appended (the head of an oversized line is what a reader
            // needs) and is paid for out of the cap, not added to it.
            let room = characterCap - elisionMarker.count
            guard room > 0 else { return String(best.text.prefix(characterCap)) }
            return String(best.text.prefix(room)) + elisionMarker
        }

        // Markers are added after selection, so they can push the render over
        // the cap. Drop the least valuable kept line (lowest score, then latest
        // in the source) until it fits. Terminates because each pass removes a
        // line — NOT because the render shrinks monotonically: dropping a
        // middle line can open a gap and cost a marker that is longer than the
        // line removed.
        var rendered = render(kept: kept, allowMarkers: true)
        while rendered.count > characterCap, kept.count > 1 {
            let victim = kept.indices.max { lhs, rhs in
                if kept[lhs].score != kept[rhs].score { return kept[lhs].score > kept[rhs].score }
                return kept[lhs].index < kept[rhs].index
            }
            guard let victim else { break }
            kept.remove(at: victim)
            rendered = render(kept: kept, allowMarkers: true)
        }

        // One line left and still over: the overflow is the LEADING marker, not
        // the content (greedy already proved the line itself fits). Drop the
        // marker rather than the tail of the line — truncating would cut the
        // trailing characters, which is exactly where a filename's extension
        // lives, i.e. the reason the line scored at all. With a single line
        // there is no contiguity for a marker to disambiguate anyway.
        if rendered.count > characterCap, kept.count == 1 {
            rendered = render(kept: kept, allowMarkers: false)
        }

        // Belt and braces: the cap is a hard contract the budget relies on, and
        // no arithmetic above may be trusted over the actual string.
        if rendered.count > characterCap {
            rendered = String(rendered.prefix(characterCap))
        }
        return rendered
    }

    // MARK: - Candidates

    private struct Candidate {
        let index: Int
        let text: String
    }

    private struct ScoredLine {
        let index: Int
        let text: String
        let score: Int
    }

    /// Sanitized, right-trimmed, non-blank lines with their ORIGINAL positions
    /// kept (gap detection and source ordering both depend on them).
    ///
    /// Right-trim only: leading whitespace is indentation, which is real
    /// signal for a copied code snippet. Blank lines are padding — they buy
    /// nothing at the model and cost characters the budget could spend on
    /// content.
    private static func candidates(from lines: [String]) -> [Candidate] {
        var result: [Candidate] = []
        for (index, line) in lines.prefix(maxConsideredLines).enumerated() {
            // See the scoring loop: batched cancellation check, same rationale.
            if index & 0x3FF == 0, Task.isCancelled { return [] }
            // Reuse the clipboard sanitizer (drops control scalars), then also
            // drop the newline/tab it deliberately keeps: a rendered context
            // line must stay one line, and an embedded newline would let copied
            // text forge extra lines inside the excerpt.
            let sanitized = PolishContextClipboardReader
                .sanitizeControlCharacters(line)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            let trimmed = rightTrimmed(sanitized)
            guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            result.append(Candidate(index: index, text: trimmed))
        }
        return result
    }

    private static func rightTrimmed(_ line: String) -> String {
        var characters = Array(line)
        while let last = characters.last, last.isWhitespace {
            characters.removeLast()
        }
        return String(characters)
    }

    // MARK: - Scoring

    /// The transcript reduced to the two forms a line is compared against: the
    /// fully normalized string (spoken separators folded away, so "use auth dot
    /// t s" matches `useAuth.ts`) and its lowercased word set.
    private struct TranscriptSignal {
        let words: Set<String>
        /// Terms already proven transcript-relevant by the whole-buffer
        /// matcher, deduped and non-trivial. Literal first, normalized as the
        /// fallback for a source whose rendering differs from the matcher's.
        let terms: [(literal: String, normalized: String)]

        init(transcript: String, groundingTerms: [String]) {
            words = Set(
                transcript
                    .lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map(String.init)
                    .filter { $0.count >= 3 }
            )
            var seen = Set<String>()
            terms = groundingTerms.compactMap { term in
                guard !term.isEmpty, seen.insert(term).inserted else { return nil }
                let normalized = RepoVocabularyMatcher.normalize(term)
                guard normalized.count >= 4 else { return nil }
                return (literal: term, normalized: normalized)
            }
        }
    }

    /// Scores one line WITHOUT running the technical-entity recognizer.
    ///
    /// This used to call `ClipboardVocabulary.entities(inExcerpt:)` per line —
    /// nine `NSRegularExpression` passes over every one of up to
    /// `maxConsideredLines` lines, re-deriving from scratch what
    /// `ClipboardVocabulary.candidateOutcome` had already extracted from the
    /// whole buffer moments earlier. On a 2M-character, 50k-line paste that is
    /// ~450k regex executions to answer a question already answered once.
    ///
    /// The terms in `signal` ARE that answer: they are exact strings taken from
    /// this very buffer and already matched against this transcript. So the
    /// primary signal reduces to literal containment — no recognizer, no
    /// per-line allocation on the hot path. The normalized form is a fallback
    /// for sources whose lines are not byte-identical to the matcher's terms.
    private static func score(line: String, against signal: TranscriptSignal) -> Int {
        var score = 0

        if !signal.terms.isEmpty {
            var normalizedLine: String? = nil
            for term in signal.terms {
                if line.contains(term.literal) {
                    score += entityMatchWeight
                    continue
                }
                // Only pay for normalization if a literal check missed, and only
                // once per line however many terms remain.
                if normalizedLine == nil {
                    normalizedLine = RepoVocabularyMatcher.normalize(line)
                }
                if normalizedLine?.contains(term.normalized) == true {
                    score += entityMatchWeight
                }
            }
        }

        // Tie-breaking signal: ordinary word overlap. Distinct words only, so a
        // line cannot climb by repeating one word.
        var counted = Set<String>()
        for word in line.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let value = String(word)
            guard value.count >= 3, counted.insert(value).inserted else { continue }
            if signal.words.contains(value) { score += wordOverlapWeight }
        }

        return score
    }

    // MARK: - Rendering

    /// Kept lines in SOURCE order, with a bounded elision marker wherever the
    /// original had lines in between, and a leading marker when the excerpt
    /// starts below the first line — the model should know it is reading a
    /// selection that began mid-source. No trailing marker: the excerpt ending
    /// early misleads no one about what the kept lines mean.
    private static func render(kept: [ScoredLine], allowMarkers: Bool) -> String {
        let ordered = kept.sorted { $0.index < $1.index }
        var lines: [String] = []
        var previousIndex: Int? = nil
        for line in ordered {
            let gap: Bool
            if let previous = previousIndex {
                gap = line.index > previous + 1
            } else {
                gap = line.index > 0
            }
            if gap, allowMarkers {
                lines.append(elisionMarker)
            }
            lines.append(line.text)
            previousIndex = line.index
        }
        return lines.joined(separator: "\n")
    }
}
