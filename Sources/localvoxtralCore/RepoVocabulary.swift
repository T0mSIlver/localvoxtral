import Foundation

// MARK: - 2. Repo indexing

/// The vocabulary harvested from a repo: exact spellings the matcher may emit
/// (file basenames, directory path components, the branch name), deduped.
///
/// The matcher indexes are built ONCE here, at vocabulary construction — off
/// the main actor and amortized by the TTL cache — so matching a transcript
/// against a 20k-term monorepo vocabulary is O(n-grams) dictionary lookups for
/// the exact tier plus a length-bucketed sweep for the fuzzy tier, never an
/// O(grams × terms) Levenshtein product.
package struct RepoVocabulary: Sendable {
    package let terms: [String]
    package let branch: String?
    /// Normalized form -> exact term (first appearance wins): the exact tier.
    package let exactIndex: [String: String]
    /// Fuzzy-tier candidates (normalized length >= the fuzzy threshold) keyed
    /// by normalized length, so an n-gram only edit-distance-checks terms
    /// within ±1 of its own length, with character arrays precomputed.
    package let fuzzyBuckets: [Int: [FuzzyCandidate]]
    /// Full-length Double Metaphone variants -> phonetic candidates. The
    /// transcript sweep performs dictionary lookups against this index; it
    /// never compares every heard n-gram with every repository term.
    package let phoneticIndex: [String: [Int]]
    /// Eligible terms, stored once even when their primary/secondary keys
    /// produce several index variants.
    package let phoneticCandidates: [PhoneticCandidate]
    /// Variants long enough for the conservative edit-distance-one phonetic
    /// tier, bucketed by length so each lookup remains bounded to ±1.
    /// Characters are pre-materialized once at index build so the
    /// distance-one sweep never converts per comparison (mirrors
    /// `FuzzyCandidate.normalizedCharacters`).
    package let phoneticBuckets: [Int: [(variant: [Character], candidateIndex: Int)]]
    /// Candidate spellings and a character n-gram index for the conservative aligned
    /// fallback. Built once with the vocabulary so a miss never degrades into
    /// an O(transcript n-grams x every repo term) scan in a large monorepo.
    package let alignedCandidates: [AlignedCandidate]
    package let alignedNGramIndex: [String: [Int]]

    package struct FuzzyCandidate: Sendable {
        package let term: String
        package let normalizedCharacters: [Character]
    }

    package struct PhoneticCandidate: Sendable {
        package let term: String
        package let wordUnitCount: Int
        package let normalized: String
    }

    package struct AlignedCandidate: Sendable {
        package let term: String
        package let normalized: String
        package let normalizedCharacters: [Character]
    }

    package init(terms: [String], branch: String?) {
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
    package static func == (lhs: RepoVocabulary, rhs: RepoVocabulary) -> Bool {
        lhs.terms == rhs.terms && lhs.branch == rhs.branch
    }
}

/// Pure-ish git-tree indexing over an injectable `FileManager`: git-root walk,
/// `.git/HEAD` branch parse (worktree gitdir-file aware), null-delimited
/// `ls-files` parsing with caps, and vocabulary assembly. No subprocess here —
/// the `ls-files` run lives in `RepoGitRunner`; this parses its bytes.
package enum RepoIndexing {
    /// Walks up from `path` looking for a `.git` entry (dir OR file — worktrees
    /// use a gitdir file), capped at `maxDepth` levels. Returns the directory
    /// that contains `.git`.
    package static func findGitRoot(
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
    package static func resolveGitDirectory(root: String, fileManager: FileManager = .default) -> String? {
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

    /// The main checkout of the repository `root` belongs to: `root` itself,
    /// unless `root` is a linked worktree (#652). What `git rev-parse
    /// --git-common-dir` answers, read from the files git keeps rather than
    /// by running git: a linked worktree's git directory holds a `commondir`
    /// file naming the shared one, and a main checkout's or a submodule's does
    /// not, so both keep their own root.
    ///
    /// When the shared git directory is a checkout's `.git`, the checkout is
    /// its parent. Anything else (a bare repository, a submodule's
    /// `.git/modules/<name>`) has no checkout to name, so the shared directory
    /// itself stands for the repository: still one answer for every worktree.
    package static func mainCheckout(ofRoot root: String, fileManager: FileManager = .default) -> String {
        guard let gitDirectory = resolveGitDirectory(root: root, fileManager: fileManager) else {
            return root
        }
        let gitDirectoryURL = URL(fileURLWithPath: gitDirectory).standardizedFileURL
        guard let data = fileManager.contents(
            atPath: gitDirectoryURL.appendingPathComponent("commondir").path
        ),
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return root }
        let common = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw).standardizedFileURL
            : gitDirectoryURL.appendingPathComponent(raw).standardizedFileURL
        guard common.path != gitDirectoryURL.path else { return root }
        return common.lastPathComponent == ".git"
            ? common.deletingLastPathComponent().path
            : common.path
    }

    /// The HEAD file inside the resolved git directory.
    package static func headFileURL(root: String, fileManager: FileManager = .default) -> URL? {
        guard let gitDir = resolveGitDirectory(root: root, fileManager: fileManager) else {
            return nil
        }
        return URL(fileURLWithPath: gitDir).appendingPathComponent("HEAD")
    }

    /// The current branch from `.git/HEAD` (`ref: refs/heads/<branch>`), or nil
    /// when detached (HEAD holds a raw SHA) or unreadable. No subprocess.
    package static func branch(root: String, fileManager: FileManager = .default) -> String? {
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
    package static func headModificationDate(root: String, fileManager: FileManager = .default) -> Date? {
        guard let headURL = headFileURL(root: root, fileManager: fileManager) else { return nil }
        return (try? fileManager.attributesOfItem(atPath: headURL.path))?[.modificationDate] as? Date
    }

    /// Parses `git ls-files -z` output: paths separated by NUL. A trailing entry
    /// not terminated by NUL (a subprocess killed mid-write on timeout/cap) is
    /// dropped as incomplete — "use what was read, cleanly parseable up to the
    /// cap". Empty entries are skipped and the list is capped at `maxEntries`.
    package static func parseNullDelimitedPaths(_ data: Data, maxEntries: Int = 20_000) -> [String] {
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
    package static func buildVocabulary(paths: [String], branch: String?) -> RepoVocabulary {
        RepoVocabulary(terms: buildVocabularyTerms(paths: paths, branch: branch), branch: branch)
    }

    /// Builds only the ordered term list, without constructing matcher indexes.
    /// Callers that need to merge another structured source can do that first,
    /// then initialize `RepoVocabulary` once for the final combined terms.
    package static func buildVocabularyTerms(paths: [String], branch: String?) -> [String] {
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
    package static func isTechnicalTerm(_ term: String) -> Bool {
        if term.contains(where: { $0 == "." || $0 == "/" || $0 == "_" || $0 == "-" }) {
            return true
        }
        let hasInternalUppercase = term.dropFirst().contains(where: \.isUppercase)
        let hasLowercase = term.contains(where: \.isLowercase)
        return hasInternalUppercase && hasLowercase
    }
}
