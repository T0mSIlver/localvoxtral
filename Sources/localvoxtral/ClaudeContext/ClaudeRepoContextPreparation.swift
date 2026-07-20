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
/// Grounding also preserves that structure: paths are decomposed into basenames
/// and technical directory components before the remaining text is scanned.
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

    /// The `.repository` source's budget demand, computed off the main actor.
    ///
    /// The demand has to be known BEFORE `prepared` can run — the allocation it
    /// feeds is what produces `renderBudget` — so it cannot ride along inside
    /// the preparation. It gets the same off-actor treatment for the same
    /// reason: it walks the harvest, and the stop-commit path is `@MainActor`.
    nonisolated static func renderDemand(snapshot: ClaudeRepoSnapshot) async -> Int {
        ClaudeRepoContextSelection.renderableCharacterCount(snapshot: snapshot)
    }

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
        let sources = groundingSources(snapshot: snapshot)
        guard !sources.isEmpty else { return .empty }

        // Grounding sees the whole harvest; rendering is what pays the budget.
        // Deliberately NOT gated on `renderBudget`: a repo whose excerpt was cut
        // to nothing still grounds the transcript from everything it harvested.
        // This is the requirement that the complete harvested terms reach
        // grounding even when the rendered excerpt is reduced — the tracked path
        // list alone routinely exceeds the entire prompt budget, and it is
        // exactly the vocabulary the feature exists to spell correctly.
        let vocabulary = RepoVocabulary(terms: terms(from: sources), branch: snapshot.branch)
        let grounding = RepoVocabularyMatcher.groundedCandidates(
            transcript: transcript,
            vocabulary: vocabulary
        )
        let excerpt = ClaudeRepoContextSelection.render(
            snapshot: snapshot,
            transcript: transcript,
            characterCap: renderBudget,
            groundingTerms: grounding.entries.map(\.replaceWith)
        )
        return ClaudeRepoContextPreparation(grounding: grounding, excerpt: excerpt)
    }

    /// The two DISJOINT things a snapshot grounds from.
    ///
    /// The split is the point. A path list is already structured — the harvest
    /// knows precisely which strings are paths — so it goes to
    /// `RepoIndexing.buildVocabulary`, which decomposes each one into the
    /// basename and directory components a speaker can actually utter. Text is
    /// unstructured, so it goes to `ClipboardVocabulary.entities`, which
    /// RECOGNIZES identifiers in prose.
    ///
    /// Running the recognizer over the path list too — which is what a single
    /// combined grounding string forced — indexed every path twice, through a
    /// regex whose whole job is to guess at what a structured list already
    /// stated. It paid a scan over the largest string in the snapshot (a
    /// monorepo's tracked list runs to hundreds of thousands of characters) to
    /// re-derive terms the decomposition had produced exactly.
    struct GroundingSources: Sendable, Equatable {
        /// Every harvested path, structured: tracked, retained-file, and
        /// content-withheld secret paths alike.
        var paths: [String] = []
        var branch: String?
        /// The harvest MINUS the paths: status, diffs, and file contents. Where
        /// entity recognition earns its scan, because a diff hunk really does
        /// hide `PolishContextBudget.totalCharacterBudget` in running text.
        var entityText: String = ""

        var isEmpty: Bool { paths.isEmpty && branch == nil && entityText.isEmpty }
    }

    /// Splits `snapshot` into its path and non-path grounding material.
    ///
    /// Internal rather than private so the separation is directly assertable:
    /// "the recognizer never sees the path list" is the invariant, and a test
    /// that could only observe the merged term list would pass just as happily
    /// with the paths scanned twice.
    nonisolated static func groundingSources(snapshot: ClaudeRepoSnapshot) -> GroundingSources {
        var sources = GroundingSources()
        // Every tracked PATH, not just the retained files: paths are the
        // vocabulary this feature exists to get right, and they cost nothing to
        // match over even in a monorepo where almost no contents were read.
        // Secret paths are here for exactly that reason and no other — the name
        // grounds, the bytes were never read.
        sources.paths = snapshot.trackedPaths + snapshot.allFiles.map(\.path) + snapshot.secretPaths
        sources.branch = snapshot.branch

        var parts: [String] = []
        if !snapshot.statusLines.isEmpty {
            parts.append(snapshot.statusLines.joined(separator: "\n"))
        }
        if !snapshot.stagedDiff.isEmpty { parts.append(snapshot.stagedDiff) }
        if !snapshot.unstagedDiff.isEmpty { parts.append(snapshot.unstagedDiff) }
        // Contents only. A retained file's own path is already in `paths` above,
        // and re-appending it here is precisely the double indexing this split
        // exists to remove.
        for file in snapshot.allFiles where !file.contents.isEmpty {
            parts.append(file.contents)
        }
        sources.entityText = parts.joined(separator: "\n")
        return sources
    }

    /// `sources` as one ordered, de-duplicated term list.
    ///
    /// Path terms first: they are the exact, structured spellings, and
    /// `RepoVocabularyMatcher` ranks on the list it is given.
    nonisolated static func terms(from sources: GroundingSources) -> [String] {
        var terms = RepoIndexing.buildVocabularyTerms(
            paths: sources.paths, branch: sources.branch
        )
        var seen = Set(terms)
        for term in ClipboardVocabulary.entities(inExcerpt: sources.entityText)
        where seen.insert(term).inserted {
            terms.append(term)
        }
        return terms
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
    /// just look at.
    ///
    /// Tool excerpts are the one bounded exception, and only for a REMOTE
    /// session — see `remoteSnippetPart`. A local session never contributes
    /// them, because the same argument that rules out its transcript rules out
    /// its hook-quoted fragments: we can read the real file.
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
        parts.append(contentsOf: remoteSnippetPart(for: snapshot))
        return parts.joined(separator: "\n\n")
    }

    /// The remote session's tool excerpts, or nothing.
    ///
    /// REMOTE ONLY, and gated on the ORIGIN rather than on the array being
    /// non-empty. The local NDJSON wire has no snippet field, so a local
    /// snapshot's array is empty in practice — but "in practice" is not an
    /// invariant, and this one is worth an explicit check: a local session's
    /// files are on this machine, where `ClaudeRepoCollecting` reads them
    /// properly, under the collector's own caps and exclusions. A hook's quoted
    /// fragment of the same file would be a strictly worse copy that skipped
    /// every one of those rules. For a remote session there is no
    /// collector and never will be, so these excerpts are the only thing we will
    /// ever know about that tree — which is exactly why they are worth
    /// attaching, and why they were dead weight until now.
    ///
    /// Bounding is already done and not re-litigated here: the transport caps
    /// each snippet (`ClaudeSnippetLimits`, 512 bytes) and sanitizes it to an
    /// allowlist before it is ever retained, and `ClaudeSessionReducer` caps how
    /// many survive. What this adds is a LABEL per snippet, because the block is
    /// untrusted foreign text and the model is told to treat it as inert data —
    /// unlabelled quoted text from another machine reads like the user's own.
    ///
    /// This returns text, not a block: the caller's output rides the shared
    /// `PolishContextPreparation`, so these characters compete for the same
    /// `.claude` grant as the prompt and the file list, and ground over the
    /// complete retained text even when the render budget cuts them.
    private static func remoteSnippetPart(for snapshot: ClaudeSessionSnapshot) -> [String] {
        guard !snapshot.origin.isLocalAuthenticated else { return [] }
        guard !snapshot.recentSnippets.isEmpty else { return [] }
        let rendered = snapshot.recentSnippets.map { snippet in
            "[\(snippet.label) (\(snippet.kind.rawValue))]\n\(snippet.text)"
        }
        return [
            "excerpts of what the agent's tools recently handled on the remote host:\n"
                + rendered.joined(separator: "\n\n")
        ]
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
