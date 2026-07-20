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

    /// Path components whose whole subtree is credential material.
    ///
    /// Matched as a full PATH COMPONENT for the same reason as
    /// `excludedComponents`: `Sources/Secrets/` is a secret store, `src/secretsanta/`
    /// is not.
    static let secretComponents: Set<String> = [
        ".aws",
        ".gcloud",
        ".gnupg",
        ".ssh",
        "secrets",
    ]

    /// Extensions that ARE key material regardless of what the file is called.
    /// A `.pem` has exactly one thing in it.
    static let secretExtensions: Set<String> = [
        "asc", "gpg", "jks", "kdbx", "key", "keystore", "p12", "pem", "pfx",
        "pkcs12", "ppk",
    ]

    /// Exact basenames that are credential stores by convention.
    static let secretFilenames: Set<String> = [
        ".git-credentials",
        ".htpasswd",
        ".netrc",
        ".npmrc",
        ".pgpass",
        ".pypirc",
        ".envrc",
        "credentials",
        "id_dsa",
        "id_ecdsa",
        "id_ed25519",
        "id_rsa",
        "netrc",
    ]

    /// Basename words that mark a CONFIG file as a credential store.
    ///
    /// Matched as whole words after splitting on separators and camel humps —
    /// never as substrings. `token` must not fire on `tokenizer.json`, and `key`
    /// must not fire on `keyboard.json`; both are ordinary files that a
    /// substring test would silently blind the feature to.
    static let secretNameWords: Set<String> = [
        "apikey", "credential", "credentials", "key", "keypair", "keys", "passwd",
        "password", "passwords", "privatekey", "secret", "secrets", "token",
        "tokens",
    ]

    /// Extensions where `secretNameWords` is trusted to mean "this file HOLDS
    /// credentials" rather than "this file is code ABOUT credentials".
    ///
    /// This gate is what keeps the rule narrow: `SecretsManager.swift` and
    /// `token_guard.rs` are source the user dictates about all day, and their
    /// contents are exactly the context this feature exists to supply. Only a
    /// config/data-shaped extension (or none at all) turns a name like
    /// `secrets` into a reason to withhold bytes.
    static let secretConfigExtensions: Set<String> = [
        "", "cfg", "conf", "config", "env", "envrc", "ini", "json", "plist",
        "properties", "toml", "txt", "xml", "yaml", "yml",
    ]

    /// `.env` suffixes that are checked-in TEMPLATES, not secrets. The whole
    /// point of `.env.example` is that it holds no values.
    static let nonSecretEnvSuffixes: Set<String> = [
        "dist", "example", "sample", "template",
    ]

    /// True for files whose CONTENTS are credential-shaped: read no bytes, keep
    /// the path.
    ///
    /// Distinct from `isLogLike` in intent, identical in mechanism, and the
    /// distinction matters. A log is excluded because its content is worthless;
    /// a `.env` is excluded because its content is a live credential and the
    /// polish request leaves this machine in the managed case only by the user's
    /// choice of backend — "the model is local today" is a deployment fact, not
    /// an invariant, and it is the wrong thing to bet a production token on.
    ///
    /// What survives is the PATH, which is the part that carries the context:
    /// "the agent just edited `.env.production`" is the useful sentence, and it
    /// is spelled entirely by the filename. This is why the rule is content-only
    /// and never drops the path from vocabulary or provenance.
    static func isSecretLike(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let filename = components.last else { return false }
        for component in components.dropLast()
        where secretComponents.contains(component.lowercased()) {
            return true
        }
        let lowercased = filename.lowercased()
        if secretComponents.contains(lowercased) { return true }
        if secretFilenames.contains(lowercased) { return true }

        // `.env`, `.env.local`, `.env.production` — but not `.env.example`.
        if lowercased == ".env" || lowercased == "env" { return true }
        if lowercased.hasPrefix(".env.") || lowercased.hasPrefix("env.") {
            let suffix = String(lowercased.split(separator: ".").last ?? "")
            return !nonSecretEnvSuffixes.contains(suffix)
        }

        let ext = (lowercased as NSString).pathExtension
        if !ext.isEmpty, secretExtensions.contains(ext) { return true }
        guard secretConfigExtensions.contains(ext) else { return false }
        return !basenameWords(filename).isDisjoint(with: secretNameWords)
    }

    /// A basename's lowercased words, split on separators AND camel humps.
    ///
    /// Both axes are needed: `api-keys.json` and `apiKeys.json` name the same
    /// file, and a rule that only understood one of them would be a rule the
    /// next repo walks straight past.
    static func basenameWords(_ filename: String) -> Set<String> {
        var words: Set<String> = []
        var current = ""
        func flush() {
            if !current.isEmpty { words.insert(current.lowercased()) }
            current = ""
        }
        for character in filename {
            if character == "." || character == "_" || character == "-" || character == " " {
                flush()
            } else if character.isUppercase, current.contains(where: \.isLowercase) {
                // A hump only ENDS a word when one was actually building, so
                // `RSAKey` yields `rsakey` rather than `r`/`s`/`a`/`key`.
                flush()
                current.append(character)
            } else {
                current.append(character)
            }
        }
        flush()
        return words
    }

    /// A diff with its sensitive per-file sections removed, and how many were.
    struct FilteredDiff: Equatable {
        var text: String
        var withheldFileCount: Int
    }

    /// Removes from a `git diff` every per-file section whose path is one the
    /// READ path refuses to attach (`isSecretLike` / `isLogLike`).
    ///
    /// The read filter alone is not the promise: a tracked, modified `.env`
    /// never has its file read, but its changed lines — the credential —
    /// arrive anyway inside `git diff` output. So the same path rules are
    /// applied here, per section rather than to the whole diff, because one
    /// secret file must not cost the prompt every ordinary hunk beside it.
    ///
    /// Candidate paths come from the `---`/`+++`/`rename`/`copy` lines plus
    /// the `diff --git` header, and ANY sensitive candidate withholds the
    /// section. Two asymmetries are deliberate and both fail safe:
    ///
    /// * A section whose paths cannot be parsed at all (exotic quoting with no
    ///   body lines) is withheld, never trusted.
    /// * File CONTENT can mimic `---`/`+++` lines (a deleted line reading
    ///   `-- a/.env` renders as `--- a/.env`) and at worst over-withholds.
    ///   It cannot forge a section BOUNDARY: content lines always carry a
    ///   `+`/`-`/space prefix, so `diff --git ` at column zero is git's own.
    ///
    /// Anything before the first header (rare git-level notices, e.g. unmerged
    /// paths) is kept: it is git's prose, not file content.
    static func withholdingSensitiveDiffSections(_ diff: String) -> FilteredDiff {
        guard !diff.isEmpty else { return FilteredDiff(text: diff, withheldFileCount: 0) }
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var section: [Substring] = []
        var inSection = false
        var withheld = 0

        func flushSection() {
            guard !section.isEmpty else { return }
            if shouldWithholdDiffSection(section) {
                withheld += 1
            } else {
                kept.append(contentsOf: section)
            }
            section = []
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flushSection()
                inSection = true
            }
            if inSection {
                section.append(line)
            } else {
                kept.append(line)
            }
        }
        flushSection()
        return FilteredDiff(
            text: kept.joined(separator: "\n"),
            withheldFileCount: withheld
        )
    }

    private static func shouldWithholdDiffSection(_ lines: [Substring]) -> Bool {
        let paths = diffSectionCandidatePaths(lines)
        // No parseable path is not a license, it is a parse failure.
        guard !paths.isEmpty else { return true }
        return paths.contains { isSecretLike($0) || isLogLike($0) }
    }

    /// Every repo-relative path a diff section names. Over-collection is fine
    /// (a bogus candidate can only withhold more); under-collection is what
    /// the fail-closed guard above exists for.
    private static func diffSectionCandidatePaths(_ lines: [Substring]) -> [String] {
        var paths: [String] = []
        func add(_ raw: Substring) {
            var path = String(raw)
            // `--- "a/path with specials"` — strip the quotes; any C-escapes
            // left inside only make the name unmatchable, never secret-blind:
            // git quotes for non-ASCII/controls, not for plain ASCII names
            // like `.env`.
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
                path = String(path.dropFirst().dropLast())
            }
            if path.hasPrefix("a/") || path.hasPrefix("b/") {
                path = String(path.dropFirst(2))
            }
            guard !path.isEmpty, path != "/dev/null" else { return }
            paths.append(path)
        }

        for line in lines {
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                add(line.dropFirst(4))
            } else if line.hasPrefix("rename from ") {
                add(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                add(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("copy from ") {
                add(line.dropFirst("copy from ".count))
            } else if line.hasPrefix("copy to ") {
                add(line.dropFirst("copy to ".count))
            }
        }
        // Body lines settle it for any section that has them. The header is
        // the fallback for body-less sections (mode-only changes): unquoted
        // `diff --git a/X b/X` splits unambiguously at the LAST ` b/`; a
        // quoted header is left unparsed on purpose — those sections carry no
        // content lines to lose, and guessing at C-quoting is how a filter
        // grows a bypass.
        if paths.isEmpty, let header = lines.first, header.hasPrefix("diff --git ") {
            let content = header.dropFirst("diff --git ".count)
            if !content.hasPrefix("\""),
               let split = content.range(of: " b/", options: .backwards) {
                add(content[..<split.lowerBound])
                add(content[content.index(after: split.lowerBound)...])
            }
        }
        return paths
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

    /// Minimum normalized length for a basename form to select a whole file.
    ///
    /// Short basenames (`api.ts` -> `apits`) collide with ordinary prose far too
    /// easily. Applied to every candidate form independently, so dropping the
    /// extension cannot smuggle a short stem past it.
    static let minimumBasenameMatchLength = 8

    /// The normalized basename forms of `path` that a speaker could plausibly
    /// have uttered, longest first.
    ///
    /// Two axes, and both were silently broken before — the doc example below
    /// ("the dictation view model" -> `DictationViewModel.swift`) could not
    /// actually match:
    ///
    /// * **Extension.** `normalize("DictationViewModel.swift")` is
    ///   `dictationviewmodelswift`, but a speaker who does not say "dot swift"
    ///   produces `dictationviewmodel`, and `contains` is not a prefix test. So
    ///   the extension-less STEM is a candidate alongside the full basename.
    ///   Both are kept: someone who does say "dot swift" still matches, and the
    ///   longer form wins the ranking, which is the correct outcome.
    /// * **`+`.** `RepoVocabularyMatcher.normalize` strips `.`/`/`/`_`/`-` but
    ///   NOT `+`, so `DictationViewModel+Session.swift` normalized to a form
    ///   containing a literal `+` that no transcript can ever contain — the file
    ///   was unmatchable by any utterance. A speaker either says "plus" or
    ///   elides it, so BOTH readings are emitted rather than guessed between.
    ///
    /// Deterministic: same path in, same forms in the same order out.
    static func basenameMatchForms(_ path: String) -> [String] {
        let basename = (path as NSString).lastPathComponent
        let stem = (basename as NSString).deletingPathExtension

        var spellings: [String] = []
        for raw in [basename, stem] where !raw.isEmpty {
            if raw.contains("+") {
                // Spoken, then elided. Spaces (not "") because `normalize`
                // tokenizes on whitespace: "plus" must land as its own token to
                // be a word rather than glued into the neighbouring one.
                spellings.append(raw.replacingOccurrences(of: "+", with: " plus "))
                spellings.append(raw.replacingOccurrences(of: "+", with: " "))
            } else {
                spellings.append(raw)
            }
        }

        var forms: [String] = []
        for spelling in spellings {
            let normalized = RepoVocabularyMatcher.normalize(spelling)
            guard normalized.count >= minimumBasenameMatchLength else { continue }
            guard !forms.contains(normalized) else { continue }
            forms.append(normalized)
        }
        // Longest first so the caller's `first(where:)` is the most specific
        // match. Length ties break lexicographically — never on insertion order,
        // which the `+` expansion above makes non-obvious.
        return forms.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0 < $1
        }
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
            // A file whose contents can never be attached must not spend one of
            // the `limit` candidate slots — the same reason generated and
            // log-like paths are excluded here rather than only at the read.
            // Nothing is lost by it: a tracked secret's PATH is already in
            // `trackedPaths`, which grounding reads whole.
            guard !isGeneratedOrVendored(path), !isLogLike(path), !isSecretLike(path)
            else { continue }
            // Longest-first, so this is the most specific form the speaker could
            // have used, and its length is what ranks the file below.
            guard let matched = basenameMatchForms(path).first(where: {
                normalizedTranscript.contains($0)
            }) else { continue }
            matches.append(Match(path: path, length: matched.count, index: index))
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
