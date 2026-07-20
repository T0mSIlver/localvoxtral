import Foundation

/// Renders a `ClaudeRepoSnapshot` into the characters the budget granted the
/// `.repository` source.
///
/// The harvest is deliberately much larger than the render. `ClaudeRepoCollector`
/// reads everything eligible; this decides what survives into the prompt. The
/// two halves are separate because they answer to different limits — the
/// collector is bounded by TIME and safety, the render by prompt characters —
/// and because everything harvested feeds grounding regardless of whether it
/// renders (see `ClaudeRepoContextPreparation`).
///
/// Pure and deterministic: same snapshot + same transcript + same cap ⇒ same
/// bytes out.
enum ClaudeRepoContextSelection {
    /// The competing sections inside the repository source's grant.
    ///
    /// Declaration order IS priority, and it encodes a claim about what helps a
    /// dictation aimed at a coding agent, most-first:
    ///
    /// 1. `activeFiles` — what the agent just read or edited. The single best
    ///    predictor of what the user is about to say, because it is literally
    ///    what they were both just looking at.
    /// 2. `diff` — what changed but is not committed. The work in progress.
    /// 3. `worktree` — branch and status. Small, and orients everything else.
    /// 4. `snippets` — tracked files the transcript happens to name. Useful,
    ///    but speculative compared to the three above.
    enum Section: String, CaseIterable, Hashable {
        case activeFiles
        case diff
        case worktree
        case snippets
    }

    /// Floor per populated section. Smaller than `PolishContextBudget`'s
    /// cross-source floor: these sections are already sharing one source's
    /// grant, and a 400-character floor across four of them would leave the
    /// active file — the section that matters most — with a fifth of what it
    /// needs. 150 characters still carries a status block or a diff hunk header
    /// plus its changed line, which is what a floor is for.
    static let sectionFloorCharacters = 150

    /// The rendered repository context under `characterCap`, or "" when nothing
    /// fits or nothing is populated.
    ///
    /// - Parameter groundingTerms: exact terms the whole-snapshot matcher
    ///   already proved transcript-relevant. Passed through to the line
    ///   selector so it does not re-derive them per line — the same contract
    ///   `PolishContextPreparation` has with `PolishContextExcerptSelector`.
    static func render(
        snapshot: ClaudeRepoSnapshot,
        transcript: String,
        characterCap: Int,
        groundingTerms: [String] = []
    ) -> String {
        guard characterCap > 0 else { return "" }

        let sections = populatedSections(snapshot: snapshot)
        guard !sections.isEmpty else { return "" }

        // Everything fits ⇒ everything is attached verbatim. This is the
        // headline case, not an optimization: a small repo with a short diff
        // should reach the model exactly as it is, with no selection machinery
        // deciding anything. The joined form is measured because THAT is what
        // gets rendered — measuring the parts and forgetting the separators is
        // how a "fits" check silently overshoots the cap.
        let verbatim = join(sections.map { ($0.key, $0.text) })
        if verbatim.count <= characterCap { return verbatim }

        let allocation = PolishContextBudget.allocate(
            demands: Dictionary(
                uniqueKeysWithValues: sections.map { ($0.key, $0.text.count) }
            ),
            order: Section.allCases,
            floor: sectionFloorCharacters,
            total: characterCap
        )

        var rendered: [(Section, String)] = []
        for section in sections {
            let grant = allocation[section.key] ?? 0
            guard grant > 0 else { continue }
            // Line selection, not truncation: the relevant hunk of a diff is
            // rarely its first lines, and a head cut of an active file is the
            // imports. `select` returns the text verbatim when it already fits
            // its grant.
            let excerpt = PolishContextExcerptSelector.select(
                text: section.text,
                transcript: transcript,
                characterCap: grant,
                groundingTerms: groundingTerms
            )
            guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            rendered.append((section.key, excerpt))
        }
        guard !rendered.isEmpty else { return "" }

        // Section headers are added by `join` AFTER selection, so the render can
        // exceed the cap that the per-section grants respected. Trim as a last
        // resort — the budget is a hard contract and no arithmetic above may be
        // trusted over the actual string.
        var output = join(rendered)
        if output.count > characterCap {
            output = String(output.prefix(characterCap))
        }
        return output
    }

    /// The characters this snapshot could actually RENDER — the demand it must
    /// declare to `PolishContextBudget`.
    ///
    /// `groundingText.count` is the wrong measure and was the bug: that string
    /// is dominated by `trackedPaths`, which are NOT a section and therefore
    /// never render a single character. A monorepo would declare a demand of
    /// hundreds of thousands of characters for material it would never show,
    /// and — because the allocator shares one total across sources — take that
    /// space from the clipboard, which had real text to render with it.
    ///
    /// Counting the render is also the only measure the allocator can honor: a
    /// grant above what a source can render is simply wasted. This is exactly
    /// the string `render` measures for its verbatim case, which is what keeps
    /// "everything fits ⇒ everything is attached" reachable.
    static func renderableCharacterCount(snapshot: ClaudeRepoSnapshot) -> Int {
        join(populatedSections(snapshot: snapshot).map { ($0.key, $0.text) }).count
    }

    /// Every section with text, in priority order.
    private static func populatedSections(
        snapshot: ClaudeRepoSnapshot
    ) -> [(key: Section, text: String)] {
        var result: [(key: Section, text: String)] = []
        for section in Section.allCases {
            let text = body(section, snapshot: snapshot)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result.append((section, text))
        }
        return result
    }

    private static func body(_ section: Section, snapshot: ClaudeRepoSnapshot) -> String {
        switch section {
        case .worktree:
            var lines: [String] = []
            if let branch = snapshot.branch { lines.append("branch: \(branch)") }
            if !snapshot.statusLines.isEmpty {
                lines.append("status:")
                lines.append(contentsOf: snapshot.statusLines)
            }
            return lines.joined(separator: "\n")
        case .diff:
            var parts: [String] = []
            if !snapshot.stagedDiff.isEmpty {
                parts.append("staged diff:\n" + snapshot.stagedDiff)
            }
            if !snapshot.unstagedDiff.isEmpty {
                parts.append("unstaged diff:\n" + snapshot.unstagedDiff)
            }
            return parts.joined(separator: "\n")
        case .activeFiles:
            return snapshot.activeFiles.map(fileBody).joined(separator: "\n")
        case .snippets:
            return snapshot.trackedFiles.map(fileBody).joined(separator: "\n")
        }
    }

    /// One file, path-labeled so the model can tell which file a line came from.
    /// A truncated file SAYS it is truncated: an unmarked cut reads as a whole
    /// file, and the model would take a severed declaration for the real one.
    private static func fileBody(_ file: ClaudeRepoSnapshot.File) -> String {
        var header = file.path
        if let touch = file.touch { header += " (\(touch.rawValue))" }
        if file.isTruncated { header += " (truncated)" }
        return "\(header):\n\(file.contents)"
    }

    private static func join(_ sections: [(Section, String)]) -> String {
        sections.map { $0.1 }.joined(separator: "\n\n")
    }

    /// The complete harvested text, for GROUNDING — never for rendering.
    ///
    /// Grounding runs over everything the collector retained, because matching
    /// is local, free, and input-side: a filename the user spoke should be
    /// spelled correctly whether or not the line carrying it survived the
    /// budget. Rendering is what the budget pays for. This is the same split
    /// `PolishContextPreparation` makes for the clipboard and the screen.
    static func groundingText(snapshot: ClaudeRepoSnapshot) -> String {
        var parts: [String] = []
        // Every tracked PATH, not just the retained files: paths are the
        // vocabulary this feature exists to get right, and they cost nothing to
        // match over even in a monorepo where almost no contents were read.
        if !snapshot.trackedPaths.isEmpty {
            parts.append(snapshot.trackedPaths.joined(separator: "\n"))
        }
        if let branch = snapshot.branch { parts.append(branch) }
        if !snapshot.statusLines.isEmpty {
            parts.append(snapshot.statusLines.joined(separator: "\n"))
        }
        if !snapshot.stagedDiff.isEmpty { parts.append(snapshot.stagedDiff) }
        if !snapshot.unstagedDiff.isEmpty { parts.append(snapshot.unstagedDiff) }
        for file in snapshot.allFiles {
            parts.append(file.path)
            parts.append(file.contents)
        }
        return parts.joined(separator: "\n")
    }
}
