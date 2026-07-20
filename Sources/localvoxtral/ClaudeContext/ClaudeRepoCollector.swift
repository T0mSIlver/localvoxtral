import ClaudeContextWire
import Darwin
import Foundation

/// What a Claude session's local repository looked like at dictation time.
///
/// Deliberately a plain value: collection (this file), selection under a
/// character budget (`ClaudeRepoContextSelection`), and rendering into the
/// prompt (`PolishContextBlock`) are three separable decisions, and welding
/// them together is what would make "harvest everything, render what fits"
/// impossible to test at either end.
///
/// Every path here is REPO-RELATIVE. The absolute tree is verified-local by
/// construction, but the user's home directory layout is not something the
/// prompt (or a log line) has any reason to carry.
struct ClaudeRepoSnapshot: Sendable, Equatable {
    /// Repo-relative path plus the bytes we retained for it.
    struct File: Sendable, Equatable {
        var path: String
        var contents: String
        /// How the session touched it, when it came from hook events. Nil for a
        /// file that is merely tracked — the transcript-matched tail.
        var touch: ClaudeFileTouchKind?
        /// True when `contents` is a prefix of a larger file.
        var isTruncated: Bool
    }

    /// Display-only workspace name (`localvoxtral`), never the absolute path.
    var workspaceName: String
    var branch: String?
    /// `git status --porcelain` lines, already repo-relative.
    var statusLines: [String]
    var stagedDiff: String
    var unstagedDiff: String
    /// Files the session read or edited, most recently touched first. These are
    /// the priority: "what I was just working on" is the single most useful
    /// thing to know when grounding dictation aimed at a coding agent.
    var activeFiles: [File]
    /// Tracked files NOT in `activeFiles`, retained for transcript matching.
    var trackedFiles: [File]
    /// Every tracked path, for vocabulary. Cheap and complete even when the
    /// contents above were capped.
    var trackedPaths: [String]
    /// Paths we saw and deliberately read NO bytes of because the name says the
    /// contents are credentials (`ClaudeRepoContentFilter.isSecretLike`).
    ///
    /// A path, not a file: there is no `contents` field here on purpose, so
    /// "attach a secret's bytes" has no value to reach for. They are kept
    /// because the path is the useful half — the user who says "fix the env
    /// production file" should have it spelled correctly, and that costs
    /// nothing but the name.
    var secretPaths: [String] = []
    var provenance: ClaudeRepoProvenance

    static let empty = ClaudeRepoSnapshot(
        workspaceName: "",
        branch: nil,
        statusLines: [],
        stagedDiff: "",
        unstagedDiff: "",
        activeFiles: [],
        trackedFiles: [],
        trackedPaths: [],
        provenance: .empty
    )

    var isEmpty: Bool {
        statusLines.isEmpty && stagedDiff.isEmpty && unstagedDiff.isEmpty
            && activeFiles.isEmpty && trackedFiles.isEmpty && trackedPaths.isEmpty
            && secretPaths.isEmpty
    }

    /// Every retained file, active first. The order IS the priority the
    /// selector inherits.
    var allFiles: [File] { activeFiles + trackedFiles }
}

/// Count-only provenance. Every field here is a number or a fixed slug; no
/// path, no file content, no branch name. This is what may be logged and put
/// in the session record (AGENTS: backend/context paths log their outcomes,
/// and content is never one of them).
struct ClaudeRepoProvenance: Sendable, Equatable {
    var trackedFileCount = 0
    var activeFileCount = 0
    var snippetFileCount = 0
    var statusLineCount = 0
    var stagedDiffCharacters = 0
    var unstagedDiffCharacters = 0
    /// Files skipped, by reason — the count-only record of what the caps and
    /// exclusions actually dropped. A silent exclusion is indistinguishable
    /// from an empty repo in the field.
    var skippedBinary = 0
    var skippedGenerated = 0
    var skippedLogs = 0
    /// Files whose contents were withheld as credential-shaped. Counted, and
    /// counted SEPARATELY from the other skips: "we declined to read your
    /// `.env`" is the one exclusion a user is most likely to want confirmed,
    /// and folding it into a generic skip counter is how a privacy promise
    /// becomes unobservable in the field.
    var skippedSecrets = 0
    /// Files whose contents were withheld because reaching them meant
    /// traversing a symlinked directory — i.e. a read the repo root does not
    /// actually contain.
    var skippedUncontained = 0
    /// Whole per-file diff sections withheld because a path they name is
    /// credential- or log-shaped — the diff-side mirror of `skippedSecrets` /
    /// `skippedLogs`. Counted per SECTION (staged and unstaged separately):
    /// the question a field log answers is "how much of the diff did we
    /// decline", not "how many distinct files".
    var withheldDiffFiles = 0
    /// Files ATTACHED in truncated form — not skipped. Kept separate from the
    /// `skipped*` counters on purpose: reporting a truncation as a skip makes a
    /// field log claim a file was dropped when its head is in the prompt, which
    /// is the opposite of the question someone reads this line to answer.
    var truncatedFiles = 0
    var deadlineExpired = false

    static let empty = ClaudeRepoProvenance()

    /// A single count-only line, safe as `.public` in a log.
    var summary: String {
        var parts = [
            "tracked:\(trackedFileCount)",
            "active:\(activeFileCount)",
            "snippets:\(snippetFileCount)",
            "status:\(statusLineCount)",
            "diff:\(stagedDiffCharacters + unstagedDiffCharacters)ch",
        ]
        if skippedBinary > 0 { parts.append("skip-binary:\(skippedBinary)") }
        if skippedGenerated > 0 { parts.append("skip-generated:\(skippedGenerated)") }
        if skippedLogs > 0 { parts.append("skip-logs:\(skippedLogs)") }
        if skippedSecrets > 0 { parts.append("skip-secrets:\(skippedSecrets)") }
        if skippedUncontained > 0 { parts.append("skip-uncontained:\(skippedUncontained)") }
        if withheldDiffFiles > 0 { parts.append("diff-withheld:\(withheldDiffFiles)") }
        if truncatedFiles > 0 { parts.append("truncated:\(truncatedFiles)") }
        if deadlineExpired { parts.append("deadline-expired") }
        return parts.joined(separator: " ")
    }
}

/// Hard bounds on one collection pass.
///
/// Every one of these exists because the alternative is unbounded: a monorepo
/// has a 400 MB tracked tree, a rebase produces a 50 MB diff, and a wedged
/// network mount makes any single `git` call take forever. The collector is
/// best-effort context for a dictation commit that the user is waiting on —
/// it must always finish, and finishing with less is always better than
/// finishing late.
struct ClaudeRepoCollectorLimits: Sendable, Equatable {
    /// Wall-clock for the WHOLE pass, enforced against an injected clock.
    var deadline: TimeInterval = 2.5
    /// Per-`git`-invocation timeout, inside the overall deadline.
    var gitTimeout: TimeInterval = 1.5
    /// Max bytes retained from one `git diff`.
    var maxDiffBytes = 200_000
    /// Max bytes retained from `git status`.
    var maxStatusBytes = 64_000
    /// Max bytes retained from `git ls-files`.
    var maxTrackedBytes = 2_000_000
    /// A single file larger than this is never read whole; only its head.
    var maxFileBytes = 128_000
    /// Head bytes retained for a file above `maxFileBytes`.
    var truncatedFileBytes = 8_000
    /// Max files whose contents are read from the hook-reported active list.
    var maxActiveFiles = 12
    /// Max additional tracked files read for transcript matching.
    var maxSnippetFiles = 24
    /// Max `git status` lines retained.
    var maxStatusLines = 200

    static let `default` = ClaudeRepoCollectorLimits()
}

/// Read-only local repository collection, gated on `LocalWorkspacePath`.
///
/// The parameter type is the whole security argument: `LocalWorkspacePath` has
/// no public initializer, and the only construction site in the codebase is
/// `ClaudeWorkspaceReference.make`, which refuses to build one for a
/// `.remote` origin. So a remote session's cwd cannot reach this function —
/// not because a check here rejects it, but because there is no way to spell
/// the call. Its derivations (`ancestor` / `descendant`) preserve the property.
protocol ClaudeRepoCollecting: Sendable {
    func collect(
        workspace: LocalWorkspacePath,
        recentFiles: [ClaudeRecentFile],
        transcript: String
    ) async -> ClaudeRepoSnapshot?
}

/// The live collector: `git` subprocesses through `RepoGitRunner` plus bounded
/// file reads, all under one deadline.
///
/// Reuses `RepoGitRunner` rather than spawning its own processes. That runner
/// already encodes a set of hard-won behaviors — `POSIXPipeRead` instead of
/// `FileHandle.availableData` (which raises an uncatchable ObjC exception and
/// aborted the app in the field, PR #60), config/environment isolation so a
/// user's `diff.external` cannot run arbitrary programs, SIGTERM-then-SIGKILL
/// escalation on cap/timeout, and a BOUNDED final wait so a child stuck in
/// uninterruptible disk-wait cannot wedge the commit. A second process
/// implementation here would be a second chance to get all of that wrong.
struct ClaudeRepoCollector: ClaudeRepoCollecting {
    private let limits: ClaudeRepoCollectorLimits
    private let files: any ClaudeLocalFileReading
    private let now: @Sendable () -> Date
    private let runGit: @Sendable (_ arguments: [String], _ root: String, _ timeout: TimeInterval, _ maxBytes: Int) async -> RepoGitRunner.Output?
    private let findGitRoot: @Sendable (_ startingAt: String) -> String?

    /// Everything live is injected — the clock, the filesystem, the git runner,
    /// and the root walk — so the whole flow is unit-testable without a real
    /// repo, a real subprocess, or a real second passing (AGENTS: no wall-clock
    /// in tests).
    init(
        limits: ClaudeRepoCollectorLimits = .default,
        files: any ClaudeLocalFileReading = ClaudeLocalFileSystem(),
        now: @escaping @Sendable () -> Date = { Date() },
        runGit: @escaping @Sendable (
            _ arguments: [String], _ root: String, _ timeout: TimeInterval, _ maxBytes: Int
        ) async -> RepoGitRunner.Output? = { arguments, root, timeout, maxBytes in
            await RepoGitRunner.run(
                arguments: arguments, root: root, timeoutSeconds: timeout, maxBytes: maxBytes
            )
        },
        findGitRoot: @escaping @Sendable (_ startingAt: String) -> String? = { path in
            RepoIndexing.findGitRoot(startingAt: path)
        }
    ) {
        self.limits = limits
        self.files = files
        self.now = now
        self.runGit = runGit
        self.findGitRoot = findGitRoot
    }

    func collect(
        workspace: LocalWorkspacePath,
        recentFiles: [ClaudeRecentFile],
        transcript: String
    ) async -> ClaudeRepoSnapshot? {
        let deadline = now().addingTimeInterval(limits.deadline)

        // The root walk starts at the verified cwd and goes UP, so the result
        // is an ancestor of a path we already trust. `ancestor(atPath:)`
        // re-proves that rather than taking the walk's word for it: a root that
        // is somehow NOT an ancestor of the cwd is a bug, and the right response
        // to a bug in a path-trust derivation is to abstain.
        guard let rootPath = findGitRoot(workspace.path),
              let root = workspace.ancestor(atPath: rootPath)
        else {
            Log.claudeContext.info("Claude repo context: session cwd is not in a git repo")
            return nil
        }

        var snapshot = ClaudeRepoSnapshot.empty
        snapshot.workspaceName = (root.path as NSString).lastPathComponent
        snapshot.branch = branch(root: root)

        // Ordered by value-per-millisecond, and every step re-checks the
        // deadline: a repo that is slow to answer yields a SMALLER snapshot,
        // never a late one. Status and diffs come before file contents because
        // "what changed" is both cheaper and more informative than any single
        // file.
        guard !isExpired(deadline) else { return finish(snapshot, expired: true) }
        snapshot.statusLines = await status(root: root, deadline: deadline)

        guard !isExpired(deadline), !Task.isCancelled else { return finish(snapshot, expired: true) }
        let staged = await diff(root: root, staged: true, deadline: deadline)
        snapshot.stagedDiff = staged.text
        snapshot.provenance.withheldDiffFiles += staged.withheldFileCount

        guard !isExpired(deadline), !Task.isCancelled else { return finish(snapshot, expired: true) }
        let unstaged = await diff(root: root, staged: false, deadline: deadline)
        snapshot.unstagedDiff = unstaged.text
        snapshot.provenance.withheldDiffFiles += unstaged.withheldFileCount

        guard !isExpired(deadline), !Task.isCancelled else { return finish(snapshot, expired: true) }
        let tracked = await trackedPaths(root: root, deadline: deadline)
        snapshot.trackedPaths = tracked

        // Active files first and unconditionally: these are the ones the hooks
        // said the session just read or edited, and they are the reason this
        // feature is worth its latency. Tracked-file snippets are the tail, and
        // only get whatever budget of TIME is left.
        let active = readActiveFiles(
            root: root,
            recentFiles: recentFiles,
            deadline: deadline
        )
        snapshot.activeFiles = active.files
        snapshot.secretPaths = active.secretPaths
        snapshot.provenance.merge(active.provenance)

        // Secret paths join the exclusion set too: their contents are settled,
        // and a snippet pass that reconsidered them would spend a candidate slot
        // to reach the same refusal.
        let activePaths = Set(active.files.map(\.path)).union(active.secretPaths)
        let snippets = readTrackedSnippets(
            root: root,
            trackedPaths: tracked,
            excluding: activePaths,
            transcript: transcript,
            deadline: deadline
        )
        snapshot.trackedFiles = snippets.files
        snapshot.provenance.merge(snippets.provenance)

        return finish(snapshot, expired: isExpired(deadline))
    }

    // MARK: - Steps

    /// The branch from `.git/HEAD`, via the existing parser — no subprocess.
    /// `RepoIndexing.branch` already handles the worktree `gitdir:` indirection
    /// and detached HEAD, which is exactly the wheel not worth reinventing.
    private func branch(root: LocalWorkspacePath) -> String? {
        RepoIndexing.branch(root: root.path)
    }

    private func status(root: LocalWorkspacePath, deadline: Date) async -> [String] {
        guard let output = await runGit(
            ["status", "--porcelain=v1", "--untracked-files=normal", "--no-color"],
            root.path,
            gitTimeout(before: deadline),
            limits.maxStatusBytes
        ) else { return [] }
        guard isUsable(output) else { return [] }
        return String(decoding: output.data, as: UTF8.self)
            .split(separator: "\n")
            .prefix(limits.maxStatusLines)
            .map { String($0) }
    }

    private func diff(
        root: LocalWorkspacePath, staged: Bool, deadline: Date
    ) async -> ClaudeRepoContentFilter.FilteredDiff {
        let none = ClaudeRepoContentFilter.FilteredDiff(text: "", withheldFileCount: 0)
        var arguments = ["diff", "--no-color", "--no-ext-diff"]
        if staged { arguments.append("--cached") }
        guard let output = await runGit(
            arguments, root.path, gitTimeout(before: deadline), limits.maxDiffBytes
        ) else { return none }
        guard isUsable(output) else { return none }
        // A diff can legitimately contain a binary blob (`git diff` says
        // "Binary files ... differ" for most, but not for every custom
        // textconv-free case). Bail on non-text rather than paste bytes into a
        // prompt.
        guard !ClaudeRepoContentFilter.looksBinary(output.data) else { return none }
        // The read path refuses a secret file's bytes; the diff of that same
        // file is those bytes by another route. Same rules, per section.
        return ClaudeRepoContentFilter.withholdingSensitiveDiffSections(
            String(decoding: output.data, as: UTF8.self)
        )
    }

    private func trackedPaths(root: LocalWorkspacePath, deadline: Date) async -> [String] {
        guard let output = await runGit(
            ["ls-files", "-z"], root.path, gitTimeout(before: deadline), limits.maxTrackedBytes
        ) else { return [] }
        guard isUsable(output) else { return [] }
        return RepoIndexing.parseNullDelimitedPaths(output.data)
    }

    /// Hook-reported touches → file contents, most recent first.
    ///
    /// A hook path is UNTRUSTED as a path even though its origin is trusted:
    /// the origin says "a local process running as this user reported this",
    /// which authorizes reading the user's own files, not reading whatever
    /// string the record happened to carry. So each one must still land inside
    /// the repo (`descendant`), be tracked by git, and clear the content
    /// filter.
    private func readActiveFiles(
        root: LocalWorkspacePath,
        recentFiles: [ClaudeRecentFile],
        deadline: Date
    ) -> FileHarvest {
        var harvest = FileHarvest()
        var skips = ClaudeRepoProvenance()
        var verifiedDirectories = Set<String>()
        var result: [ClaudeRepoSnapshot.File] = []
        var seen = Set<String>()

        for recent in recentFiles {
            guard result.count < limits.maxActiveFiles else { break }
            guard !isExpired(deadline) else {
                skips.deadlineExpired = true
                break
            }
            // The hook reports absolute paths; reduce to repo-relative and, in
            // doing so, prove the file is inside this workspace at all. A path
            // outside it (the agent read /etc/hosts, or a file in another repo)
            // is simply not this repo's context.
            guard let relative = repoRelativePath(root: root, hookPath: recent.path),
                  seen.insert(relative).inserted
            else { continue }
            // Tracked-ness is deliberately NOT required: the file the agent
            // just created is untracked by definition, and it is the single
            // most likely thing the user is about to dictate about. The
            // containment check above plus the filters in `readFile` are what
            // make this safe; being in the index is not part of that argument.
            switch readFile(
                root: root,
                relativePath: relative,
                skips: &skips,
                verifiedDirectories: &verifiedDirectories
            ) {
            case let .file(file):
                result.append(ClaudeRepoSnapshot.File(
                    path: file.path,
                    contents: file.contents,
                    touch: recent.kind,
                    isTruncated: file.isTruncated
                ))
            case .pathOnly:
                // An untracked `.env` the agent just wrote appears NOWHERE else
                // in the snapshot — not in `trackedPaths`, not in `activeFiles`.
                // Recording the path here is what keeps "the agent touched the
                // env file" groundable while its bytes stay unread.
                harvest.secretPaths.append(relative)
            case .nothing:
                continue
            }
        }
        skips.activeFileCount = result.count
        harvest.files = result
        harvest.provenance = skips
        return harvest
    }

    /// Tracked files the transcript actually mentions.
    ///
    /// Reading every tracked file in a monorepo is not an option, so this reads
    /// only files whose PATH the transcript plausibly refers to — the same
    /// normalized comparison the vocabulary matcher uses, so "the dictation
    /// view model" selects `DictationViewModel.swift` without the speaker
    /// having to pronounce the extension.
    private func readTrackedSnippets(
        root: LocalWorkspacePath,
        trackedPaths: [String],
        excluding: Set<String>,
        transcript: String,
        deadline: Date
    ) -> FileHarvest {
        var harvest = FileHarvest()
        var skips = ClaudeRepoProvenance()
        guard !transcript.isEmpty else { return harvest }

        let candidates = ClaudeRepoContentFilter.transcriptMatchedPaths(
            trackedPaths: trackedPaths,
            excluding: excluding,
            transcript: transcript,
            limit: limits.maxSnippetFiles
        )
        var verifiedDirectories = Set<String>()
        var result: [ClaudeRepoSnapshot.File] = []
        for relative in candidates {
            guard !isExpired(deadline) else {
                skips.deadlineExpired = true
                break
            }
            // A tracked secret needs no `pathOnly` bookkeeping: it is already in
            // `trackedPaths`, which grounding reads in full. Only the untracked
            // active case has a path that would otherwise be lost.
            guard case let .file(file) = readFile(
                root: root,
                relativePath: relative,
                skips: &skips,
                verifiedDirectories: &verifiedDirectories
            ) else { continue }
            result.append(file)
        }
        skips.snippetFileCount = result.count
        harvest.files = result
        harvest.provenance = skips
        return harvest
    }

    // MARK: - File reading

    /// What one filtered read produced.
    private enum FileReadOutcome {
        case file(ClaudeRepoSnapshot.File)
        /// Deliberately read no bytes; the path is still worth keeping.
        case pathOnly
        case nothing
    }

    /// One pass's harvested files, the paths it kept without contents, and what
    /// it counted. A struct rather than a wider tuple because `secretPaths` is a
    /// third thing a caller must not silently drop.
    private struct FileHarvest {
        var files: [ClaudeRepoSnapshot.File] = []
        var secretPaths: [String] = []
        var provenance = ClaudeRepoProvenance()
    }

    /// One bounded, filtered file read. Every exclusion the feature promises
    /// (generated/vendor trees, logs, secrets, binaries, oversized files, and
    /// containment) is enforced HERE, so no caller can read a file by a path
    /// that skipped a rule.
    private func readFile(
        root: LocalWorkspacePath,
        relativePath: String,
        skips: inout ClaudeRepoProvenance,
        verifiedDirectories: inout Set<String>
    ) -> FileReadOutcome {
        if ClaudeRepoContentFilter.isGeneratedOrVendored(relativePath) {
            skips.skippedGenerated += 1
            return .nothing
        }
        if ClaudeRepoContentFilter.isLogLike(relativePath) {
            // Count-only by design: a log file's CONTENT is the least useful and
            // most sensitive thing in a tree (tokens, hostnames, customer ids),
            // and its name already tells the model everything it needs.
            skips.skippedLogs += 1
            return .nothing
        }
        if ClaudeRepoContentFilter.isSecretLike(relativePath) {
            // Path-only, not dropped: the name is the context, the contents are
            // a live credential. See `ClaudeRepoContentFilter.isSecretLike`.
            skips.skippedSecrets += 1
            return .pathOnly
        }
        guard let path = containedPath(
            root: root,
            relativePath: relativePath,
            verifiedDirectories: &verifiedDirectories
        ) else {
            skips.skippedUncontained += 1
            return .nothing
        }
        // A symlink is not a regular file, and `isRegularFile` does not follow a
        // final link — so this is the last of the components, after
        // `containedPath` has cleared every directory above it.
        guard files.isRegularFile(path) else { return .nothing }

        let size = files.fileSize(path) ?? 0
        let truncated = size > limits.maxFileBytes
        let readLimit = truncated ? limits.truncatedFileBytes : limits.maxFileBytes
        guard let data = files.readFile(path, maxBytes: readLimit) else { return .nothing }
        if truncated { skips.truncatedFiles += 1 }

        guard !ClaudeRepoContentFilter.looksBinary(data) else {
            skips.skippedBinary += 1
            return .nothing
        }
        guard let contents = String(data: data, encoding: .utf8), !contents.isEmpty else {
            // Not valid UTF-8 and not caught by the NUL heuristic — some other
            // encoding, or a file that happens to be latin-1. Either way it is
            // not text we can faithfully show a model.
            skips.skippedBinary += 1
            return .nothing
        }
        return .file(ClaudeRepoSnapshot.File(
            path: relativePath,
            contents: contents,
            touch: nil,
            isTruncated: truncated
        ))
    }

    /// `relativePath` under `root`, proved reachable without traversing a single
    /// symlink — or nil.
    ///
    /// The final-component check (`isRegularFile`, which does not follow a last
    /// link) was never sufficient on its own, and the gap was not subtle: a
    /// symlinked DIRECTORY inside the repo makes `exports/current/id_rsa` a
    /// perfectly ordinary regular file whose bytes live in `~/.ssh`. Lexical
    /// containment cannot see that, because it reasons about the name and the
    /// escape happens in the inode.
    ///
    /// So every component between the root and the file is required to be a real
    /// directory. `isDirectory` is backed by `attributesOfItem`, which does NOT
    /// follow a final symlink — so a symlinked directory answers "not a
    /// directory" and the walk stops there rather than stepping through it. The
    /// root itself is not checked: it is the trusted `LocalWorkspacePath` this
    /// whole containment argument is rooted at, and the derivation
    /// (`descendant`) is what keeps every step inside it.
    ///
    /// This is a pre-read guard, not an atomic one. Between the walk and the
    /// read, a component could in principle be swapped for a link — but the
    /// attacker able to do that is a process running as the user, which can read
    /// the user's files directly and needs none of this. The realistic threat is
    /// a symlink that is simply THERE (checked into the repo, or left by a build
    /// tool), and against that this is exact.
    private func containedPath(
        root: LocalWorkspacePath,
        relativePath: String,
        verifiedDirectories: inout Set<String>
    ) -> LocalWorkspacePath? {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let filename = components.last else { return nil }

        var current = root
        for component in components.dropLast() {
            // Re-derived one component at a time so `..`, `.`, and absolute
            // spellings are rejected by `descendant` at every step rather than
            // only for the path as a whole.
            guard let next = current.descendant(relativePath: component) else { return nil }
            current = next
            // Cached per pass: 24 snippets under `Sources/localvoxtral/` is the
            // same three directories twenty-four times, and the answer cannot
            // change within one pass without the swap described above.
            if verifiedDirectories.contains(next.path) { continue }
            guard files.isDirectory(next) else { return nil }
            verifiedDirectories.insert(next.path)
        }
        return current.descendant(relativePath: filename)
    }

    /// A hook-reported absolute path reduced to repo-relative, or nil when it
    /// is not inside the repo.
    private func repoRelativePath(root: LocalWorkspacePath, hookPath: String) -> String? {
        guard hookPath.hasPrefix("/") else {
            // Already relative: accept only if it resolves inside the tree.
            return root.descendant(relativePath: hookPath).flatMap { root.relativePath(of: $0) }
        }
        // `descendant` is the only constructor available, so an absolute hook
        // path has to be re-derived through it. Strip the root prefix first,
        // which also proves containment.
        let base = LocalWorkspacePathNormalization.normalize(root.path)
        let candidate = LocalWorkspacePathNormalization.normalize(hookPath)
        guard candidate.hasPrefix(base + "/") else { return nil }
        let relative = String(candidate.dropFirst(base.count + 1))
        guard root.descendant(relativePath: relative) != nil else { return nil }
        return relative
    }

    // MARK: - Deadline

    private func isExpired(_ deadline: Date) -> Bool { now() >= deadline }

    /// The per-call git timeout, never exceeding the time actually left. A 1.5 s
    /// call started 0.2 s before the deadline must not run for 1.5 s.
    private func gitTimeout(before deadline: Date) -> TimeInterval {
        max(0.1, min(limits.gitTimeout, deadline.timeIntervalSince(now())))
    }

    /// A git run we may use the bytes of. Mirrors `RepoVocabularyService`: a
    /// clean non-zero exit is a real failure, but on timeout/cap we keep
    /// whatever was cleanly read.
    private func isUsable(_ output: RepoGitRunner.Output) -> Bool {
        if !output.timedOut, !output.capped, output.exitCode != 0 { return false }
        return true
    }

    private func finish(_ snapshot: ClaudeRepoSnapshot, expired: Bool) -> ClaudeRepoSnapshot? {
        var result = snapshot
        result.provenance.trackedFileCount = result.trackedPaths.count
        result.provenance.statusLineCount = result.statusLines.count
        result.provenance.stagedDiffCharacters = result.stagedDiff.count
        result.provenance.unstagedDiffCharacters = result.unstagedDiff.count
        if expired { result.provenance.deadlineExpired = true }
        guard !result.isEmpty else { return nil }
        Log.claudeContext.info(
            "Claude repo context collected: \(result.provenance.summary, privacy: .public)"
        )
        return result
    }
}

extension ClaudeRepoProvenance {
    /// Folds a partial pass's counters in. Counts add; the deadline flag is
    /// sticky (any expired step means the snapshot is incomplete).
    mutating func merge(_ other: ClaudeRepoProvenance) {
        activeFileCount += other.activeFileCount
        snippetFileCount += other.snippetFileCount
        skippedBinary += other.skippedBinary
        skippedGenerated += other.skippedGenerated
        skippedLogs += other.skippedLogs
        skippedSecrets += other.skippedSecrets
        skippedUncontained += other.skippedUncontained
        withheldDiffFiles += other.withheldDiffFiles
        truncatedFiles += other.truncatedFiles
        deadlineExpired = deadlineExpired || other.deadlineExpired
    }
}

/// `LocalWorkspacePath.normalize` is internal to `ClaudeContextWire`; this is
/// the app-side mirror for the one place that needs it before it has a
/// `LocalWorkspacePath` to ask.
enum LocalWorkspacePathNormalization {
    static func normalize(_ path: String) -> String {
        "/" + path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }
}

/// The live filesystem. Kept trivial on purpose: everything interesting is a
/// decision, and decisions live in the collector where they can be tested.
struct ClaudeLocalFileSystem: ClaudeLocalFileReading {
    func isDirectory(_ path: LocalWorkspacePath) -> Bool {
        metadata(path).map { ($0.st_mode & S_IFMT) == S_IFDIR } ?? false
    }

    func isRegularFile(_ path: LocalWorkspacePath) -> Bool {
        metadata(path).map { ($0.st_mode & S_IFMT) == S_IFREG } ?? false
    }

    func fileSize(_ path: LocalWorkspacePath) -> Int? {
        metadata(path).map { Int($0.st_size) }
    }

    func readFile(_ path: LocalWorkspacePath, maxBytes: Int) -> Data? {
        guard maxBytes > 0 else { return nil }
        // `.mappedIfSafe` so a large file is not copied into the heap just to
        // read its head; the prefix below is what bounds what we retain.
        guard let data = try? Data(contentsOf: path.fileURL, options: [.mappedIfSafe]) else {
            return nil
        }
        return data.count > maxBytes ? data.prefix(maxBytes) : data
    }

    /// `lstat` never follows the final component. That property is what both
    /// type checks rely on while the collector walks every path component.
    private func metadata(_ path: LocalWorkspacePath) -> stat? {
        var result = stat()
        guard path.path.withCString({ lstat($0, &result) }) == 0 else { return nil }
        return result
    }
}
