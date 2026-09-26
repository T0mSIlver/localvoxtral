import Foundation

/// Runs a read-only `git` subcommand off the main actor with hard timeout /
/// output caps. Piping uses `POSIXPipeRead` (never `FileHandle.availableData`,
/// which raises an uncatchable ObjC exception on descriptor errors —
/// AGENTS.md, PR #60).
///
/// `run` is the single git entry point: it isolates the environment and hands
/// the process to `BoundedProcess`, which owns the reader thread, the
/// cap/timeout escalation and the bounded final wait. `lsFiles` and the Claude
/// repo collector (`ClaudeRepoCollector`) are both thin argument lists over it.
package enum RepoGitRunner {
    package typealias Output = BoundedProcess.Output

    /// Runs off the main actor (the caller is the @MainActor polish Task):
    /// `BoundedProcess` hops to a background queue.
    ///
    /// - Parameter arguments: the subcommand and its flags, WITHOUT the
    ///   leading `-C <root>` — this adds it, so no caller can accidentally run
    ///   git against a directory other than the one it named.
    package static func run(
        arguments: [String],
        root: String,
        timeoutSeconds: TimeInterval = 2.0,
        maxBytes: Int = 2_000_000
    ) async -> Output? {
        let gitURL = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else {
            Log.polishing.info("git runner: /usr/bin/git not executable")
            return nil
        }
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
        return await BoundedProcess.run(
            executableURL: gitURL,
            arguments: ["-C", root] + arguments,
            environment: environment,
            timeoutSeconds: timeoutSeconds,
            maxBytes: maxBytes,
            label: "git runner"
        )
    }

    package static func lsFiles(
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
}
