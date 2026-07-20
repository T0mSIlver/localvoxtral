import Foundation

/// Deterministic, app-side protection for code-like tokens through LLM
/// polishing. Dictated coding-agent prompts carry CLI flags, paths, URLs,
/// backtick spans, env vars, hashes and version literals; a small polish model
/// can silently mangle exactly those (e.g. `--force` → `– force`, a path
/// case-folded, backticks dropped). This enum recognizes such tokens in the
/// pre-polish text and, after polishing, either confirms each survived
/// byte-exact, repairs a near-miss the model introduced, or (when a token is
/// gone and unrepairable) signals the caller to discard the polish entirely.
///
/// Pure functions on `String`, mirroring `TextMergingAlgorithms`. Recognition
/// is deliberately conservative: prefer missing a token over a false positive
/// that would block legitimate cleanup.
enum PolishTokenGuard {
    struct Repair: Equatable {
        /// The text the caller should commit for `.clean`/`.repaired`. For
        /// `.fallback` it is the untouched `original`, but the caller decides
        /// what to keep by switching on `outcome`.
        let text: String
        let outcome: Outcome
        /// How many protected tokens were accepted as SANCTIONED rewrites (see
        /// `verifyAndRepair(polished:original:sanctionedReplacements:)`) rather
        /// than found verbatim. Callers log this so field logs show when the
        /// repo-vocabulary path changed a protected token on purpose. Defaulted
        /// so every pre-existing construction/comparison stays byte-identical.
        let sanctionedCount: Int

        init(text: String, outcome: Outcome, sanctionedCount: Int = 0) {
            self.text = text
            self.outcome = outcome
            self.sanctionedCount = sanctionedCount
        }

        enum Outcome: Equatable {
            case clean
            case repaired(count: Int)
            case fallback(missing: [String])
        }
    }

    // MARK: - Recognition

    // Static literals: a bad pattern is a coding error we want to crash on
    // immediately (same rationale as TextMergingAlgorithms).
    private static let backtickSpan = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let url = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9+.-]*://[^\\s]+")
    // A path is an optional leading `/` (absolute paths must protect it — a
    // dropped slash silently turns `/tmp/app.log` relative) plus one or more
    // "segment/" groups and a final segment. Segment chars include `.`, `~`,
    // `-` so `./scripts/foo.sh` and `~/Library/x` match. Inside a URL the
    // `/host/path` sub-span still matches but is dropped by containment.
    private static let path = try! NSRegularExpression(pattern: "/?(?:[\\w.~-]+/)+[\\w.~-]+")
    // Standalone dotted filename: stem must be 2+ chars holding a letter/
    // underscore (rejects pure numbers like `3.14` and abbreviations `e.g`/
    // `i.e`), ext is 1–8 all-lowercase alphanumerics (rejects `works.Then` —
    // STT output missing the space after a sentence period; the polish
    // legitimately fixes that, and a protected token here would make the
    // guard revert the fix). The extension must additionally sit in
    // `knownFileExtensions` — see that constant's comment. Accepted losses
    // per the conservative-recognition principle: uppercase-ext files
    // (`Makefile.AM`), single-letter stems (`a.txt`) and unlisted extensions
    // go unprotected.
    private static let filename = try! NSRegularExpression(
        pattern: "\\b(?=[A-Za-z0-9_-]*[A-Za-z_])[A-Za-z0-9_-]{2,}\\.[a-z0-9]{1,8}\\b"
    )
    // Conservative allowlist of real file extensions for the standalone
    // dotted-filename recognizer. Lowercase STT glue like "works.then" /
    // "dr.smith" / "st.louis" fits the stem.ext shape; without this gate the
    // guard "protects" it and the repair path re-glues the polish's correct
    // "works. Then" back into "works.then". Slash paths (`src/foo.xyz`) are
    // recognized by `path` and are NOT gated on this list.
    private static let knownFileExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "json", "md", "txt", "log", "sh",
        "py", "rb", "go", "rs", "c", "h", "cpp", "hpp", "m", "mm",
        "yml", "yaml", "toml", "xml", "html", "css", "plist", "entitlements",
        "xcconfig", "lock", "csv", "sql", "env", "resolved", "cfg", "ini",
        "conf", "png", "svg", "pdf", "proto", "java", "kt", "php", "gradle",
        "zsh", "bash", "ipynb",
    ]
    // Flags: whitespace/start-preceded; group 1 is the flag itself. Double dash
    // takes an optional =value; single dash is exactly one alphanumeric (so
    // hyphenated prose like "well-known" is never captured).
    private static let flag = try! NSRegularExpression(
        pattern: "(?:^|\\s)(--[A-Za-z][A-Za-z0-9-]*(?:=\\S+)?|-[A-Za-z0-9])(?![\\w-])"
    )
    private static let envVar = try! NSRegularExpression(pattern: "\\$[A-Z_][A-Z0-9_]+\\b")
    // Standalone lowercase-hex run, 7–40 chars. Post-filtered to require at
    // least one digit — a conservative refinement over a bare [0-9a-f]{7,40}
    // that would flag all-letter English words like "acceded"/"defaced".
    private static let hexHash = try! NSRegularExpression(pattern: "\\b[0-9a-f]{7,40}\\b")
    // Version literal: `v` prefix needs 2+ components, bare needs 3+ (so prose
    // "2.5" is not captured but "1.2.3" and "v2.5" are).
    private static let version = try! NSRegularExpression(
        pattern: "\\bv\\d+(?:\\.\\d+)+\\b|\\b\\d+\\.\\d+(?:\\.\\d+)+\\b"
    )

    /// Trailing sentence punctuation trimmed off URL/path/filename matches so a
    /// dictated "…in src/foo.ts." protects `src/foo.ts`, not `src/foo.ts.`.
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")"]

    /// Ordered, de-duplicated protected tokens found in `text`. Ordering is by
    /// first appearance; tokens whose span is fully contained in a longer
    /// token's span (e.g. a filename inside a path) are dropped.
    static func protectedTokens(in text: String) -> [String] {
        containmentFiltered(spans: collectSpans(in: text))
    }

    /// A recognized span: its range in the source text and the token it yields.
    typealias ProtectedSpan = (range: NSRange, token: String)

    #if DEBUG
    /// Test seam: the raw recognized spans BEFORE containment filtering, so the
    /// containment sweep can be checked against a naive oracle over identical
    /// input rather than against a re-run of the recognizers.
    static func debugProtectedSpans(in text: String) -> [ProtectedSpan] {
        collectSpans(in: text)
    }
    #endif

    /// Every span each recognizer finds, in recognizer order — overlaps and all.
    private static func collectSpans(in text: String) -> [ProtectedSpan] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var spans: [ProtectedSpan] = []

        func collect(_ regex: NSRegularExpression, captureGroup: Int = 0, trimTrailing: Bool = false,
                     filter: (String) -> Bool = { _ in true }) {
            for match in regex.matches(in: text, range: full) {
                let range = match.range(at: captureGroup)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                var token = ns.substring(with: range)
                var effectiveRange = range
                if trimTrailing {
                    var trimmed = 0
                    while let last = token.last, trailingPunctuation.contains(last) {
                        token.removeLast()
                        trimmed += 1
                    }
                    effectiveRange = NSRange(location: range.location, length: range.length - trimmed)
                }
                guard !token.isEmpty, filter(token) else { continue }
                spans.append((effectiveRange, token))
            }
        }

        collect(backtickSpan)
        collect(url, trimTrailing: true)
        collect(path, trimTrailing: true)
        collect(filename, trimTrailing: true, filter: { token in
            guard let dotIndex = token.lastIndex(of: ".") else { return false }
            return knownFileExtensions.contains(String(token[token.index(after: dotIndex)...]))
        })
        // trimTrailing only ever bites the `=value` tail (`--mode=fast.` at
        // sentence end): the flag charset itself excludes punctuation.
        collect(flag, captureGroup: 1, trimTrailing: true)
        collect(envVar)
        collect(hexHash, filter: { $0.contains(where: { $0.isNumber }) })
        collect(version)
        return spans
    }

    /// Drops any span contained in another, then de-duplicates by token in
    /// first-appearance order.
    private static func containmentFiltered(spans: [ProtectedSpan]) -> [String] {
        // Drop any span strictly contained in a longer span (path swallows its
        // inner filename, URL swallows an inner path, etc.).
        //
        // Linear sweep after a sort, NOT the naive all-pairs scan this replaced:
        // clipboard context now retains up to
        // `PolishContextClipboardReader.retentionCharacterCap` characters, and a
        // code-heavy buffer that size yields tens of thousands of spans, where
        // O(n²) containment is the difference between milliseconds and minutes.
        // Same result, sorted order instead of pairwise comparison.
        //
        // Why one left-to-right pass suffices: sort by location ascending, then
        // length DESCENDING. A span S can only be contained by some O with
        // `O.location <= S.location` and `O.end >= S.end`. Any such O either
        // starts earlier (sorted before S), or starts at the same location with
        // `O.length >= S.length` (also sorted before S, by the length tiebreak).
        // So every possible container precedes S, and tracking the maximum end
        // seen so far answers containment in O(1) per span.
        let sorted = spans.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.range.length > rhs.range.length
        }

        // Identical ranges never drop each other (the all-pairs version excluded
        // them via `!NSEqualRanges`), and the sort makes them adjacent. So they
        // are handled as a GROUP: every member is tested against the maximum end
        // of strictly-earlier groups only, and the group's own end is folded in
        // afterwards. Two spans sharing a range therefore survive or fall
        // together, exactly as before.
        var kept: [(range: NSRange, token: String)] = []
        var maxEndBeforeGroup = Int.min
        var index = 0
        while index < sorted.count {
            var groupEnd = index
            while groupEnd + 1 < sorted.count,
                  NSEqualRanges(sorted[groupEnd + 1].range, sorted[index].range)
            {
                groupEnd += 1
            }
            let span = sorted[index]
            let end = span.range.location + span.range.length
            if maxEndBeforeGroup < end {
                for member in sorted[index...groupEnd] { kept.append(member) }
            }
            maxEndBeforeGroup = max(maxEndBeforeGroup, end)
            index = groupEnd + 1
        }

        var seen = Set<String>()
        var result: [String] = []
        for span in kept {
            if seen.insert(span.token).inserted {
                result.append(span.token)
            }
        }
        return result
    }

    // MARK: - Verify & repair

    /// Confirms every protected token of `original` survived into `polished`,
    /// repairing near-misses in place. Verification is per-occurrence: a token
    /// dictated twice must survive (or be repaired) twice — recognition dedup
    /// must not let one intact occurrence vouch for a mangled duplicate
    /// (`run --force first, then – force again`). If any occurrence is neither
    /// present nor repairable, returns `.fallback` and the caller keeps its
    /// pre-polish text.
    ///
    /// `sanctionedReplacements` teaches the guard about rewrites the CALLER
    /// requested from the model (repo vocabulary: the prompt asks it to fix a
    /// misheard `useauth.ts` to the repo's exact `useAuth.ts`). Without this,
    /// the guard protects the STT's WRONG filename-shaped token and its
    /// near-miss repair deterministically REVERTS the very correction the
    /// vocabulary injected (or, for a fuzzy fix the canonical form can't
    /// bridge, discards the whole polish). A protected token missing from
    /// `polished` is treated as preserved — no repair, no fallback — when it
    /// canonically equals a pair's `from` AND that pair's `to` occurs
    /// standalone in `polished`. Comparison is the guard's own `canonical`
    /// form (case-insensitive, dash/space-normalized) so the guard stays
    /// self-contained. The default `[]` keeps all pre-existing behavior
    /// byte-identical.
    static func verifyAndRepair(
        polished: String,
        original: String,
        sanctionedReplacements: [(from: String, to: String)] = []
    ) -> Repair {
        let tokens = protectedTokens(in: original)
        guard !tokens.isEmpty else { return Repair(text: polished, outcome: .clean) }

        var working = polished
        var repairedCount = 0
        var sanctionedCount = 0
        var missing: [String] = []

        for token in tokens {
            // `max(1, …)` is belt-and-braces: a recognized token always counts
            // at least once in its own source text.
            let required = max(1, standaloneOccurrenceCount(of: token, in: original))
            var surviving = standaloneOccurrenceCount(of: token, in: working)
            // Sanctioned rewrites are consulted BEFORE near-miss repair: the
            // repair path is exactly what would revert a case-only vocabulary
            // correction back to the misheard spelling. A sanctioned token is
            // treated as preserved for ALL its occurrences (the caller asked
            // the model to rewrite it wherever it appears).
            if surviving < required,
                isSanctionedRewrite(
                    of: token, in: working, sanctionedReplacements: sanctionedReplacements
                )
            {
                sanctionedCount += 1
                continue
            }
            while surviving < required {
                guard let repaired = repairFirstNearMiss(of: token, in: working) else {
                    missing.append(token)
                    break
                }
                working = repaired
                repairedCount += 1
                let recounted = standaloneOccurrenceCount(of: token, in: working)
                // Defensive: a repair that fails to add a standalone
                // occurrence would loop forever — treat it as unrepairable.
                guard recounted > surviving else {
                    missing.append(token)
                    break
                }
                surviving = recounted
            }
        }

        if !missing.isEmpty {
            return Repair(
                text: original,
                outcome: .fallback(missing: missing),
                sanctionedCount: sanctionedCount
            )
        }
        if repairedCount > 0 {
            return Repair(
                text: working,
                outcome: .repaired(count: repairedCount),
                sanctionedCount: sanctionedCount
            )
        }
        return Repair(text: working, outcome: .clean, sanctionedCount: sanctionedCount)
    }

    /// True when `token` matches a sanctioned pair's `from` (canonical-form
    /// CONTAINMENT: case-insensitive, dash/space-normalized) and that pair's
    /// `to` occurs standalone in `text` — i.e. the model applied a rewrite the
    /// caller explicitly asked for, so the token counts as preserved.
    ///
    /// Containment, not equality (field regression, 2026-07-11): a sanctioned
    /// alias is often a multi-word transcript gram whose TAIL is itself the
    /// protected token — "user session manager.swift" containing protected
    /// `manager.swift`, corrected to `UserSessionManager.swift`. Under
    /// equality the guard token canonically equals no alias, so the very
    /// correction the caller requested was reverted (or the whole polish
    /// discarded). When the alias gram subsumes the protected token's
    /// occurrence and the model produced the requested `to`, the token's
    /// disappearance is explained and sanctioned.
    ///
    /// Deletion-masking limitation (accepted): there is no occurrence counting
    /// here — a sanctioned `to` present ANYWHERE in the polished text lets an
    /// outright deletion of the `from` occurrence pass without fallback (e.g.
    /// the token was spoken twice and the model kept the corrected form once).
    private static func isSanctionedRewrite(
        of token: String,
        in text: String,
        sanctionedReplacements: [(from: String, to: String)]
    ) -> Bool {
        guard !sanctionedReplacements.isEmpty else { return false }
        let canonicalToken = canonical(token)
        guard !canonicalToken.isEmpty else { return false }
        for (from, to) in sanctionedReplacements {
            guard canonical(from).contains(canonicalToken) else { continue }
            if standaloneOccurrenceCount(of: to, in: text) > 0 { return true }
        }
        return false
    }

    /// Canonical form for near-miss comparison: lowercase, dash variants unified
    /// (en/em dash → `--`, Unicode hyphens → `-`), and inserted whitespace
    /// removed. This is what makes a case-folded path, an en-dash-mangled
    /// `--force`, or a `-- force` with an inserted space compare equal to the
    /// exact token.
    private static func canonical(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\u{2014}", with: "--") // em dash
            .replacingOccurrences(of: "\u{2013}", with: "--") // en dash
            .replacingOccurrences(of: "\u{2012}", with: "-")  // figure dash
            .replacingOccurrences(of: "\u{2010}", with: "-")  // hyphen
            .replacingOccurrences(of: "\u{2011}", with: "-")  // non-breaking hyphen
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")   // narrow no-break space
            .replacingOccurrences(of: "\u{00A0}", with: "")   // no-break space
    }

    /// Number of non-overlapping standalone occurrences of `token` in `text`:
    /// no letter/digit/`_`/`-` glued to either side. An occurrence with a body
    /// char appended or prepended is a corruption (`--force` inside
    /// `--forceful`, `src/App.ts` inside `src/App.tsx`), not a survival.
    /// Sentence punctuation is not a body char, so "src/App.ts." still counts.
    private static func standaloneOccurrenceCount(of token: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: token, range: searchRange) {
            let standaloneBefore = found.lowerBound == text.startIndex
                || !isBodyCharacter(text[text.index(before: found.lowerBound)])
            let standaloneAfter = found.upperBound == text.endIndex
                || !isBodyCharacter(text[found.upperBound])
            if standaloneBefore && standaloneAfter {
                count += 1
                searchRange = found.upperBound..<text.endIndex
            } else {
                guard found.lowerBound < text.endIndex else { break }
                searchRange = text.index(after: found.lowerBound)..<text.endIndex
            }
        }
        return count
    }

    /// Internal (not private): `ClipboardPayloadMacro` reuses this exact
    /// boundary rule for its standalone placeholder count, so the guard and the
    /// macro can never disagree on what "standalone" means.
    static func isBodyCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }

    /// Locates the leftmost, shortest substring of `text` whose canonical form
    /// equals the token's and replaces it with the exact `token`. Window
    /// endpoints must be non-space so a boundary space is never eaten (which
    /// would merge the token into an adjacent word), and the window must be
    /// standalone (no body char glued to either side) so a token embedded in a
    /// longer word (`–forceful`) is never "repaired" into another corruption.
    /// Returns nil if no near-miss exists.
    private static func repairFirstNearMiss(of token: String, in text: String) -> String? {
        let target = canonical(token)
        guard !target.isEmpty else { return nil }

        let chars = Array(text)
        let n = chars.count
        // Slack past the token length covers whitespace the model inserted.
        let maxWindow = token.count + 8

        for start in 0..<n where !isSkippableSpace(chars[start]) {
            // A body char glued before the window means this start is the tail
            // of a longer word — never a standalone repair site.
            if start > 0, isBodyCharacter(chars[start - 1]) { continue }
            let hi = min(n, start + maxWindow)
            var end = start + 1
            while end <= hi {
                if isSkippableSpace(chars[end - 1]) {
                    end += 1
                    continue
                }
                let window = String(chars[start..<end])
                let canon = canonical(window)
                if canon == target {
                    // A body char right after the window is appended-char
                    // corruption; growing the window past it can only
                    // overshoot the target, so give up on this start.
                    if end < n, isBodyCharacter(chars[end]) { break }
                    // An exact occurrence is not a near-miss: skip past it and
                    // keep scanning — with per-occurrence verification an
                    // intact first occurrence must not block the repair of a
                    // mangled duplicate later in the text.
                    if window == token { break }
                    var result = chars
                    result.replaceSubrange(start..<end, with: Array(token))
                    return String(result)
                }
                // canonical length is non-decreasing as the window grows, so
                // once it overshoots the target there is no match past here.
                if canon.count > target.count { break }
                end += 1
            }
        }
        return nil
    }

    private static func isSkippableSpace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\u{202F}" || c == "\u{00A0}"
    }
}
