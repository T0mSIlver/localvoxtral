import ClaudeContextWire
import Foundation

/// Turns a harvested repo snapshot into the two things the polish request needs
/// from it: the grounding entries to pre-apply, and the excerpt to render.
///
/// The sibling of `PolishContextPreparation`, and the same contract — one
/// whole-source extraction feeding a budget-bounded render. It is a separate
/// type only because the repository is STRUCTURED: the clipboard and the screen
/// are flat buffers where "which lines" is the whole question, while a repo has
/// sections with different priorities (`ClaudeRepoContextSelection`), so the
/// render is a section allocation rather than a line selection over one string.
/// The grounding half is identical, which is why it delegates.
///
/// The work is pure and potentially large (a monorepo's tracked path list runs
/// to hundreds of thousands of characters), and the stop-commit path runs on
/// `@MainActor` — so `prepared` is `nonisolated async`, which under this
/// package's settings executes on the generic executor while remaining a
/// structured child of the caller. Same mechanism, same reason, as
/// `PolishContextPreparation.prepared`.
struct ClaudeRepoContextPreparation: Sendable, Equatable {
    /// Matched over the COMPLETE harvest — never the rendered excerpt.
    let grounding: RepoVocabularyMatcher.GroundingOutcome
    /// What actually renders into the prompt, within the granted budget.
    let excerpt: String

    static let empty = ClaudeRepoContextPreparation(grounding: .empty, excerpt: "")

    /// Prepares `snapshot` off the main actor.
    nonisolated static func prepared(
        snapshot: ClaudeRepoSnapshot,
        transcript: String,
        renderBudget: Int
    ) async -> ClaudeRepoContextPreparation {
        prepare(snapshot: snapshot, transcript: transcript, renderBudget: renderBudget)
    }

    /// The pure computation, synchronous and actor-agnostic. Exposed for tests;
    /// production callers should prefer `prepared`.
    nonisolated static func prepare(
        snapshot: ClaudeRepoSnapshot,
        transcript: String,
        renderBudget: Int
    ) -> ClaudeRepoContextPreparation {
        let groundingText = ClaudeRepoContextSelection.groundingText(snapshot: snapshot)
        guard !groundingText.isEmpty else { return .empty }

        // Grounding sees the whole harvest; rendering is what pays the budget.
        // Deliberately NOT gated on `renderBudget`: a repo whose excerpt was cut
        // to nothing still grounds the transcript from everything it harvested.
        // This is the requirement that the complete harvested terms reach
        // grounding even when the rendered excerpt is reduced — the tracked path
        // list alone routinely exceeds the entire prompt budget, and it is
        // exactly the vocabulary the feature exists to spell correctly.
        let grounding = ClipboardVocabulary.candidateOutcome(
            transcript: transcript,
            clipboardText: groundingText
        )
        let excerpt = ClaudeRepoContextSelection.render(
            snapshot: snapshot,
            transcript: transcript,
            characterCap: renderBudget,
            groundingTerms: grounding.entries.map(\.replaceWith)
        )
        return ClaudeRepoContextPreparation(grounding: grounding, excerpt: excerpt)
    }
}

/// The off-screen session facts: what the user last asked Claude, where, and
/// what it touched.
///
/// Flat text by construction, so it can go through the SHARED
/// `PolishContextPreparation` like the clipboard and the screen — there is no
/// structure here worth a second selector.
enum ClaudeSessionContextText {
    /// The `.claude` source's text for `snapshot`, or "" when the session has
    /// told us nothing worth attaching.
    ///
    /// Note what is NOT here, and stays absent: transcript contents. We never
    /// receive the path (the publisher drops it) and we would not read it if we
    /// did. For a LOCAL session the files are readable directly and are the
    /// better source anyway — a transcript is a lossy retelling of a tree we can
    /// just look at. Nor is arbitrary tool OUTPUT attached: the same argument
    /// applies, and tool output is where command results, secrets, and
    /// unbounded logs live.
    static func text(for snapshot: ClaudeSessionSnapshot) -> String {
        var parts: [String] = []
        if let workspace = snapshot.workspace {
            // `displayName`, never a path: for a remote session there IS no
            // path, and for a local one the repo block already carries the
            // relative layout. The user's home directory structure is not
            // context.
            parts.append("workspace: \(workspace.displayName)")
        }
        if let prompt = snapshot.latestPriorUserPrompt, !prompt.isEmpty {
            // The PRIOR prompt — by the time dictation reads this, the user has
            // already submitted it and is now speaking the next one. This is the
            // task they are continuing, which is why it is worth attaching at
            // all.
            parts.append("previous request to the agent: \(prompt)")
        }
        if !snapshot.recentFiles.isEmpty {
            let files = snapshot.recentFiles.map {
                "\(displayPath(of: $0.path, in: snapshot)) (\($0.kind.rawValue))"
            }
            parts.append("files the agent recently touched:\n" + files.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// A recent file's path as the prompt should see it: relative to the
    /// workspace when it is inside it, else the bare filename.
    ///
    /// Hooks report ABSOLUTE paths, and an absolute path is a description of the
    /// user's home directory layout — `/Users/someone/clients/acme-migration/…`
    /// tells a model who they work for. The repo-relative form carries every bit
    /// of context that is actually useful and none of that.
    private static func displayPath(of path: String, in snapshot: ClaudeSessionSnapshot) -> String {
        // Only a local workspace has a path to be relative TO. A remote
        // session's cwd is an opaque label by construction, so there is nothing
        // to strip and the filename is all we can honestly show.
        if let workspace = snapshot.localWorkspacePath,
           let relative = LocalWorkspacePathDisplay.relativePath(of: path, under: workspace)
        {
            return relative
        }
        return (path as NSString).lastPathComponent
    }
}

/// Reduces a raw hook path to workspace-relative for DISPLAY.
///
/// Separate from `LocalWorkspacePath.descendant`, which exists to authorize a
/// filesystem read and is strict for that reason. This one only decides what a
/// string looks like in a prompt, opens nothing, and so takes the raw path
/// directly — the trust boundary is not involved in formatting.
enum LocalWorkspacePathDisplay {
    static func relativePath(of path: String, under workspace: LocalWorkspacePath) -> String? {
        let base = LocalWorkspacePathNormalization.normalize(workspace.path)
        let candidate = LocalWorkspacePathNormalization.normalize(path)
        guard candidate.hasPrefix(base + "/") else { return nil }
        return String(candidate.dropFirst(base.count + 1))
    }
}
