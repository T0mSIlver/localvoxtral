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
// `RepoVocabulary`, `RepoIndexing`, `RepoVocabularyMatcher` and
// `ClipboardVocabulary` are Foundation-only and live in localvoxtralCore.

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
/// the `.git/HEAD` or `.github/dictation.md` mtime changes. `Mutex`-guarded per
/// repo conventions (no actors). The clock is injected at every call so tests
/// never touch wall-clock.
final class RepoVocabularyCache: Sendable {
    private struct Cached {
        let vocabulary: RepoVocabulary
        let headModificationDate: Date?
        let dictationFileModificationDate: Date?
        let cachedAt: Date
    }

    private let ttl: TimeInterval
    private let storage = Mutex<[String: Cached]>([:])

    init(ttl: TimeInterval = 300) {
        self.ttl = ttl
    }

    /// The cached vocabulary for `root` when still within TTL AND both mtimes
    /// are unchanged, else nil (a fresh index is required).
    func lookup(
        root: String,
        now: Date,
        currentHeadModificationDate: Date?,
        currentDictationFileModificationDate: Date? = nil
    ) -> RepoVocabulary? {
        storage.withLock { store in
            guard let cached = store[root] else { return nil }
            if now.timeIntervalSince(cached.cachedAt) > ttl { return nil }
            if cached.headModificationDate != currentHeadModificationDate { return nil }
            if cached.dictationFileModificationDate != currentDictationFileModificationDate { return nil }
            return cached.vocabulary
        }
    }

    func insert(
        root: String,
        vocabulary: RepoVocabulary,
        headModificationDate: Date?,
        dictationFileModificationDate: Date? = nil,
        now: Date
    ) {
        storage.withLock { store in
            store[root] = Cached(
                vocabulary: vocabulary,
                headModificationDate: headModificationDate,
                dictationFileModificationDate: dictationFileModificationDate,
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
        let dictationFileModificationDate = DictationTermsFile.modificationDate(
            root: root, fileManager: fileManager
        )
        if let cached = cache.lookup(
            root: root,
            now: now(),
            currentHeadModificationDate: headModificationDate,
            currentDictationFileModificationDate: dictationFileModificationDate
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
        // The file's terms come first: where one normalizes like a path-derived
        // term, the matcher keeps the first, and the spelling someone wrote
        // down beats the one inferred from a file name. They skip
        // `isTechnicalTerm` because a person chose them; "Voxtral" has no
        // machine-checkable signal and is exactly what the file is for.
        let fileTerms = DictationTermsFile.read(root: root, fileManager: fileManager)
        if !fileTerms.isEmpty {
            Log.polishing.info(
                "Repo vocabulary: \(fileTerms.count, privacy: .public) term(s) from \(DictationTermsFile.relativePath, privacy: .public)"
            )
        }
        var seen = Set(fileTerms)
        let terms = fileTerms + RepoIndexing.buildVocabularyTerms(paths: paths, branch: branch)
            .filter { seen.insert($0).inserted }
        guard !terms.isEmpty else {
            Log.polishing.info("Repo vocabulary: repo yielded no technical terms")
            return nil
        }
        let vocabulary = RepoVocabulary(terms: terms, branch: branch)
        cache.insert(
            root: root,
            vocabulary: vocabulary,
            headModificationDate: headModificationDate,
            dictationFileModificationDate: dictationFileModificationDate,
            now: now()
        )
        return vocabulary
    }

    /// The full focused-title/terminal-PID -> git root -> vocabulary -> matched
    /// entries pipeline for one commit. A joined local session's workspace,
    /// when there is one, decides alone: the join named the session the user
    /// is talking to, which a title or a process walk can only approximate,
    /// and it is the only signal a Claude Desktop dictation has. Without one,
    /// the focused title is tier 1: it can soundly distinguish a focused tab
    /// even when other tabs use other repos. When it contains no usable repo
    /// path, tier 2 walks terminal descendants and proceeds only if every
    /// process CWD maps to one root. Everything here may block, so the view
    /// model runs it inside a detached task; only the AX title read stays on
    /// the main actor.
    static func entries(
        forWindowTitle title: String?,
        terminalApplicationPID: pid_t? = nil,
        joinedWorkspaceDirectory: String? = nil,
        transcript: String,
        cache: RepoVocabularyCache,
        fileManager: FileManager = .default,
        processSnapshot: @Sendable () -> [TerminalDescendantProcessResolver.ProcessRecord] = {
            TerminalDescendantProcessResolver.liveProcessSnapshot()
        },
        workingDirectoryForPID: @Sendable (pid_t) -> String? = {
            TerminalDescendantProcessResolver.liveWorkingDirectory(forPID: $0)
        },
        rootSink: (@Sendable (String?) -> Void)? = nil
    ) async -> RepoVocabularyMatcher.GroundingOutcome? {
        var gitRoot: String?
        if let joinedWorkspaceDirectory {
            gitRoot = RepoIndexing.findGitRoot(
                startingAt: joinedWorkspaceDirectory, fileManager: fileManager
            )
            if gitRoot != nil {
                Log.polishing.info("Repo vocabulary: resolved git root from the joined session's workspace")
            }
        } else if let title,
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

        if gitRoot == nil, joinedWorkspaceDirectory == nil, let terminalApplicationPID {
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

        // Reported before the index and the match, and whatever they return:
        // the caller uses it to attribute what the dictation LEARNS to a
        // project, and a repo whose `ls-files` timed out is still the repo the
        // speaker was working in. This is the only place a git root is
        // resolved off the main actor, which is why the learned-terms project
        // key is taken from here rather than walking the filesystem again on
        // the commit path.
        //
        // Nil is reported too, and means something different from staying
        // silent: the resolution ran and this is not a repository. The tier-2
        // ambiguity exits above return BEFORE this line on purpose — several
        // repos under one terminal is not "no repository", it is "we do not
        // know", and the caller must be able to tell those apart.
        rootSink?(gitRoot)

        guard let gitRoot else {
            // Shape is class-mapped (letters->a, digits->9), never content —
            // safe as .public, and makes the NEXT field failure of this kind
            // self-diagnosing (T6 was invisible without it).
            if joinedWorkspaceDirectory != nil {
                Log.polishing.info("Repo vocabulary: the joined session's workspace is not in a git repo")
            } else if let title {
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
