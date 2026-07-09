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
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var spans: [(range: NSRange, token: String)] = []

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

        // Drop any span strictly contained in a longer span (path swallows its
        // inner filename, URL swallows an inner path, etc.).
        let kept = spans.enumerated().filter { _, span in
            !spans.contains { other in
                !NSEqualRanges(other.range, span.range)
                    && other.range.location <= span.range.location
                    && (span.range.location + span.range.length)
                        <= (other.range.location + other.range.length)
            }
        }

        var seen = Set<String>()
        var result: [String] = []
        for (_, span) in kept.sorted(by: { $0.element.range.location < $1.element.range.location }) {
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
    static func verifyAndRepair(polished: String, original: String) -> Repair {
        let tokens = protectedTokens(in: original)
        guard !tokens.isEmpty else { return Repair(text: polished, outcome: .clean) }

        var working = polished
        var repairedCount = 0
        var missing: [String] = []

        for token in tokens {
            // `max(1, …)` is belt-and-braces: a recognized token always counts
            // at least once in its own source text.
            let required = max(1, standaloneOccurrenceCount(of: token, in: original))
            var surviving = standaloneOccurrenceCount(of: token, in: working)
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
            return Repair(text: original, outcome: .fallback(missing: missing))
        }
        if repairedCount > 0 {
            return Repair(text: working, outcome: .repaired(count: repairedCount))
        }
        return Repair(text: working, outcome: .clean)
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

    private static func isBodyCharacter(_ c: Character) -> Bool {
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
