import Foundation

/// Recognizes code-like tokens in dictated text: CLI flags, paths, URLs,
/// backtick spans, env vars, hashes and version literals. Clipboard
/// vocabulary and the clipboard context reader use it; it does not check or
/// repair polish output (#138 took that out of the commit path).
///
/// Pure functions on `String`, mirroring `TextMergingAlgorithms`. Recognition
/// is deliberately conservative: prefer missing a token over a false positive.
package enum PolishTokenGuard {
    // MARK: - Recognition

    // Static literals: a bad pattern is a coding error we want to crash on
    // immediately (same rationale as TextMergingAlgorithms).
    //
    // LINEAR-TIME DISCIPLINE. Recognition runs over the COMPLETE retained
    // context buffer — up to `PolishContextClipboardReader
    // .retentionCharacterCap` (2M) characters — so a pattern that is quadratic
    // in the length of one unbroken character run is a hang, not merely a slow
    // test. Any recognizer whose greedy character class is followed by a
    // literal that class CANNOT contain has exactly that shape: on a long run
    // the engine consumes the run, fails, backs up one character at a time,
    // fails again, then repeats the whole exercise from the next start
    // position. Measured on the build host over 40k characters of unbroken
    // run: `protectedTokens` cost 20.2s, or 130.8s when the run was
    // hyphen-dense, scaling 4x per doubling. Three fixes apply, and each is either provably
    // output-identical or a documented bound:
    //   * possessive quantifiers (`++`, `{n,m}+`) where the following literal
    //     is outside the class — every position the engine would back up to
    //     holds a class character, so the backtracking cannot succeed and
    //     removing it cannot change a match;
    //   * a lookbehind rejecting start positions INSIDE such a run — a match
    //     starting mid-run is always subsumed by the longer one starting at
    //     the run boundary, which the leftmost rule already prefers, so the
    //     blocked starts never produced output;
    //   * a length bound on the run itself, where the first two still leave
    //     the engine re-scanning from many starts.
    // Past a bound, recognition does not simply stop: the lookbehind and the
    // bound together mean the next VIABLE start inside the run is used, so the
    // token can be a SUFFIX of what the unbounded pattern matched (never a
    // longer or unrelated one). On the shape that actually occurs — a pasted
    // payload glued to a real URL — that suffix is the token worth having.
    // `PolishTokenGuardTests.testRecognitionHoldsAtTheSchemeAndStemBounds` and
    // `.testPastTheBoundsRecognitionFallsBackToASuffixNeverALongerToken` pin
    // both halves; `PolishContextPreparationTests
    // .testPreparationOverAPathologicalRunCostsNoMoreThanOverRealSource` guards
    // the complexity.
    private static let backtickSpan = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    // The scheme is length-bounded because `://` can never appear inside the
    // scheme class: unbounded, every letter of a long alphanumeric blob (a
    // base64 payload, a JWT) starts another full re-scan. RFC 3986 schemes are
    // short — the longest IANA-registered one is under 40 characters — so 64
    // is generous, and a longer "scheme" becoming a miss is the
    // conservative-recognition principle working as intended.
    private static let url = try! NSRegularExpression(
        pattern: "(?<![A-Za-z])[A-Za-z][A-Za-z0-9+.-]{0,63}+://[^\\s]+"
    )
    // A path is an optional leading `/` (absolute paths must protect it — a
    // dropped slash silently turns `/tmp/app.log` relative) plus one or more
    // "segment/" groups and a final segment. Segment chars include `.`, `~`,
    // `-` so `./scripts/foo.sh` and `~/Library/x` match. Inside a URL the
    // `/host/path` sub-span still matches but is dropped by containment.
    // Segments are possessive (`/` is outside the class, so a shorter segment
    // can never find one) and starts inside a segment run are rejected; the
    // OUTER `+` stays greedy, which is what still lets `a/b/` fall back to
    // matching `a/b`.
    private static let path = try! NSRegularExpression(
        pattern: "(?<![\\w.~-])/?(?:[\\w.~-]++/)+[\\w.~-]+"
    )
    // Standalone dotted filename: stem must be 2+ chars holding a letter/
    // underscore (rejects pure numbers like `3.14` and abbreviations `e.g`/
    // `i.e`), ext is 1–8 all-lowercase alphanumerics (rejects `works.Then` —
    // STT output missing the space after a sentence period; the polish
    // legitimately fixes that, and a protected token here would make the
    // guard revert the fix). The extension must additionally sit in
    // `knownFileExtensions` — see that constant's comment. Accepted losses
    // per the conservative-recognition principle: uppercase-ext files
    // (`Makefile.AM`), single-letter stems (`a.txt`) and unlisted extensions
    // go unprotected. The stem is bounded at NAME_MAX (255) — `.` is outside
    // the stem class, so an unbounded stem re-scans the whole run from every
    // word boundary in it, and a stem longer than a filesystem allows is not a
    // filename anyway — and possessive, since a shorter stem always ends on a
    // stem character, never on the required `.`.
    private static let filename = try! NSRegularExpression(
        pattern: "\\b(?=[A-Za-z0-9_-]{0,255}[A-Za-z_])[A-Za-z0-9_-]{2,255}+\\.[a-z0-9]{1,8}\\b"
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
    package static func protectedTokens(in text: String) -> [String] {
        containmentFiltered(spans: collectSpans(in: text))
    }

    /// A recognized span: its range in the source text and the token it yields.
    package typealias ProtectedSpan = (range: NSRange, token: String)

    #if DEBUG
    /// Test seam: the raw recognized spans BEFORE containment filtering, so the
    /// containment sweep can be checked against a naive oracle over identical
    /// input rather than against a re-run of the recognizers.
    package static func debugProtectedSpans(in text: String) -> [ProtectedSpan] {
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

    /// Internal (not private): `ClipboardPayloadMacro` reuses this exact
    /// boundary rule for its standalone placeholder count, so the guard and the
    /// macro can never disagree on what "standalone" means.
    package static func isBodyCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }
}
