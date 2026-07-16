import ClaudeContextWire
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
        snapshot.stagedDiff = await diff(root: root, staged: true, deadline: deadline)

        guard !isExpired(deadline), !Task.isCancelled else { return finish(snapshot, expired: true) }
        snapshot.unstagedDiff = await diff(root: root, staged: false, deadline: deadline)

        guard !isExpired(deadline), !Task.isCancelled else { return finish(snapshot, expired: true) }
        let tracked = await trackedPaths(root: root, deadline: deadline)
        snapshot.trackedPaths = tracked

        // Active files first and unconditionally: these are the ones the hooks
        // said the session just read or edited, and they are the reason this
        // feature is worth its latency. Tracked-file snippets are the tail, and
        // only get whatever budget of TIME is left.
        let (active, activeSkips) = readActiveFiles(
            root: root,
            recentFiles: recentFiles,
            deadline: deadline
        )
        snapshot.activeFiles = active
        snapshot.provenance.merge(activeSkips)

        let activePaths = Set(active.map(\.path))
        let (snippets, snippetSkips) = readTrackedSnippets(
            root: root,
            trackedPaths: tracked,
            excluding: activePaths,
            transcript: transcript,
            deadline: deadline
        )
        snapshot.trackedFiles = snippets
        snapshot.provenance.merge(snippetSkips)

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

    private func diff(root: LocalWorkspacePath, staged: Bool, deadline: Date) async -> String {
        var arguments = ["diff", "--no-color", "--no-ext-diff"]
        if staged { arguments.append("--cached") }
        guard let output = await runGit(
            arguments, root.path, gitTimeout(before: deadline), limits.maxDiffBytes
        ) else { return "" }
        guard isUsable(output) else { return "" }
        // A diff can legitimately contain a binary blob (`git diff` says
        // "Binary files ... differ" for most, but not for every custom
        // textconv-free case). Bail on non-text rather than paste bytes into a
        // prompt.
        guard !ClaudeRepoContentFilter.looksBinary(output.data) else { return "" }
        return String(decoding: output.data, as: UTF8.self)
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
    ) -> ([ClaudeRepoSnapshot.File], ClaudeRepoProvenance) {
        var result: [ClaudeRepoSnapshot.File] = []
        var skips = ClaudeRepoProvenance()
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
            guard let file = readFile(root: root, relativePath: relative, skips: &skips) else {
                continue
            }
            result.append(ClaudeRepoSnapshot.File(
                path: file.path,
                contents: file.contents,
                touch: recent.kind,
                isTruncated: file.isTruncated
            ))
        }
        skips.activeFileCount = result.count
        return (result, skips)
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
    ) -> ([ClaudeRepoSnapshot.File], ClaudeRepoProvenance) {
        var skips = ClaudeRepoProvenance()
        guard !transcript.isEmpty else { return ([], skips) }

        let candidates = ClaudeRepoContentFilter.transcriptMatchedPaths(
            trackedPaths: trackedPaths,
            excluding: excluding,
            transcript: transcript,
            limit: limits.maxSnippetFiles
        )
        var result: [ClaudeRepoSnapshot.File] = []
        for relative in candidates {
            guard !isExpired(deadline) else {
                skips.deadlineExpired = true
                break
            }
            guard let file = readFile(root: root, relativePath: relative, skips: &skips) else {
                continue
            }
            result.append(file)
        }
        skips.snippetFileCount = result.count
        return (result, skips)
    }

    // MARK: - File reading

    /// One bounded, filtered file read. Every exclusion the feature promises
    /// (generated/vendor trees, logs, binaries, oversized files) is enforced
    /// HERE, so no caller can read a file by a path that skipped a rule.
    private func readFile(
        root: LocalWorkspacePath,
        relativePath: String,
        skips: inout ClaudeRepoProvenance
    ) -> ClaudeRepoSnapshot.File? {
        if ClaudeRepoContentFilter.isGeneratedOrVendored(relativePath) {
            skips.skippedGenerated += 1
            return nil
        }
        if ClaudeRepoContentFilter.isLogLike(relativePath) {
            // Count-only by design: a log file's CONTENT is the least useful and
            // most sensitive thing in a tree (tokens, hostnames, customer ids),
            // and its name already tells the model everything it needs.
            skips.skippedLogs += 1
            return nil
        }
        guard let path = root.descendant(relativePath: relativePath) else { return nil }
        // Symlinks are not followed: lexical containment says where the NAME
        // points, not where the inode does, and a tracked symlink to
        // `~/.ssh/id_rsa` is a legal thing to have in a repo.
        guard files.isRegularFile(path) else { return nil }

        let size = files.fileSize(path) ?? 0
        let truncated = size > limits.maxFileBytes
        let readLimit = truncated ? limits.truncatedFileBytes : limits.maxFileBytes
        guard let data = files.readFile(path, maxBytes: readLimit) else { return nil }
        if truncated { skips.truncatedFiles += 1 }

        guard !ClaudeRepoContentFilter.looksBinary(data) else {
            skips.skippedBinary += 1
            return nil
        }
        guard let contents = String(data: data, encoding: .utf8), !contents.isEmpty else {
            // Not valid UTF-8 and not caught by the NUL heuristic — some other
            // encoding, or a file that happens to be latin-1. Either way it is
            // not text we can faithfully show a model.
            skips.skippedBinary += 1
            return nil
        }
        return ClaudeRepoSnapshot.File(
            path: relativePath,
            contents: contents,
            touch: nil,
            isTruncated: truncated
        )
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
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func isDirectory(_ path: LocalWorkspacePath) -> Bool {
        attributes(path)?[.type] as? FileAttributeType == .typeDirectory
    }

    func isRegularFile(_ path: LocalWorkspacePath) -> Bool {
        attributes(path)?[.type] as? FileAttributeType == .typeRegular
    }

    func fileSize(_ path: LocalWorkspacePath) -> Int? {
        (attributes(path)?[.size] as? NSNumber)?.intValue
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

    /// `attributesOfItem` does NOT follow a final symlink, which is the
    /// property both `isRegularFile` and `isDirectory` rely on to keep a
    /// tracked link out of the tree from being read as a file.
    private func attributes(_ path: LocalWorkspacePath) -> [FileAttributeKey: Any]? {
        try? fileManager.attributesOfItem(atPath: path.path)
    }
}
