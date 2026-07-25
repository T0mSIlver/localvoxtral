import ApplicationServices
import Darwin
import Foundation
import Synchronization

// Repo vocabulary: when the dictation target is a terminal sitting in a git
// repo, harvest file names / path components / the branch name from that repo
// and inject the transcript-relevant ones into the polish prompt's replacement-
// dictionary section, so the polish model spells `useAuth.ts` /
// `UserSessionManager.swift` exactly instead of hallucinating. Opt-in, loopback
// endpoints only (repo file names must not ride to a remote endpoint), and
// high-confidence mappings are also applied to the pre-polish working text so
// exact local bytes do not depend on a generative model reproducing them.
// Three separable,
// independently testable pieces + a TTL cache do the amortizing:
//   1. `TerminalWorkingDirectoryResolver` / `TerminalDescendantProcessResolver`
//      — focused title first, then an unambiguous descendant-process cwd
//   2. `RepoIndexing` / `RepoGitRunner` / `RepoVocabularyService` — cwd -> vocab
//   3. `RepoVocabularyMatcher` — transcript + vocab -> replacement entries

// MARK: - 1. Terminal cwd resolution

/// Extracts a working directory from a terminal emulator's window title, then
/// (via the AX seam) reads that title for the app owning the dictation-commit
/// PID. The title parser is a PURE function so it is table-testable without AX;
/// only `windowTitle(forApplicationPID:)` touches live AX and is `@MainActor`.
enum TerminalWorkingDirectoryResolver {
    /// Path-like segments extracted from a terminal window title, in order of
    /// appearance, tilde-expanded. Only `/`- or `~`-prefixed segments count: a
    /// bare last-path-component (Terminal.app's "proj — zsh — 80×24") is NOT
    /// resolvable, so bare names are ignored. Trailing decorations (" — zsh",
    /// " - vim", box-dimension suffixes, sentence punctuation) are trimmed.
    /// `homeDirectory` is injected (default `NSHomeDirectory()`) for testability.
    static func workingDirectoryCandidates(
        fromWindowTitle title: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> [String] {
        // A run starting at `~` or `/` and continuing over non-whitespace. Box
        // dimensions ("80×24"), shell/editor decorations (" — zsh") and bare
        // window names never start with `~`/`/`, so they never match.
        let matches = pathRunRegex.matches(
            in: title,
            range: NSRange(title.startIndex..., in: title)
        )
        var result: [String] = []
        var seen = Set<String>()
        for match in matches {
            guard let range = Range(match.range, in: title) else { continue }
            let trimmed = trimDecorations(String(title[range]))
            guard trimmed.first == "~" || trimmed.first == "/" else { continue }
            // A lone "~" resolves to home; a lone "/" is just the root separator
            // (never a meaningful cwd), so require length >= 2 otherwise.
            guard trimmed == "~" || trimmed.count >= 2 else { continue }
            let expanded = expandTilde(trimmed, homeDirectory: homeDirectory)
            if seen.insert(expanded).inserted {
                result.append(expanded)
            }
        }
        return result
    }

    /// Home-anchored fallback candidates for ABBREVIATED titles, in order of
    /// appearance. Ghostty elides leading path components in tab titles as
    /// `..` ("../Desktop/projects/proj" for `$HOME/Desktop/projects/proj`),
    /// which is never statable as-is — its only meaningful resolution is
    /// re-anchoring at home (field, 2026-07-11: the whole vocabulary feature
    /// silently no-oped in Ghostty). ONLY `../`-prefixed runs are re-anchored:
    /// the title itself must signal elision. A genuinely absolute path that
    /// happens not to exist locally (an SSH/container path like `/work/repo`,
    /// an unmounted volume) must NEVER be re-anchored — that would index a
    /// same-named repo under home and inject wrong-repo vocabulary.
    /// These are FALLBACKS: `resolveWorkingDirectory` tries every exact
    /// candidate first.
    static func homeAnchoredFallbackCandidates(
        fromWindowTitle title: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let matches = abbreviatedRunRegex.matches(
            in: title,
            range: NSRange(title.startIndex..., in: title)
        )
        for match in matches {
            guard let range = Range(match.range, in: title) else { continue }
            let trimmed = trimDecorations(String(title[range]))
            // "../X" (or an ellipsis-elided variant) -> "$HOME/X".
            guard let prefix = elidedPrefixes.first(where: { trimmed.hasPrefix($0) }),
                  trimmed.count > prefix.count
            else { continue }
            let anchored = homeDirectory + "/" + String(trimmed.dropFirst(prefix.count))
            if seen.insert(anchored).inserted { result.append(anchored) }
        }
        return result
    }

    /// Elided-title prefixes accepted for home-anchoring: ASCII "../" plus
    /// the Unicode ellipses terminals actually render — U+2026 HORIZONTAL
    /// ELLIPSIS ("…/", Ghostty's real output; the T6 field title was
    /// "…/Desktop/projects/supervoxtral", owner-confirmed 2026-07-11 — a
    /// typed report loses the distinction from "../") and U+2025 TWO DOT
    /// LEADER ("‥/").
    private static let elidedPrefixes = ["../", "…/", "‥/"]

    /// The first candidate that verifies as an existing directory — every
    /// exact candidate first, then the home-anchored fallbacks for
    /// abbreviated titles. The FS check is injectable so parser tests never
    /// hit the disk.
    static func resolveWorkingDirectory(
        fromWindowTitle title: String,
        homeDirectory: String = NSHomeDirectory(),
        isDirectory: (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    ) -> String? {
        for candidate in workingDirectoryCandidates(fromWindowTitle: title, homeDirectory: homeDirectory) {
            if isDirectory(candidate) { return candidate }
        }
        for fallback in homeAnchoredFallbackCandidates(
            fromWindowTitle: title, homeDirectory: homeDirectory
        ) {
            if isDirectory(fallback) { return fallback }
        }
        return nil
    }

    /// Reads the AX title of the focused (then main) window of the app owning
    /// `pid`. Returns nil on any AX failure (no trust, no window, no title) —
    /// silent skip is fine. This is the only piece that touches live AX.
    @MainActor
    static func windowTitle(forApplicationPID pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        // A wedged/unresponsive target app must not stall the commit: cap AX
        // messaging at 0.5 s instead of the global default. The timeout is
        // per-element, so the window element below gets its own cap.
        _ = AXUIElementSetMessagingTimeout(appElement, 0.5)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var windowObject: AnyObject?
            let status = AXUIElementCopyAttributeValue(
                appElement, attribute as CFString, &windowObject
            )
            guard status == .success,
                  let windowObject,
                  CFGetTypeID(windowObject) == AXUIElementGetTypeID()
            else { continue }
            let window = unsafeDowncast(windowObject, to: AXUIElement.self)
            _ = AXUIElementSetMessagingTimeout(window, 0.5)
            var titleObject: AnyObject?
            let titleStatus = AXUIElementCopyAttributeValue(
                window, kAXTitleAttribute as CFString, &titleObject
            )
            if titleStatus == .success,
               let title = titleObject as? String,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return title
            }
        }
        return nil
    }

    /// Redacted SHAPE of a window title for field diagnostics (the T6 failure
    /// was undiagnosable because the log line carried no hint of what the
    /// title looked like): letters map to "a", digits to "9", path separators
    /// and elision marks (`/`, `.`, `~`, `…`, `‥`) and spaces survive,
    /// anything else becomes "?", capped at 60 characters. Class-mapped shape
    /// only — never raw content.
    static func titleShape(_ title: String, cap: Int = 60) -> String {
        var shape = ""
        for character in title.prefix(cap) {
            if character.isLetter {
                shape.append("a")
            } else if character.isNumber {
                shape.append("9")
            } else if character == "/" || character == "." || character == "~"
                || character == "…" || character == "‥" || character == " "
            {
                shape.append(character)
            } else {
                shape.append("?")
            }
        }
        return shape
    }

    // Static literal: a bad pattern is a coding error to crash on immediately
    // (same rationale as TextMergingAlgorithms / PolishTokenGuard).
    private static let pathRunRegex = try! NSRegularExpression(pattern: "[~/][^\\s]*")

    /// A Ghostty-elided run: "../", "…/" (U+2026) or "‥/" (U+2025), then
    /// non-whitespace. Prose "..." or a bare ".."/"…" never matches (the
    /// character after the elision mark must be `/`).
    private static let abbreviatedRunRegex = try! NSRegularExpression(
        pattern: "(?:\\.\\.|…|‥)/[^\\s]*"
    )

    /// Trailing sentence/decoration punctuation trimmed off an extracted run.
    private static let trailingDecorations: Set<Character> =
        [",", ";", ":", ")", "]", ".", "'", "\"", "»", "”"]

    private static func trimDecorations(_ segment: String) -> String {
        var value = segment
        while let last = value.last, trailingDecorations.contains(last) {
            value.removeLast()
        }
        return value
    }

    private static func expandTilde(_ path: String, homeDirectory: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return homeDirectory + String(path.dropFirst(1))
        }
        return path
    }
}

/// Title-independent fallback for terminal tabs whose foreground program has
/// replaced the window title (coding agents, editors, multiplexers, and other
/// TUIs commonly emit OSC 0). A terminal app owns every tab/window, so its PID
/// alone cannot identify which descendant process belongs to the focused tab.
/// Consequently this resolver returns a root ONLY when every descendant CWD
/// maps to the same canonical git root. A different repo, a non-repo CWD, or
/// an unreadable CWD is ambiguity, never a ranking problem: injecting no hints
/// is safer than hints from the wrong repo.
enum TerminalDescendantProcessResolver {
    struct ProcessRecord: Sendable, Equatable {
        let pid: pid_t
        let parentPID: pid_t
    }

    enum GitRootResolution: Sendable, Equatable {
        case none
        case unique(String)
        case ambiguous
        case indeterminate
    }

    /// Resolves repo roots from recursively descended process CWDs. Both live
    /// process operations are injected so unit tests never inspect real PIDs.
    static func resolveGitRoot(
        terminalApplicationPID: pid_t,
        fileManager: FileManager = .default,
        processSnapshot: @Sendable () -> [ProcessRecord] = { liveProcessSnapshot() },
        workingDirectoryForPID: @Sendable (pid_t) -> String? = { liveWorkingDirectory(forPID: $0) }
    ) -> GitRootResolution {
        let records = processSnapshot()
        var descendants = Set<pid_t>()
        descendants.insert(terminalApplicationPID)

        // A process snapshot is finite. Repeated passes handle arbitrary tree
        // depth without relying on record ordering; the set also breaks cycles
        // in malformed/injected snapshots.
        var changed = true
        while changed {
            changed = false
            for record in records where descendants.contains(record.parentPID) {
                if descendants.insert(record.pid).inserted { changed = true }
            }
        }
        descendants.remove(terminalApplicationPID)

        var roots = Set<String>()
        for pid in descendants.sorted() {
            // Omitting an unreadable descendant could hide a second tab's repo
            // and turn genuine ambiguity into a false unique result. Fail
            // closed for this commit instead. Exited-process races therefore
            // cost one best-effort hint attempt, never correctness.
            guard let cwd = workingDirectoryForPID(pid) else { return .indeterminate }
            guard let root = RepoIndexing.findGitRoot(
                startingAt: cwd, fileManager: fileManager
            ) else {
                // A non-repo descendant may be the focused plain-shell tab,
                // while the one repo we can see belongs to a background tab.
                // It therefore makes the focused repo unknowable, not absent.
                return .indeterminate
            }
            // `/var` and `/private/var` (and user-created symlink paths) can
            // name the same repo. Canonicalize so aliases cause a safe match,
            // not a false ambiguity.
            let canonicalRoot = URL(fileURLWithPath: root)
                .resolvingSymlinksInPath().standardizedFileURL.path
            roots.insert(canonicalRoot)
            if roots.count > 1 { return .ambiguous }
        }
        guard let root = roots.first else { return .none }
        return .unique(root)
    }

    /// One coherent parent/PID snapshot of the whole process table. This is
    /// deliberately a `sysctl(KERN_PROC_ALL)` snapshot rather than repeated
    /// child queries, which could splice different process generations into a
    /// tree while tabs are rapidly starting/exiting commands.
    static func liveProcessSnapshot() -> [ProcessRecord] {
        var mib = [Int32(CTL_KERN), Int32(KERN_PROC), Int32(KERN_PROC_ALL)]
        var byteCount = 0
        guard sysctl(&mib, u_int(mib.count), nil, &byteCount, nil, 0) == 0,
              byteCount > 0
        else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        // Leave growth room between the sizing and fetch calls. If the table
        // still outgrows it, fail closed for this commit; the feature is
        // best-effort and a later TTL miss/commit will retry.
        let capacity = byteCount + max(byteCount / 8, stride * 16)
        var processes = [kinfo_proc](
            repeating: kinfo_proc(), count: (capacity + stride - 1) / stride
        )
        var fetchedBytes = processes.count * stride
        let status = processes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &fetchedBytes, nil, 0)
        }
        guard status == 0 else { return [] }

        return processes.prefix(fetchedBytes / stride).map {
            ProcessRecord(pid: $0.kp_proc.p_pid, parentPID: $0.kp_eproc.e_ppid)
        }
    }

    /// Reads another process's current directory through libproc. Same-UID
    /// access is available to this unsandboxed app; failures (exited process,
    /// protected/different-UID child, kernel denial) simply omit that process.
    static func liveWorkingDirectory(forPID pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let expectedBytes = MemoryLayout<proc_vnodepathinfo>.size
        let bytes = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            Int32(expectedBytes)
        )
        guard bytes == Int32(expectedBytes) else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { path in
            path.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        // libproc reported a full structure, but an empty/non-absolute path is
        // still not a usable CWD. Treat it exactly like an unavailable lookup;
        // passing `""` to URL(fileURLWithPath:) would incorrectly mean our own
        // process directory.
        return path.hasPrefix("/") ? path : nil
    }
}

// MARK: - 2. Repo indexing

/// The vocabulary harvested from a repo: exact spellings the matcher may emit
/// (file basenames, directory path components, the branch name), deduped.
///
/// The matcher indexes are built ONCE here, at vocabulary construction — off
/// the main actor and amortized by the TTL cache — so matching a transcript
/// against a 20k-term monorepo vocabulary is O(n-grams) dictionary lookups for
/// the exact tier plus a length-bucketed sweep for the fuzzy tier, never an
/// O(grams × terms) Levenshtein product.
struct RepoVocabulary: Sendable {
    let terms: [String]
    let branch: String?
    /// Normalized form -> exact term (first appearance wins): the exact tier.
    let exactIndex: [String: String]
    /// Fuzzy-tier candidates (normalized length >= the fuzzy threshold) keyed
    /// by normalized length, so an n-gram only edit-distance-checks terms
    /// within ±1 of its own length, with character arrays precomputed.
    let fuzzyBuckets: [Int: [FuzzyCandidate]]
    /// Full-length Double Metaphone variants -> phonetic candidates. The
    /// transcript sweep performs dictionary lookups against this index; it
    /// never compares every heard n-gram with every repository term.
    let phoneticIndex: [String: [Int]]
    /// Eligible terms, stored once even when their primary/secondary keys
    /// produce several index variants.
    let phoneticCandidates: [PhoneticCandidate]
    /// Variants long enough for the conservative edit-distance-one phonetic
    /// tier, bucketed by length so each lookup remains bounded to ±1.
    /// Characters are pre-materialized once at index build so the
    /// distance-one sweep never converts per comparison (mirrors
    /// `FuzzyCandidate.normalizedCharacters`).
    let phoneticBuckets: [Int: [(variant: [Character], candidateIndex: Int)]]
    /// Candidate spellings and a character n-gram index for the conservative aligned
    /// fallback. Built once with the vocabulary so a miss never degrades into
    /// an O(transcript n-grams x every repo term) scan in a large monorepo.
    let alignedCandidates: [AlignedCandidate]
    let alignedNGramIndex: [String: [Int]]

    struct FuzzyCandidate: Sendable {
        let term: String
        let normalizedCharacters: [Character]
    }

    struct PhoneticCandidate: Sendable {
        let term: String
        let wordUnitCount: Int
        let normalized: String
    }

    struct AlignedCandidate: Sendable {
        let term: String
        let normalized: String
        let normalizedCharacters: [Character]
    }

    init(terms: [String], branch: String?) {
        self.terms = terms
        self.branch = branch
        var exact: [String: String] = [:]
        var buckets: [Int: [FuzzyCandidate]] = [:]
        var phoneticIndex: [String: [Int]] = [:]
        var phoneticCandidates: [PhoneticCandidate] = []
        var phoneticBuckets: [Int: [(variant: [Character], candidateIndex: Int)]] = [:]
        var aligned: [AlignedCandidate] = []
        var ngramIndex: [String: [Int]] = [:]
        for term in terms {
            let normalized = RepoVocabularyMatcher.normalize(term)
            if normalized.count >= RepoVocabularyMatcher.minNormalizedLength {
                if exact[normalized] == nil { exact[normalized] = term }
                if normalized.count >= RepoVocabularyMatcher.fuzzyMinNormalizedLength {
                    buckets[normalized.count, default: []].append(
                        FuzzyCandidate(term: term, normalizedCharacters: Array(normalized))
                    )
                }
            }

            let wordUnits = RepoVocabularyMatcher.phoneticWordUnits(of: term)
            if !wordUnits.isEmpty,
               wordUnits.count <= RepoVocabularyMatcher.phoneticMaxWordUnits,
               (wordUnits.count >= 2
                   || normalized.count
                        >= RepoVocabularyMatcher.phoneticMinSingleWordNormalizedLength)
            {
                let candidateIndex = phoneticCandidates.count
                phoneticCandidates.append(PhoneticCandidate(
                    term: term,
                    wordUnitCount: wordUnits.count,
                    normalized: normalized
                ))
                // Primary/secondary alternates can converge. Index each term
                // once per distinct concatenated key so an alternate cannot
                // manufacture ambiguity with itself.
                for variant in RepoVocabularyMatcher.phoneticVariants(for: wordUnits) {
                    guard variant.count >= 2 else { continue }
                    phoneticIndex[variant, default: []].append(candidateIndex)
                    if variant.count >= 4 {
                        phoneticBuckets[variant.count, default: []].append(
                            (variant: Array(variant), candidateIndex: candidateIndex)
                        )
                    }
                }
            }

            let alignedNormalized = RepoVocabularyMatcher.alignedNormalize(term)
            if alignedNormalized.count >= RepoVocabularyMatcher.alignedMinNormalizedLength {
                let candidateIndex = aligned.count
                aligned.append(AlignedCandidate(
                    term: term,
                    normalized: alignedNormalized,
                    normalizedCharacters: Array(alignedNormalized)
                ))
                for ngram in RepoVocabularyMatcher.characterNGrams(alignedNormalized) {
                    ngramIndex[ngram, default: []].append(candidateIndex)
                }
            }
        }
        self.exactIndex = exact
        self.fuzzyBuckets = buckets
        self.phoneticIndex = phoneticIndex
        self.phoneticCandidates = phoneticCandidates
        self.phoneticBuckets = phoneticBuckets
        self.alignedCandidates = aligned
        self.alignedNGramIndex = ngramIndex
    }
}

extension RepoVocabulary: Equatable {
    /// The indexes are a pure function of `terms`, so identity is terms+branch.
    static func == (lhs: RepoVocabulary, rhs: RepoVocabulary) -> Bool {
        lhs.terms == rhs.terms && lhs.branch == rhs.branch
    }
}

/// Pure-ish git-tree indexing over an injectable `FileManager`: git-root walk,
/// `.git/HEAD` branch parse (worktree gitdir-file aware), null-delimited
/// `ls-files` parsing with caps, and vocabulary assembly. No subprocess here —
/// the `ls-files` run lives in `RepoGitRunner`; this parses its bytes.
enum RepoIndexing {
    /// Walks up from `path` looking for a `.git` entry (dir OR file — worktrees
    /// use a gitdir file), capped at `maxDepth` levels. Returns the directory
    /// that contains `.git`.
    static func findGitRoot(
        startingAt path: String,
        fileManager: FileManager = .default,
        maxDepth: Int = 20
    ) -> String? {
        var current = URL(fileURLWithPath: path).standardizedFileURL
        var depth = 0
        while depth <= maxDepth {
            let gitEntry = current.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitEntry.path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }  // reached filesystem root
            current = parent
            depth += 1
        }
        return nil
    }

    /// The actual git directory for a root: `<root>/.git` when it is a real
    /// directory, else (worktree `.git` file) the `gitdir:` pointer target.
    static func resolveGitDirectory(root: String, fileManager: FileManager = .default) -> String? {
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit.path }
        guard let content = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let raw = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            if raw.hasPrefix("/") { return raw }
            return URL(fileURLWithPath: root)
                .appendingPathComponent(raw)
                .standardizedFileURL.path
        }
        return nil
    }

    /// The HEAD file inside the resolved git directory.
    static func headFileURL(root: String, fileManager: FileManager = .default) -> URL? {
        guard let gitDir = resolveGitDirectory(root: root, fileManager: fileManager) else {
            return nil
        }
        return URL(fileURLWithPath: gitDir).appendingPathComponent("HEAD")
    }

    /// The current branch from `.git/HEAD` (`ref: refs/heads/<branch>`), or nil
    /// when detached (HEAD holds a raw SHA) or unreadable. No subprocess.
    static func branch(root: String, fileManager: FileManager = .default) -> String? {
        guard let headURL = headFileURL(root: root, fileManager: fileManager),
              let content = try? String(contentsOf: headURL, encoding: .utf8)
        else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref:") else { return nil }  // detached HEAD
        let ref = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
        guard let markerRange = ref.range(of: "refs/heads/") else { return nil }
        let branch = String(ref[markerRange.upperBound...])
        return branch.isEmpty ? nil : branch
    }

    /// The `.git/HEAD` modification date, used to invalidate the cache on a
    /// checkout/commit without re-running git.
    static func headModificationDate(root: String, fileManager: FileManager = .default) -> Date? {
        guard let headURL = headFileURL(root: root, fileManager: fileManager) else { return nil }
        return (try? fileManager.attributesOfItem(atPath: headURL.path))?[.modificationDate] as? Date
    }

    /// Parses `git ls-files -z` output: paths separated by NUL. A trailing entry
    /// not terminated by NUL (a subprocess killed mid-write on timeout/cap) is
    /// dropped as incomplete — "use what was read, cleanly parseable up to the
    /// cap". Empty entries are skipped and the list is capped at `maxEntries`.
    static func parseNullDelimitedPaths(_ data: Data, maxEntries: Int = 20_000) -> [String] {
        guard !data.isEmpty else { return [] }
        let endsCleanly = data.last == 0x00
        let text = String(decoding: data, as: UTF8.self)
        var parts = text.components(separatedBy: "\0")
        if !endsCleanly, !parts.isEmpty {
            parts.removeLast()  // truncated final entry
        }
        var result: [String] = []
        for part in parts where !part.isEmpty {
            result.append(part)
            if result.count >= maxEntries { break }
        }
        return result
    }

    /// Builds the vocabulary from relative paths + the branch: each path's
    /// basename (with extension), plus its directory components as auxiliary
    /// words, plus the branch name — each admitted only when it carries a
    /// technical signal (`isTechnicalTerm`). Deduped, first-appearance order.
    static func buildVocabulary(paths: [String], branch: String?) -> RepoVocabulary {
        RepoVocabulary(terms: buildVocabularyTerms(paths: paths, branch: branch), branch: branch)
    }

    /// Builds only the ordered term list, without constructing matcher indexes.
    /// Callers that need to merge another structured source can do that first,
    /// then initialize `RepoVocabulary` once for the final combined terms.
    static func buildVocabularyTerms(paths: [String], branch: String?) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        func add(_ value: String) {
            guard !value.isEmpty, isTechnicalTerm(value), seen.insert(value).inserted else {
                return
            }
            terms.append(value)
        }
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard let basename = components.last else { continue }
            add(basename)
            for component in components.dropLast() { add(component) }
        }
        if let branch { add(branch) }
        return terms
    }

    /// Technical-signal gate: common-word path components (`Tests`,
    /// `Resources`, `docs`) must not become prompt hints — they would
    /// capitalize ordinary prose ("run the tests" -> "run the Tests"). A term
    /// qualifies only with a dot, a separator (`/`, `_`, `-`), or an internal
    /// capital in a MIXED-case word (camelCase/PascalCase: an uppercase letter
    /// past position 0 plus at least one lowercase letter — so `LICENSE`-style
    /// all-caps does not qualify). Accepted losses, deliberately: bare names
    /// like `Makefile`, `LICENSE`, `Dockerfile` carry no machine-checkable
    /// signal and are excluded.
    static func isTechnicalTerm(_ term: String) -> Bool {
        if term.contains(where: { $0 == "." || $0 == "/" || $0 == "_" || $0 == "-" }) {
            return true
        }
        let hasInternalUppercase = term.dropFirst().contains(where: \.isUppercase)
        let hasLowercase = term.contains(where: \.isLowercase)
        return hasInternalUppercase && hasLowercase
    }
}

// MARK: - git ls-files subprocess

/// Runs a read-only `git` subcommand off the main actor with hard timeout /
/// output caps. Piping uses `POSIXPipeRead` (never `FileHandle.availableData`,
/// which raises an uncatchable ObjC exception on descriptor errors —
/// AGENTS.md, PR #60).
///
/// `run` is the single process entry point: the environment isolation, the
/// bounded reader thread, the cap/timeout escalation (SIGTERM then SIGKILL),
/// and the bounded final wait are subtle enough that a second copy would be a
/// second set of the bugs this one already fixed. `lsFiles` and the Claude
/// repo collector (`ClaudeRepoCollector`) are both thin argument lists over it.
enum RepoGitRunner {
    struct Output: Sendable {
        let data: Data
        let exitCode: Int32
        let timedOut: Bool
        let capped: Bool
    }

    /// Async wrapper: hops to a background queue so the blocking Process run
    /// never touches the main actor (the caller is the @MainActor polish Task).
    ///
    /// - Parameter arguments: the subcommand and its flags, WITHOUT the
    ///   leading `-C <root>` — this adds it, so no caller can accidentally run
    ///   git against a directory other than the one it named.
    static func run(
        arguments: [String],
        root: String,
        timeoutSeconds: TimeInterval = 2.0,
        maxBytes: Int = 2_000_000
    ) async -> Output? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Output?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: runBlocking(
                        arguments: arguments,
                        root: root,
                        timeoutSeconds: timeoutSeconds,
                        maxBytes: maxBytes
                    )
                )
            }
        }
    }

    static func lsFiles(
        root: String,
        timeoutSeconds: TimeInterval = 2.0,
        maxBytes: Int = 2_000_000
    ) async -> Output? {
        await run(
            arguments: ["ls-files", "-z"],
            root: root,
            timeoutSeconds: timeoutSeconds,
            maxBytes: maxBytes
        )
    }

    private static func runBlocking(
        arguments: [String],
        root: String,
        timeoutSeconds: TimeInterval,
        maxBytes: Int
    ) -> Output? {
        let gitURL = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else {
            Log.polishing.info("git runner: /usr/bin/git not executable")
            return nil
        }

        let process = Process()
        process.executableURL = gitURL
        process.arguments = ["-C", root] + arguments
        // Determinism against user git config: no global/system config (which
        // also pins out hooks/aliases/pagers/`diff.external` — a user's
        // configured external differ or textconv filter would otherwise run
        // arbitrary programs inside what is supposed to be a read-only probe)
        // and never a credential prompt.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        // Exit is observed via terminationHandler + semaphore so the final
        // wait can be BOUNDED (see below). Set before run() so the signal can
        // never be missed, even for a process that exits instantly.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            Log.polishing.info("git runner: git failed to launch")
            return nil
        }

        // The reader thread owns the pipe fd and only mutates the mutex-guarded
        // collector; the process handle is touched only from THIS thread, so no
        // non-Sendable state crosses threads.
        let readFD = outPipe.fileHandleForReading.fileDescriptor
        let collector = Mutex<(data: Data, capped: Bool)>((Data(), false))
        let finished = DispatchSemaphore(value: 0)

        let readerThread = Thread {
            while true {
                let chunk = POSIXPipeRead.nextChunk(fromDescriptor: readFD)
                if chunk.isEmpty { break }
                let reachedCap = collector.withLock { state -> Bool in
                    state.data.append(chunk)
                    if state.data.count >= maxBytes {
                        state.capped = true
                        return true
                    }
                    return false
                }
                if reachedCap { break }
            }
            finished.signal()
        }
        readerThread.stackSize = 1 << 20
        readerThread.start()

        let timedOut = finished.wait(timeout: .now() + timeoutSeconds) == .timedOut
        let capped = collector.withLock { $0.capped }
        if timedOut || capped, process.isRunning {
            // Cap: the reader stopped consuming, so a still-writing process
            // would block forever on a full pipe — a polite SIGTERM suffices
            // (never a raw kill on a possibly-already-exited pid). Timeout:
            // the process ignored 2 s of expectations; escalate to SIGKILL so
            // the reader's read(2) sees EOF promptly.
            process.terminate()
            if timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        if timedOut {
            // Only the timeout path still has a live reader thread (blocked in
            // read(2)); the kill closes the pipe's write end so it hits EOF —
            // wait briefly for it to finish before reading the collector. The
            // cap path's reader already exited (its signal was consumed by the
            // first wait above), so waiting again there would burn the whole
            // grace period on a semaphore that can never be signaled.
            _ = finished.wait(timeout: .now() + 0.5)
        }
        // BOUNDED replacement for waitUntilExit(): a child stuck in
        // uninterruptible disk-wait can survive even SIGKILL indefinitely, and
        // an unbounded wait here would wedge the polish task and lose the
        // commit. On expiry, abandon: Foundation's process monitor (and, on
        // the timeout path, the reader thread) is deliberately leaked until
        // the kernel eventually reaps the child — vocabulary is best-effort,
        // the commit is not.
        guard exited.wait(timeout: .now() + 2.0) != .timedOut else {
            Log.polishing.info(
                "git runner: git did not exit after kill; abandoning"
            )
            return nil
        }

        let data = collector.withLock { $0.data }
        return Output(
            data: data,
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            capped: capped
        )
    }
}

// MARK: - Single-flight gate

/// Single-flight gate for the detached vocabulary pipeline. An abandoned
/// (deadline-expired) pipeline can stay parked in a blocking syscall, pinning
/// one cooperative-pool thread; without this gate every subsequent commit
/// against the same wedged mount would stack another blocked thread until the
/// pool — and the deadline mechanism itself — starves. A class holding the
/// `Mutex` (per repo conventions) so the detached pipeline wrapper can release
/// it from off-main on eventual completion.
final class RepoVocabularyFlightGate: Sendable {
    private let inFlight = Mutex(false)

    /// True when the caller acquired the gate; false when a prior pipeline is
    /// still in flight and the caller must fast-skip.
    func acquire() -> Bool {
        inFlight.withLock { alreadyInFlight in
            if alreadyInFlight { return false }
            alreadyInFlight = true
            return true
        }
    }

    func release() {
        inFlight.withLock { $0 = false }
    }
}

// MARK: - TTL cache

/// Root-keyed cache of harvested vocabularies. TTL-bounded and invalidated when
/// `.git/HEAD` mtime changes. `Mutex`-guarded per repo conventions (no actors).
/// The clock is injected at every call so tests never touch wall-clock.
final class RepoVocabularyCache: Sendable {
    private struct Cached {
        let vocabulary: RepoVocabulary
        let headModificationDate: Date?
        let cachedAt: Date
    }

    private let ttl: TimeInterval
    private let storage = Mutex<[String: Cached]>([:])

    init(ttl: TimeInterval = 300) {
        self.ttl = ttl
    }

    /// The cached vocabulary for `root` when still within TTL AND the HEAD mtime
    /// is unchanged, else nil (a fresh index is required).
    func lookup(root: String, now: Date, currentHeadModificationDate: Date?) -> RepoVocabulary? {
        storage.withLock { store in
            guard let cached = store[root] else { return nil }
            if now.timeIntervalSince(cached.cachedAt) > ttl { return nil }
            if cached.headModificationDate != currentHeadModificationDate { return nil }
            return cached.vocabulary
        }
    }

    func insert(root: String, vocabulary: RepoVocabulary, headModificationDate: Date?, now: Date) {
        storage.withLock { store in
            store[root] = Cached(
                vocabulary: vocabulary,
                headModificationDate: headModificationDate,
                cachedAt: now
            )
        }
    }
}

// MARK: - Orchestration

/// Ties indexing + cache + subprocess together: cwd -> git root -> (cache hit or
/// fresh index) -> vocabulary. The `now` clock and `runLsFiles` subprocess are
/// injected so the whole flow is testable against fixture repos / stubs.
enum RepoVocabularyService {
    static func vocabulary(
        forWorkingDirectory cwd: String,
        cache: RepoVocabularyCache,
        fileManager: FileManager = .default,
        now: @Sendable () -> Date = { Date() },
        runLsFiles: @Sendable (_ root: String) async -> RepoGitRunner.Output? = { root in
            await RepoGitRunner.lsFiles(root: root)
        }
    ) async -> RepoVocabulary? {
        guard let root = RepoIndexing.findGitRoot(startingAt: cwd, fileManager: fileManager) else {
            return nil
        }
        let headModificationDate = RepoIndexing.headModificationDate(root: root, fileManager: fileManager)
        if let cached = cache.lookup(
            root: root, now: now(), currentHeadModificationDate: headModificationDate
        ) {
            return cached
        }

        let branch = RepoIndexing.branch(root: root, fileManager: fileManager)
        guard let output = await runLsFiles(root) else {
            Log.polishing.info("Repo vocabulary: git ls-files unavailable")
            return nil
        }
        // A clean non-zero exit (not a repo, git error) with no cap/timeout is a
        // real failure: skip. On timeout/cap we keep whatever was cleanly read.
        if !output.timedOut, !output.capped, output.exitCode != 0 {
            Log.polishing.info("Repo vocabulary: git ls-files exited non-zero")
            return nil
        }

        let paths = RepoIndexing.parseNullDelimitedPaths(output.data)
        let vocabulary = RepoIndexing.buildVocabulary(paths: paths, branch: branch)
        guard !vocabulary.terms.isEmpty else {
            Log.polishing.info("Repo vocabulary: repo yielded no technical terms")
            return nil
        }
        cache.insert(
            root: root,
            vocabulary: vocabulary,
            headModificationDate: headModificationDate,
            now: now()
        )
        return vocabulary
    }

    /// The full focused-title/terminal-PID -> git root -> vocabulary -> matched
    /// entries pipeline for one commit. The focused title remains tier 1: it
    /// can soundly distinguish a focused tab even when other tabs use other
    /// repos. When it contains no usable repo path, tier 2 walks terminal
    /// descendants and proceeds only if every process CWD maps to one root.
    /// Everything here may block, so the view model runs it inside a
    /// detached task; only the AX title read stays on the main actor.
    static func entries(
        forWindowTitle title: String?,
        terminalApplicationPID: pid_t? = nil,
        transcript: String,
        cache: RepoVocabularyCache,
        fileManager: FileManager = .default,
        processSnapshot: @Sendable () -> [TerminalDescendantProcessResolver.ProcessRecord] = {
            TerminalDescendantProcessResolver.liveProcessSnapshot()
        },
        workingDirectoryForPID: @Sendable (pid_t) -> String? = {
            TerminalDescendantProcessResolver.liveWorkingDirectory(forPID: $0)
        }
    ) async -> RepoVocabularyMatcher.GroundingOutcome? {
        var gitRoot: String?
        if let title,
           let titleDirectory = TerminalWorkingDirectoryResolver.resolveWorkingDirectory(
               fromWindowTitle: title,
               isDirectory: { path in
                   var isDirectory: ObjCBool = false
                   return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                       && isDirectory.boolValue
               }
           )
        {
            gitRoot = RepoIndexing.findGitRoot(startingAt: titleDirectory, fileManager: fileManager)
        }

        if gitRoot == nil, let terminalApplicationPID {
            switch TerminalDescendantProcessResolver.resolveGitRoot(
                terminalApplicationPID: terminalApplicationPID,
                fileManager: fileManager,
                processSnapshot: processSnapshot,
                workingDirectoryForPID: workingDirectoryForPID
            ) {
            case .unique(let root):
                gitRoot = root
                Log.polishing.info("Repo vocabulary: resolved git root from terminal descendants")
            case .ambiguous:
                Log.polishing.info("Repo vocabulary skipped: terminal descendants span multiple repos")
                return nil
            case .indeterminate:
                Log.polishing.info("Repo vocabulary skipped: terminal descendant cwds do not establish one repo")
                return nil
            case .none:
                break
            }
        }

        guard let gitRoot else {
            // Shape is class-mapped (letters->a, digits->9), never content —
            // safe as .public, and makes the NEXT field failure of this kind
            // self-diagnosing (T6 was invisible without it).
            if let title {
                Log.polishing.info(
                    "Repo vocabulary: no git root resolved from title or terminal descendants (title shape: \(TerminalWorkingDirectoryResolver.titleShape(title), privacy: .public))"
                )
            } else {
                Log.polishing.info("Repo vocabulary: no git root resolved from terminal descendants")
            }
            return nil
        }
        guard let vocabulary = await vocabulary(
            forWorkingDirectory: gitRoot, cache: cache, fileManager: fileManager
        ) else {
            return nil
        }
        #if LOCALVOXTRAL_DOGFOOD
        // The exact term pool matching runs against, which the returned
        // outcome no longer carries — see `DogfoodCaptureTap`.
        DogfoodCaptureTap.shared.noteRepoVocabularyHarvest(vocabulary.terms)
        #endif
        // Carries provenance, not just entries: whether these came from the
        // exact / edit-distance-one tiers or from the bounded aligned fallback
        // decides who yields when another context source covers the same heard
        // span (`PolishContextGrounding`). Collapsing that to a bare array here
        // is what forced the merge to assume every repo entry was solid.
        let outcome = RepoVocabularyMatcher.groundedCandidates(
            transcript: transcript, vocabulary: vocabulary
        )
        if outcome.entries.isEmpty,
           outcome.phoneticEntries.isEmpty,
           outcome.verificationCandidates.isEmpty
        {
            // Static string + no content: the LAST silent skip on this path.
            // Every skip reason is .info — .debug is not persisted by the
            // unified log store, which made a field no-attach undiagnosable
            // (2026-07-11, Ghostty).
            Log.polishing.info("Repo vocabulary: no transcript-relevant matches")
            return nil
        }
        return outcome
    }
}

// MARK: - 3. Transcript matching

/// Matches spoken transcript n-grams against repo vocabulary and emits
/// `ReplacementEntry`s (exact spelling -> the spoken form) for the polish
/// prompt. Pure functions, mirroring `PolishTokenGuard` / `TextMergingAlgorithms`.
enum RepoVocabularyMatcher {
    /// Hard cap on emitted entries — grounding hints, not an index dump.
    static let maxEntries = 12
    /// Minimum normalized length on BOTH sides. Drops collision-prone short
    /// forms (`app`, `src`) as standalone entries while still letting them count
    /// inside longer n-grams (`app.tsx`).
    static let minNormalizedLength = 4
    /// Minimum normalized length (both sides) for the edit-distance-1 fuzzy
    /// tier — short forms would collide constantly.
    static let fuzzyMinNormalizedLength = 8
    /// A single word needs more evidence than a multi-word phrase before
    /// pronunciation alone may nominate it. Short homophones such as
    /// `pane`/`pain` therefore remain ordinary prose unless another tier owns
    /// them, while a phrase like `terminal pane` is eligible.
    static let phoneticMinSingleWordNormalizedLength = 8
    /// Pre-application (a silent rewrite) demands more evidence than a
    /// verification suggestion, for every window shape: the heard span must
    /// carry as many normalized characters as a single-word candidate needs,
    /// and the agreeing key must carry enough consonant structure that the
    /// agreement is unlikely to be a short-homophone accident. Otherwise a
    /// multi-word term gluing a stopword onto a short homophone (`thePane`
    /// heard as "the pain") would silently rewrite ordinary prose. Weaker
    /// exact-key hits remain verification candidates.
    static let phoneticMinPreApplyNormalizedLength = 8
    static let phoneticMinPreApplyKeyLength = 6
    /// Bounds both index expansion (at most 2^4 key variants) and transcript
    /// n-grams. Longer identifiers are better served by the character tiers.
    static let phoneticMaxWordUnits = 4
    /// Weak phonetic evidence is prompt-only and deliberately scarce: it
    /// should help verification, not become a vocabulary dump.
    static let phoneticMaxVerificationCandidates = 4
    /// The aligned fallback is intentionally narrower than the exact matcher:
    /// short strings collide too easily in normal prose.
    static let alignedMinNormalizedLength = 8
    static let alignedMinimumScore = 0.60
    static let alignedMinimumMargin = 0.05
    static let alignedVerificationMinimumScore = 0.55
    static let alignedMaxWords = 7
    /// A span whose rarest shared n-gram still fans out beyond this cap is not
    /// distinctive enough for deterministic grounding. This also bounds work
    /// in large same-language monorepos.
    static let alignedMaxCandidatesPerSpan = 512

    /// Spoken separator words map to the symbols the file side already strips,
    /// so "use auth dot t s" normalizes identically to `useAuth.ts`.
    private static let spokenSeparators: Set<String> =
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
    static func normalize(_ text: String) -> String {
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
    static func phoneticWordUnits(of term: String) -> [String] {
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
    static func phoneticVariants(for wordUnits: [String]) -> [String] {
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
    struct PhoneticOutcome: Equatable, Sendable {
        let preApply: [ReplacementEntry]
        let verification: [ReplacementEntry]

        static let empty = PhoneticOutcome(preApply: [], verification: [])
    }

    /// Matches transcript word n-grams through the prebuilt phonetic indexes.
    /// Exact/fuzzy character ownership is checked before recording a hit, so
    /// phonetics never duplicate stronger evidence. Exact pronunciation is a
    /// pre-apply guess only when one distinct local term owns the heard key;
    /// ambiguity, distance-one pronunciation, and unspoken extensions remain
    /// prompt-only suggestions.
    static func phoneticCandidates(
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
            .prefix(phoneticMaxVerificationCandidates).map {
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
    static func candidateEntries(
        transcript: String,
        vocabulary: RepoVocabulary
    ) -> [ReplacementEntry] {
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
        return ranked.prefix(maxEntries).map {
            ReplacementEntry(replaceWith: $0.term, matches: [$0.spoken])
        }
    }

    /// Production matcher: keep entries approved by the existing exact /
    /// edit-distance-one tiers unless one heard span maps to multiple terms.
    /// Exact-index hits are single-valued; multiple terms for the same span are
    /// therefore tied distance-one fuzzy hits and must all abstain. Only when
    /// those tiers leave NOTHING, try one broader aligned match (which applies
    /// its own score margin) and otherwise abstain.
    static func groundedCandidateEntries(
        transcript: String,
        vocabulary: RepoVocabulary
    ) -> [ReplacementEntry] {
        groundedCandidates(transcript: transcript, vocabulary: vocabulary).entries
    }

    /// One source's grounding decision, carrying HOW it was reached.
    ///
    /// `isFallbackOnly` distinguishes "the exact / edit-distance-one tiers
    /// approved these" from "those tiers found nothing and the bounded aligned
    /// matcher guessed once". Within a single source that difference is already
    /// spent; across sources it decides who yields — see
    /// `PolishContextGrounding`.
    struct GroundingOutcome: Equatable, Sendable {
        let entries: [ReplacementEntry]
        let isFallbackOnly: Bool
        /// Exact, unambiguous phonetic-key matches. They are still guess grade
        /// across sources, but may be pre-applied when nobody contests them.
        let phoneticEntries: [ReplacementEntry]
        /// Weak or contested evidence whose original transcript bytes must
        /// remain untouched. A later prompt renderer can present these as
        /// explicit possible-mishearing pairs.
        let verificationCandidates: [ReplacementEntry]

        init(
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
        static let empty = GroundingOutcome(
            entries: [],
            isFallbackOnly: false,
            phoneticEntries: [],
            verificationCandidates: []
        )
    }

    /// `groundedCandidateEntries` with its provenance retained.
    static func groundedCandidates(
        transcript: String,
        vocabulary: RepoVocabulary
    ) -> GroundingOutcome {
        let approved = candidateEntries(transcript: transcript, vocabulary: vocabulary)
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

        let primaryEntries: [ReplacementEntry]
        let isFallbackOnly: Bool
        if !unambiguous.isEmpty {
            primaryEntries = unambiguous
            isFallbackOnly = false
        } else if let fallback {
            primaryEntries = [fallback]
            isFallbackOnly = true
        } else {
            primaryEntries = []
            isFallbackOnly = false
        }

        // `maxEntries` remains the total pre-application budget. Existing
        // solid/fallback entries spend it first; phonetic guesses use only the
        // remainder and never displace stronger evidence.
        let phoneticBudget = max(0, maxEntries - primaryEntries.count)
        phoneticPreApply = Array(phoneticPreApply.prefix(phoneticBudget))

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

        var verificationCandidates: [ReplacementEntry] = []
        var seenVerification = Set<VerificationKey>()
        for entry in phoneticVerification + alignedVerification {
            for heard in entry.matches {
                let key = VerificationKey(heardKey: normalize(heard), term: entry.replaceWith)
                guard seenVerification.insert(key).inserted else { continue }
                verificationCandidates.append(ReplacementEntry(
                    replaceWith: entry.replaceWith,
                    matches: [heard]
                ))
                if verificationCandidates.count == phoneticMaxVerificationCandidates { break }
            }
            if verificationCandidates.count == phoneticMaxVerificationCandidates { break }
        }

        return GroundingOutcome(
            entries: primaryEntries,
            isFallbackOnly: isFallbackOnly,
            phoneticEntries: phoneticPreApply,
            verificationCandidates: verificationCandidates
        )
    }

    /// Places exact vocabulary bytes into only the literal ASR spans already
    /// selected by the matcher. Longest aliases run first; technical-token
    /// boundaries prevent a short alias from rewriting inside another path or
    /// identifier. Punctuation remains outside the replaced range.
    static func preapplying(
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
    /// and emits at most one mapping.
    static func alignedFallbackEntry(
        transcript: String,
        vocabulary: RepoVocabulary
    ) -> ReplacementEntry? {
        alignedFallbackOutcome(transcript: transcript, vocabulary: vocabulary).approved
    }

    /// The aligned matcher has one deterministic approval channel and a small
    /// demotion channel for evidence that narrowly misses confidence. Only
    /// score ambiguity, a near score, or an unspoken extension can be useful
    /// to the model; a single glued word inflated far beyond the candidate is
    /// a structural mismatch and remains a hard drop.
    static func alignedFallbackOutcome(
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
        let term: String
        let normalizedLength: Int
        let position: Int
        let spoken: String
        let exact: Bool
    }

    private struct PhoneticHit {
        let term: String
        let normalizedLength: Int
        let position: Int
        let spoken: String
        let exactKey: Bool
    }

    private struct VerificationKey: Hashable {
        let heardKey: String
        let term: String
    }

    private struct FallbackToken {
        let lowerBound: String.Index
        let upperBound: String.Index
    }

    private struct AlignedHit {
        let candidateIndex: Int
        let heard: String
        let score: Double
        let lengthDelta: Int
        let startWord: Int
        let wordCount: Int
    }

    private static let nonAlphanumericEdges = CharacterSet.alphanumerics.inverted
    private static let fallbackEdgeCharacters = CharacterSet(
        charactersIn: "`'\"“”‘’()[]{}<>.,;:!?"
    )

    /// Splits on whitespace and trims each word of leading/trailing
    /// non-alphanumerics (STT-sprinkled commas/periods) so the normalized form
    /// and the "as spoken" match string are both clean.
    private static func tokenize(_ transcript: String) -> [String] {
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
    static func alignedNormalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(String.init).joined()
    }

    static func characterNGrams(_ value: String, width: Int = 2) -> Set<String> {
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

    private static func hasTechnicalBoundaries(
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
    static func sanitizedTerm(_ term: String) -> String {
        PolishContextClipboardReader.sanitizeControlCharacters(term)
            .filter { $0 != "\n" && $0 != "\t" && $0 != "\"" }
            .trimmingCharacters(in: .whitespaces)
    }

    /// A sanitized term is renderable when something meaningful remains: not
    /// empty, and not a bare dash run (`---` would read as a section divider).
    private static func isRenderableTerm(_ term: String) -> Bool {
        !term.isEmpty && !term.allSatisfy { $0 == "-" }
    }

    /// Header for entries harvested from the focused terminal's git repo.
    static let repositoryVocabularyHeader =
        "Repository vocabulary (exact file names and identifiers from the project the "
        + "speaker is working in; use them to correct near-miss spellings of the terms "
        + "below, never to add new content):"

    /// Header for entries harvested from the user's clipboard excerpt (the
    /// clipboard polish-context feature): same rendering, honest provenance.
    static let clipboardVocabularyHeader =
        "Clipboard vocabulary (exact file names and identifiers from text the user "
        + "recently copied; use them to correct near-miss spellings of the terms "
        + "below, never to add new content):"

    /// Header for entries harvested from the terminal screen the speaker was
    /// looking at (the terminal screen polish-context feature): same rendering,
    /// honest provenance. Used for BOTH the `render` and `vocabularyOnly`
    /// reconciliation outcomes — in the latter the excerpt itself is withheld,
    /// but these entries are still terms the user could see while speaking.
    static let terminalScreenVocabularyHeader =
        "Terminal screen vocabulary (exact file names and identifiers visible on the "
        + "speaker's terminal screen; use them to correct near-miss spellings of the "
        + "terms below, never to add new content):"

    /// Header for entries harvested from the joined Claude Code session's own
    /// state — the request the speaker previously sent that agent and the files
    /// it touched. Same rendering, honest provenance.
    static let claudeSessionVocabularyHeader =
        "Coding agent session vocabulary (exact file names and identifiers from the "
        + "speaker's open coding-agent session; use them to correct near-miss spellings "
        + "of the terms below, never to add new content):"

    /// Header for below-threshold matcher candidates rendered as explicit
    /// verification suggestions rather than pre-applied bytes. The matcher was
    /// not confident enough to edit the user's words deterministically, so the
    /// model verifies each untrusted guess against the surrounding transcript —
    /// the same reference-block defense framing used by the context sections.
    static let verificationCandidatesHeader =
        "Possible mishearings (unverified guesses pairing a transcript phrase with a "
        + "project term it may be a mishearing of; rewrite a phrase to its paired term "
        + "only when the surrounding transcript clearly supports that term; when unsure, "
        + "keep the transcript's words unchanged; never use these to add new content):"

    /// Renders the merge's prompt-only guesses as explicit heard/exact pairs.
    /// Both sides pass through the same single-line defense as vocabulary terms;
    /// a malformed or now-identical pair contributes no instruction to the model.
    static func verificationPromptSection(
        pairs: [PolishContextGrounding.VerificationPair]
    ) -> String {
        let lines: [String] = pairs.compactMap { pair in
            let heard = sanitizedTerm(pair.heard)
            let exact = sanitizedTerm(pair.exact)
            guard isRenderableTerm(heard),
                  isRenderableTerm(exact),
                  heard != exact
            else { return nil }
            return "- possible mishearing: \"\(heard)\" -> \"\(exact)\""
        }
        guard !lines.isEmpty else { return "" }
        return "\(verificationCandidatesHeader)\n\(lines.joined(separator: "\n"))"
    }

    /// Appends prompt-only verification suggestions beside the replacement-
    /// dictionary sections. An empty base leaves the section standing alone;
    /// if sanitization removes every pair, the existing base stays byte-exact.
    static func appendedVerificationSection(
        base: String,
        pairs: [PolishContextGrounding.VerificationPair]
    ) -> String {
        let section = verificationPromptSection(pairs: pairs)
        guard !section.isEmpty else { return base }
        guard !base.isEmpty else { return section }
        return base + "\n\n" + section
    }

    /// Renders matched entries as a prompt section mirroring
    /// `ReplacementDictionary.renderedPromptSection`'s `- key: aliases` shape,
    /// under the given header. Every key/alias is sanitized first; an entry
    /// whose key or every alias becomes unrenderable is dropped. Empty entries
    /// render nothing.
    static func promptSection(
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
    static func appendedPromptSection(
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

// MARK: - Clipboard vocabulary

/// Clipboard entities join the vocabulary-hint pipeline: the clipboard polish-
/// context excerpt tells the model the exact spelling of a copied identifier.
/// Extracting its code-like entities with the existing `PolishTokenGuard`
/// recognizer plus a narrow technical-identifier supplement, matching
/// transcript n-grams against them exactly like repo vocabulary, then
/// pre-applying only the selected spans gives the model exact bytes without
/// scanning its output.
///
/// Pure functions; all privacy gating (feature toggle, loopback endpoint,
/// concealed/transient pasteboard) already happened when the excerpt was
/// captured — this type never touches the pasteboard.
enum ClipboardVocabulary {
    /// Ordered, de-duplicated code-like entities in `excerpt`, recognized by
    /// `PolishTokenGuard.protectedTokens` plus a narrow supplemental grammar
    /// for long bare env vars, method signatures, and mixed-case identifiers.
    /// Backtick spans are unwrapped to their inner text: the vocabulary term
    /// is the identifier, not its markdown decoration.
    static func entities(inExcerpt excerpt: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func append(_ term: String) {
            guard !term.isEmpty, seen.insert(term).inserted else { return }
            result.append(term)
        }
        for token in PolishTokenGuard.protectedTokens(in: excerpt) {
            var term = token
            if term.hasPrefix("`"), term.hasSuffix("`"), term.count > 2 {
                term = String(term.dropFirst().dropLast())
            }
            append(term)
        }
        // The guard recognizer is intentionally conservative and does not
        // cover every useful INPUT-side context spelling (notably a bare
        // ALL_CAPS env var, a method signature, or a PascalCase package name).
        // Admit only long tokens carrying machine-checkable technical signal;
        // ordinary clipboard prose never becomes a fallback candidate.
        for match in supplementalEntityRegex.matches(
            in: excerpt,
            range: NSRange(excerpt.startIndex..., in: excerpt)
        ) {
            guard let range = Range(match.range, in: excerpt) else { continue }
            var term = String(excerpt[range])
                .trimmingCharacters(in: supplementalEntityEdges)
            if term.hasSuffix(")"), !term.contains("(") {
                term.removeLast()
            }
            guard isSupplementalTechnicalEntity(term) else { continue }
            append(term)
        }
        return result
    }

    private static let supplementalEntityRegex = try! NSRegularExpression(
        pattern: #"[$#A-Za-z0-9][_$#A-Za-z0-9./:()'\-]{6,}"#
    )
    private static let supplementalEntityEdges = CharacterSet(
        charactersIn: "`'\"“”‘’[]{}<>.,;!?"
    )

    private static func isSupplementalTechnicalEntity(_ value: String) -> Bool {
        guard value.count >= 7 else { return false }
        let envBody = value.drop(while: { $0 == "$" })
        let isLongEnvironmentVariable = envBody.contains("_")
            && envBody.contains(where: { $0.isLetter })
            && envBody.allSatisfy { $0 == "_" || $0.isUppercase || $0.isNumber }
        if isLongEnvironmentVariable { return true }

        if let openParen = value.firstIndex(of: "("),
           openParen != value.startIndex,
           value.hasSuffix(")")
        {
            return true
        }

        let hasLowercase = value.contains { $0.isLowercase }
        let hasInternalUppercase = value.dropFirst().contains { $0.isUppercase }
        let hasLetter = value.contains { $0.isLetter }
        let hasNumber = value.contains { $0.isNumber }
        return (hasLowercase && hasInternalUppercase) || (hasLetter && hasNumber)
    }

    /// The transcript-relevant clipboard entities as replacement entries, via
    /// the exact matcher repo vocabulary uses (same n-gram windows, same
    /// normalization, same fuzzy tier, same cap). Empty when the excerpt holds
    /// no code-like entities or none matches the transcript.
    static func candidateEntries(
        transcript: String,
        excerpt: String
    ) -> [ReplacementEntry] {
        candidateOutcome(transcript: transcript, clipboardText: excerpt).entries
    }

    /// `candidateEntries` with its provenance retained, over the COMPLETE
    /// retained clipboard text.
    ///
    /// `clipboardText` is deliberately not called `excerpt`: matching runs over
    /// everything capture retained, not over the smaller block the budget
    /// renders into the prompt. A term is groundable when the user copied it —
    /// not when it happened to survive excerpt selection.
    static func candidateOutcome(
        transcript: String,
        clipboardText: String
    ) -> RepoVocabularyMatcher.GroundingOutcome {
        let terms = entities(inExcerpt: clipboardText)
        guard !terms.isEmpty else { return .empty }
        let vocabulary = RepoVocabulary(terms: terms, branch: nil)
        return RepoVocabularyMatcher.groundedCandidates(
            transcript: transcript,
            vocabulary: vocabulary
        )
    }
}
