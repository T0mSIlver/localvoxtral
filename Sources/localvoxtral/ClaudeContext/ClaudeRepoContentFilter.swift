import Foundation

/// Decides what a repository collection is allowed to look at.
///
/// Pure functions, no I/O, mirroring `TextMergingAlgorithms` /
/// `RepoVocabularyMatcher`: the collector does the reading, this decides what
/// is worth reading. Split out because these are the rules most likely to need
/// tuning against real repos, and they should be tunable without touching
/// process handling or deadlines.
enum ClaudeRepoContentFilter {
    /// Path prefixes/components that are machine-generated, vendored, or
    /// otherwise not the user's own work.
    ///
    /// The point is signal, not secrecy: `node_modules` is tracked in plenty of
    /// repos, and attaching a minified bundle to a dictation prompt spends the
    /// whole budget to tell the model nothing about what the user is doing.
    /// Matched as a full PATH COMPONENT, never a substring — `src/nodes/` must
    /// not be excluded because it starts with `node`.
    static let excludedComponents: Set<String> = [
        ".build",
        ".git",
        ".gradle",
        ".idea",
        ".mypy_cache",
        ".next",
        ".pytest_cache",
        ".svelte-kit",
        ".terraform",
        ".tox",
        ".venv",
        ".vs",
        "DerivedData",
        "Pods",
        "__pycache__",
        "bower_components",
        "build",
        "coverage",
        "dist",
        "node_modules",
        "target",
        "vendor",
        "venv",
    ]

    /// Extensions whose contents are never useful text here. Lockfiles are in
    /// this list for the same reason as `node_modules`: enormous, generated,
    /// and never what someone dictates about.
    static let excludedExtensions: Set<String> = [
        "lock", "map", "min", "pack", "pyc", "class", "o", "a", "so", "dylib",
        "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "pdf", "zip", "gz",
        "tar", "bz2", "xz", "7z", "mp3", "mp4", "mov", "wav", "woff", "woff2",
        "ttf", "otf", "eot", "bin", "dat", "db", "sqlite", "wasm",
    ]

    /// Exact filenames that are generated or lock-like regardless of extension.
    static let excludedFilenames: Set<String> = [
        "Package.resolved",
        "package-lock.json",
        "pnpm-lock.yaml",
        "yarn.lock",
        "Cargo.lock",
        "poetry.lock",
        "Gemfile.lock",
        "composer.lock",
        "go.sum",
    ]

    /// True when the repo-relative path lives in a generated/vendored tree or
    /// is itself a generated artifact.
    static func isGeneratedOrVendored(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let filename = components.last else { return true }
        for component in components.dropLast() where excludedComponents.contains(component) {
            return true
        }
        // A generated DIRECTORY name in the last position is still a directory
        // we do not want, and a caller passing one is asking about the wrong
        // thing either way.
        if excludedComponents.contains(filename) { return true }
        if excludedFilenames.contains(filename) { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty, excludedExtensions.contains(ext) { return true }
        return false
    }

    /// True for files whose contents are counted but never attached.
    ///
    /// A log is the highest-risk, lowest-value text in a tree: it is where
    /// tokens, hostnames, stack traces, and customer identifiers accumulate,
    /// and its NAME already tells the model everything the user's dictation
    /// needs ("the build log"). So logs are count-only — they contribute
    /// provenance and vocabulary, never bytes.
    static func isLogLike(_ relativePath: String) -> Bool {
        let filename = (relativePath as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "log" { return true }
        let components = relativePath.split(separator: "/").map(String.init)
        return components.dropLast().contains { $0 == "logs" || $0 == "log" }
    }

    /// Binary heuristic: a NUL byte in the head.
    ///
    /// The same rule `git` itself uses to decide a file is binary, and it is
    /// the right one here for the same reason — it is cheap, it has no false
    /// positives on real text (UTF-8 text never contains NUL), and its false
    /// NEGATIVES (a binary format with no NUL in its first 8k) are caught
    /// downstream by the UTF-8 decode, which such a file will fail.
    static func looksBinary(_ data: Data, headBytes: Int = 8_000) -> Bool {
        data.prefix(headBytes).contains(0x00)
    }

    /// Tracked paths the transcript plausibly refers to, best match first.
    ///
    /// Uses the SAME normalization as the vocabulary matcher, so a speaker who
    /// says "the dictation view model" selects `DictationViewModel.swift`
    /// without pronouncing the extension, and "polish context budget" selects
    /// `PolishContextBudget.swift`. Matching on the normalized BASENAME (not
    /// the whole path) keeps a directory name from dragging in every file
    /// under it.
    ///
    /// Deterministic: ties break on path order, never on dictionary iteration.
    static func transcriptMatchedPaths(
        trackedPaths: [String],
        excluding: Set<String>,
        transcript: String,
        limit: Int
    ) -> [String] {
        guard limit > 0, !transcript.isEmpty else { return [] }
        let normalizedTranscript = RepoVocabularyMatcher.normalize(transcript)
        guard !normalizedTranscript.isEmpty else { return [] }

        struct Match {
            let path: String
            let length: Int
            let index: Int
        }
        var matches: [Match] = []
        for (index, path) in trackedPaths.enumerated() {
            guard !excluding.contains(path) else { continue }
            guard !isGeneratedOrVendored(path), !isLogLike(path) else { continue }
            let basename = (path as NSString).lastPathComponent
            let normalized = RepoVocabularyMatcher.normalize(basename)
            // Short basenames (`api.ts` -> `apits`) collide with ordinary prose
            // far too easily to select a whole file on.
            guard normalized.count >= 8 else { continue }
            guard normalizedTranscript.contains(normalized) else { continue }
            matches.append(Match(path: path, length: normalized.count, index: index))
        }
        // Longest normalized match first: a transcript containing
        // `DictationViewModel+Session.swift` mentions `Session.swift` too, and
        // the specific file is the one meant.
        return matches
            .sorted {
                if $0.length != $1.length { return $0.length > $1.length }
                return $0.index < $1.index
            }
            .prefix(limit)
            .map(\.path)
    }
}
