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
// prompt-context only (no deterministic auto-replacement). Three separable,
// independently testable pieces + a TTL cache do the amortizing:
//   1. `TerminalWorkingDirectoryResolver` — terminal window title -> cwd
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

    struct FuzzyCandidate: Sendable {
        let term: String
        let normalizedCharacters: [Character]
    }

    init(terms: [String], branch: String?) {
        self.terms = terms
        self.branch = branch
        var exact: [String: String] = [:]
        var buckets: [Int: [FuzzyCandidate]] = [:]
        for term in terms {
            let normalized = RepoVocabularyMatcher.normalize(term)
            guard normalized.count >= RepoVocabularyMatcher.minNormalizedLength else { continue }
            if exact[normalized] == nil { exact[normalized] = term }
            if normalized.count >= RepoVocabularyMatcher.fuzzyMinNormalizedLength {
                buckets[normalized.count, default: []].append(
                    FuzzyCandidate(term: term, normalizedCharacters: Array(normalized))
                )
            }
        }
        self.exactIndex = exact
        self.fuzzyBuckets = buckets
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
        return RepoVocabulary(terms: terms, branch: branch)
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

/// Runs `git ls-files -z` off the main actor with hard timeout / output caps.
/// Piping uses `POSIXPipeRead` (never `FileHandle.availableData`, which raises
/// an uncatchable ObjC exception on descriptor errors — AGENTS.md, PR #60).
enum RepoGitRunner {
    struct Output: Sendable {
        let data: Data
        let exitCode: Int32
        let timedOut: Bool
        let capped: Bool
    }

    /// Async wrapper: hops to a background queue so the blocking Process run
    /// never touches the main actor (the caller is the @MainActor polish Task).
    static func lsFiles(
        root: String,
        timeoutSeconds: TimeInterval = 2.0,
        maxBytes: Int = 2_000_000
    ) async -> Output? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Output?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: runBlocking(root: root, timeoutSeconds: timeoutSeconds, maxBytes: maxBytes)
                )
            }
        }
    }

    private static func runBlocking(root: String, timeoutSeconds: TimeInterval, maxBytes: Int) -> Output? {
        let gitURL = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else {
            Log.polishing.info("Repo vocabulary: /usr/bin/git not executable")
            return nil
        }

        let process = Process()
        process.executableURL = gitURL
        process.arguments = ["-C", root, "ls-files", "-z"]
        // Determinism against user git config: no global/system config (ls-files
        // runs no hooks/aliases, this pins it) and never a credential prompt.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
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
            Log.polishing.info("Repo vocabulary: git ls-files failed to launch")
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
                "Repo vocabulary: git ls-files did not exit after kill; abandoning"
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

    /// The full title -> cwd -> vocabulary -> matched-entries pipeline for one
    /// commit. Everything here may block (FS stats on the title's path
    /// candidates — possibly a stale network mount —, the git subprocess, the
    /// n-gram match over a large vocabulary), so the view model runs this
    /// inside a detached task; only the AX title read stays on the main actor.
    static func entries(
        forWindowTitle title: String,
        transcript: String,
        cache: RepoVocabularyCache
    ) async -> [ReplacementEntry]? {
        guard let workingDirectory = TerminalWorkingDirectoryResolver
            .resolveWorkingDirectory(fromWindowTitle: title)
        else {
            // Shape is class-mapped (letters->a, digits->9), never content —
            // safe as .public, and makes the NEXT field failure of this kind
            // self-diagnosing (T6 was invisible without it).
            Log.polishing.info(
                "Repo vocabulary: no working directory resolved from window title (shape: \(TerminalWorkingDirectoryResolver.titleShape(title), privacy: .public))"
            )
            return nil
        }
        guard let vocabulary = await vocabulary(
            forWorkingDirectory: workingDirectory, cache: cache
        ) else {
            return nil
        }
        let entries = RepoVocabularyMatcher.candidateEntries(
            transcript: transcript, vocabulary: vocabulary
        )
        if entries.isEmpty {
            // Static string + no content: the LAST silent skip on this path.
            // Every skip reason is .info — .debug is not persisted by the
            // unified log store, which made a field no-attach undiagnosable
            // (2026-07-11, Ghostty).
            Log.polishing.info("Repo vocabulary: no transcript-relevant matches")
            return nil
        }
        return entries
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

    // MARK: - Internals

    /// One matched (term, transcript n-gram) pairing.
    private struct Hit {
        let term: String
        let normalizedLength: Int
        let position: Int
        let spoken: String
        let exact: Bool
    }

    private static let nonAlphanumericEdges = CharacterSet.alphanumerics.inverted

    /// Splits on whitespace and trims each word of leading/trailing
    /// non-alphanumerics (STT-sprinkled commas/periods) so the normalized form
    /// and the "as spoken" match string are both clean.
    private static func tokenize(_ transcript: String) -> [String] {
        transcript
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: nonAlphanumericEdges) }
            .filter { !$0.isEmpty }
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
    /// dictionary line must stay single-line.
    static func sanitizedTerm(_ term: String) -> String {
        PolishContextClipboardReader.sanitizeControlCharacters(term)
            .filter { $0 != "\n" && $0 != "\t" }
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

/// Clipboard entities join the sanctioned-rewrite pipeline (field regression,
/// 2026-07-11): the clipboard polish-context excerpt already tells the model
/// the exact spelling of a copied identifier, but when the STT's misheard form
/// was itself a protected token (`manager.swift` for a dictated
/// "user session manager dot swift", clipboard holding
/// `UserSessionManager.swift`), the token guard deterministically DISCARDED
/// the model's correct rewrite. Extracting the excerpt's code-like entities
/// (the guard's OWN recognizer — never a second grammar), matching transcript
/// n-grams against them exactly like repo vocabulary, and registering the
/// matches as sanctioned pairs makes that correction survive the guard.
///
/// Pure functions; all privacy gating (feature toggle, loopback endpoint,
/// concealed/transient pasteboard) already happened when the excerpt was
/// captured — this type never touches the pasteboard.
enum ClipboardVocabulary {
    /// Ordered, de-duplicated code-like entities in `excerpt`, recognized by
    /// `PolishTokenGuard.protectedTokens` (backtick spans, dotted filenames,
    /// paths, flags, env vars, URLs, hashes, versions). Backtick spans are
    /// unwrapped to their inner text: the vocabulary term is the identifier,
    /// not its markdown decoration.
    static func entities(inExcerpt excerpt: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in PolishTokenGuard.protectedTokens(in: excerpt) {
            var term = token
            if term.hasPrefix("`"), term.hasSuffix("`"), term.count > 2 {
                term = String(term.dropFirst().dropLast())
            }
            guard !term.isEmpty, seen.insert(term).inserted else { continue }
            result.append(term)
        }
        return result
    }

    /// The transcript-relevant clipboard entities as replacement entries, via
    /// the exact matcher repo vocabulary uses (same n-gram windows, same
    /// normalization, same fuzzy tier, same cap). Empty when the excerpt holds
    /// no code-like entities or none matches the transcript.
    static func candidateEntries(
        transcript: String,
        excerpt: String
    ) -> [ReplacementEntry] {
        let terms = entities(inExcerpt: excerpt)
        guard !terms.isEmpty else { return [] }
        let vocabulary = RepoVocabulary(terms: terms, branch: nil)
        return RepoVocabularyMatcher.candidateEntries(
            transcript: transcript,
            vocabulary: vocabulary
        )
    }
}
