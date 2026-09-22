import Foundation

/// Everything a commit gathers before it builds the polish request: the
/// screen decision (swapped for the joined pane's socket read), the
/// repository vocabulary, the joined session's repository snapshot and text,
/// the one budget allocation over every source, the four preparations, the
/// learned-term grounding, and the merge that resolves the sources against
/// each other. Off-actor work runs where it did (under its own deadlines);
/// the result is one value the assembler and the capture read.
struct PolishContextMaterial {
    let screenDecision: TerminalScreenContextDecision
    let repoVocabularyOutcome: RepoVocabularyMatcher.GroundingOutcome
    let claudeRepoSnapshot: ClaudeRepoSnapshot?
    let claudeSessionText: String
    let screenRenderDemand: Int
    let repoRenderDemand: Int
    let allocation: [PolishContextSource: Int]
    let clipboardRenderBudget: Int
    let screenRenderBudget: Int
    let repoRenderBudget: Int
    let claudeRenderBudget: Int
    let claudeRepoPreparation: ClaudeRepoContextPreparation
    let claudeSessionPreparation: PolishContextPreparation
    let clipboardPreparation: PolishContextPreparation
    let screenPreparation: PolishContextPreparation
    let learnedProject: LearnedTermProjectResolver.Identity?
    let learnedVocabularyOutcome: RepoVocabularyMatcher.GroundingOutcome
    let merged: PolishContextGrounding.Merged

    var claudeRepoOutcome: RepoVocabularyMatcher.GroundingOutcome { claudeRepoPreparation.grounding }
    var claudeSessionOutcome: RepoVocabularyMatcher.GroundingOutcome { claudeSessionPreparation.grounding }
    var clipboardVocabularyOutcome: RepoVocabularyMatcher.GroundingOutcome { clipboardPreparation.grounding }
    var screenVocabularyOutcome: RepoVocabularyMatcher.GroundingOutcome { screenPreparation.grounding }
}

@MainActor
enum PolishContextGatherer {
    struct Input {
        let settings: SettingsStore
        let textInsertion: TextInsertionService
        let context: SessionContextResolver
        let repoVocabularyGrounding: any RepoVocabularyGrounding
        let learnedTermStore: LearnedTermStore?
        /// Nil only when polishing has no configuration, in which case
        /// nothing here has an endpoint to ground for.
        let endpointURL: URL?
        let workingText: String
        let capturedScreenDecision: TerminalScreenContextDecision
        let capturedSocketPaneStart: SocketPaneScreenCapture?
        let capturedClaudeJoin: ClaudeSessionJoin?
        let capturedClipboardContext: PolishClipboardContext?
        let templateCarriesDictionarySlot: Bool
        let needsRepoGroundingForConflictSafety: Bool
    }

    /// The two gates every repository-vocabulary read passes first: the
    /// setting, and a permitted endpoint. An injected grounding is asked only
    /// after both, so "off" and "remote" tests still prove the no-op paths.
    static func repoVocabularyGroundingIfEnabled(
        settings: SettingsStore,
        grounding: any RepoVocabularyGrounding,
        endpointURL: URL,
        transcript: String,
        repositoryRoot: RepoVocabularyRootBox?
    ) async -> RepoVocabularyMatcher.GroundingOutcome? {
        guard settings.repoVocabularyEnabled else { return nil }
        guard PolishContextClipboardReader.isPermittedContextEndpoint(
            endpointURL,
            trustedEndpointEnabled: settings.polishContextTrustedEndpointEnabled
        ) else {
            Log.polishing.info("Repo vocabulary skipped: polishing endpoint is not local")
            return nil
        }
        return await grounding.grounding(
            endpointURL: endpointURL,
            transcript: transcript,
            repositoryRoot: repositoryRoot
        )
    }

    /// Nil when the commit was cancelled at one of its checkpoints.
    static func gather(_ input: Input) async -> PolishContextMaterial? {
        let settings = input.settings
        let textInsertion = input.textInsertion
        let context = input.context
        let repoVocabularyGrounding = input.repoVocabularyGrounding
        let learnedTermStore = input.learnedTermStore
        let endpointURL = input.endpointURL
        let workingText = input.workingText
        let capturedScreenDecision = input.capturedScreenDecision
        let capturedSocketPaneStart = input.capturedSocketPaneStart
        let capturedClaudeJoin = input.capturedClaudeJoin
        let capturedClipboardContext = input.capturedClipboardContext
        let templateCarriesDictionarySlot = input.templateCarriesDictionarySlot
        let needsRepoGroundingForConflictSafety = input.needsRepoGroundingForConflictSafety

        // A herdr- or cmux-joined dictation swaps the AX screen
        // decision for the JOINED pane's clean per-pane socket
        // read. FIRST await in the Task, before the
        // repo-vocabulary hop, for the same reason the AX
        // reconcile runs pre-Task: the stop re-read must sample
        // the pane at commit, not after up to 3 s of agent output has
        // scrolled past. Everything downstream (render demand,
        // vocab grounding, the rendered block, provenance) reads
        // this decision, so the swap is complete or not at all —
        // on any pane-read failure it IS `capturedScreenDecision`,
        // which for these joins is vocabulary-only at best (the
        // authorizer still refuses raw AX attachment).
        var screenDecision = capturedScreenDecision
        if capturedSocketPaneStart != nil,
           let endpointURL = endpointURL {
            screenDecision = await SocketPaneScreenContext.reconcileAtStop(
                start: capturedSocketPaneStart,
                join: capturedClaudeJoin,
                resolver: context.claudeSessionJoinResolver,
                fallback: capturedScreenDecision,
                settingEnabled: settings.terminalScreenContextEnabled,
                endpointURL: endpointURL,
                isAccessibilityTrusted: textInsertion.isAccessibilityTrusted,
                trustedEndpointEnabled:
                    settings.polishContextTrustedEndpointEnabled
            )
        }
        // The stop-side pane read above was the LAST reader of a
        // remote herdr join's `ssh -L`; everything downstream works
        // from text already in hand. Closed through the view model,
        // which OWNS the handle — the join was consumed pre-Task,
        // so closing "the join's" tunnel here would leave the owner
        // holding a closed handle it still had to forget.
        context.closeRemoteHerdrForwards()

        // The polish request is assembled HERE, inside the Task, so
        // the opt-in repo-vocabulary indexing — whose git subprocess
        // runs OFF the main actor with a 2 s timeout — can complete
        // before the request is built without stalling the commit. On
        // timeout / no repo / feature off it is a fast no-op and the
        // request is byte-identical to the no-vocabulary path.
        var repoVocabularyOutcome = RepoVocabularyMatcher.GroundingOutcome.empty
        // The git root that pipeline resolves is also the
        // learned-terms project key. Scoped to THIS commit: an
        // abandoned pipeline that reports a root after its
        // deadline writes into a box nobody reads again, instead
        // of attributing a later dictation to the wrong project.
        let repositoryRootBox = RepoVocabularyRootBox()
        if (templateCarriesDictionarySlot || needsRepoGroundingForConflictSafety),
           let endpointURL = endpointURL,
           let outcome = await Self.repoVocabularyGroundingIfEnabled(
               settings: settings,
               grounding: repoVocabularyGrounding,
               endpointURL: endpointURL,
               transcript: workingText,
               repositoryRoot: repositoryRootBox
           )
        {
            repoVocabularyOutcome = outcome
        }

        // Clipboard vocabulary is grounded in the already
        // privacy-gated clipboard text (feature toggle ON + permitted
        // endpoint + never concealed/transient — all enforced when
        // it was captured; nil context means none of it runs).
        //
        // Matching runs over the COMPLETE retained text, never the
        // rendered excerpt: a term the user copied grounds the
        // transcript whether or not it survived excerpt selection.
        // Grounding is input-side and costs no prompt characters,
        // so it has no reason to inherit the render budget.
        //
        // Both the matching and the excerpt selection happen here,
        // together, and move OFF the main actor when the buffer is
        // large enough to be worth the hop — see
        // `PolishContextPreparation`. The render budget is resolved
        // first because it is also the inline/detached threshold.
        //
        // ONE allocation across ALL populated sources, not one per
        // source: they share a single request's prompt, so they must
        // share a single budget. Two sources each allocating from
        // `totalCharacterBudget` would each believe they had all of
        // it and together spend double.
        //
        // Only text that can actually RENDER declares a demand. The
        // screen demands nothing unless the decision is `.render`
        // (see below): `vocabularyOnly` and `drop` cost no prompt
        // characters, and letting them reserve some would starve the
        // clipboard of budget to render nothing with.
        let screenRenderDemand: Int = {
            guard case let .render(excerpt, _, _) = screenDecision else { return 0 }
            return excerpt.count
        }()

        // The joined Claude session's repository. Collected inside
        // the Task, like the repo vocabulary above and for the same
        // reason: its git subprocesses and file reads run OFF the
        // main actor under their own deadline, so a slow repo yields
        // a smaller snapshot rather than a late commit. Every gate
        // (setting, permitted endpoint, live join, LOCAL workspace)
        // is inside `claudeRepoSnapshotIfEnabled`, ahead of the
        // collector — an unjoined pane means no filesystem call at
        // all, not a collector that reads and then discards.
        var claudeRepoSnapshot: ClaudeRepoSnapshot?
        if let endpointURL = endpointURL {
            claudeRepoSnapshot = await context.claudeRepoSnapshotIfEnabled(
                join: capturedClaudeJoin,
                endpointURL: endpointURL,
                transcript: workingText
            )
        }
        guard !Task.isCancelled else { return nil }

        // The session block's text (workspace, the PRIOR prompt, the
        // files the agent touched, and a remote session's tool
        // excerpts) is flat, so it rides the shared preparation like
        // the clipboard and the screen.
        //
        // Gated through `claudeSessionTextIfEnabled` on ALL THREE of
        // the repo block's gates — current setting, currently permitted
        // endpoint, this exact join still live — not just the
        // setting. Both blocks attach the session's content, and
        // consenting to one is consenting to both; it follows that
        // withdrawing consent, or a session dying mid-sentence, must
        // stop both too. Checking only the setting here meant a dead
        // session's PRIOR PROMPT still rode to whatever endpoint was
        // configured, including a remote one.
        var claudeSessionText = ""
        if let endpointURL = endpointURL {
            claudeSessionText = context.claudeSessionTextIfEnabled(
                join: capturedClaudeJoin,
                endpointURL: endpointURL
            )
        }

        // Only RENDERABLE material declares a demand — the repo's
        // demand is what it could show, never `groundingText.count`.
        // That string is mostly `trackedPaths`, which ground but
        // never render, so counting it made a monorepo bid hundreds
        // of thousands of characters for content it would not
        // attach, and take that space from sources that would. It is
        // also computed off-actor: it walks the harvest, and this is
        // the `@MainActor` commit path.
        var repoRenderDemand = 0
        if let claudeRepoSnapshot {
            repoRenderDemand = await ClaudeRepoContextPreparation.renderDemand(
                snapshot: claudeRepoSnapshot
            )
        }

        let allocation = PolishContextBudget.allocate(demands: [
            .repository: repoRenderDemand,
            .terminal: screenRenderDemand,
            .claude: claudeSessionText.count,
            .clipboard: capturedClipboardContext?.retainedCharacterCount ?? 0,
        ])
        let clipboardRenderBudget = allocation[.clipboard] ?? 0
        let screenRenderBudget = allocation[.terminal] ?? 0
        let repoRenderBudget = allocation[.repository] ?? 0
        let claudeRenderBudget = allocation[.claude] ?? 0

        // Prepared exactly like every other source: matching over
        // the COMPLETE harvest, rendering within the grant. The gap
        // is widest here — a monorepo's tracked path list alone can
        // exceed the whole prompt budget — which is precisely why
        // grounding must not inherit the render budget. Every
        // harvested term votes; only what fits is shown.
        var claudeRepoPreparation = ClaudeRepoContextPreparation.empty
        if let claudeRepoSnapshot {
            claudeRepoPreparation = await ClaudeRepoContextPreparation.prepared(
                snapshot: claudeRepoSnapshot,
                transcript: workingText,
                renderBudget: repoRenderBudget
            )
        }
        let claudeRepoOutcome = claudeRepoPreparation.grounding

        var claudeSessionPreparation = PolishContextPreparation.empty
        if !claudeSessionText.isEmpty {
            claudeSessionPreparation = await PolishContextPreparation.prepared(
                text: claudeSessionText,
                transcript: workingText,
                renderBudget: claudeRenderBudget
            )
        }
        let claudeSessionOutcome = claudeSessionPreparation.grounding

        var clipboardPreparation = PolishContextPreparation.empty
        if let clipboardContext = capturedClipboardContext {
            clipboardPreparation = await PolishContextPreparation.prepared(
                text: clipboardContext.retainedText,
                transcript: workingText,
                renderBudget: clipboardRenderBudget
            )
        }
        let clipboardVocabularyOutcome = clipboardPreparation.grounding

        // Terminal screen context. Grounded in the screen the user
        // was looking at when they started speaking, which both
        // surviving reconciliation outcomes preserve — `.render`
        // may also show it to the model, `.vocabularyOnly` withholds
        // the excerpt but the terms the user could SEE while
        // choosing their words are still the right spellings to
        // match against. `.drop` yields nil and none of this runs.
        //
        // Matching runs over the COMPLETE sanitized screen, never
        // the excerpt: the budget can cut the rendered excerpt to
        // nothing (or bar it entirely) and the full screen still
        // grounds the transcript, exactly as it does for the
        // clipboard.
        var screenPreparation = PolishContextPreparation.empty
        if let screenText = screenDecision.vocabularyGroundingText {
            screenPreparation = await PolishContextPreparation.prepared(
                text: screenText,
                transcript: workingText,
                renderBudget: screenRenderBudget
            )
        }
        let screenVocabularyOutcome = screenPreparation.grounding

        // What earlier dictations in this project taught. No
        // harvest and no I/O beyond resolving the project: the
        // terms are already in memory, and matching them is the
        // same matcher every other source runs.
        let learnedProject = LearnedTermProjectResolver.resolve(
            repositoryRoot: repositoryRootBox.value,
            workspace: capturedClaudeJoin?.snapshot.workspace
        )
        let learnedVocabularyOutcome = await Self.learnedTermGrounding(store: learnedTermStore,
            project: learnedProject,
            transcript: workingText
        )

        guard !Task.isCancelled else { return nil }

        // Sources matched independently; the merge is what resolves
        // them against each other (agreement collapses, conflicting
        // spans abstain, and a sound-alike term is not offered for
        // a span or a term another source already rewrote).
        //
        // The terminal votes HERE, in the same single merge, rather
        // than appending its entries downstream. That is the whole
        // point: a span the screen and the clipboard read differently
        // must ABSTAIN, and a span they agree on must collapse to one
        // entry. A source that appends after the merge has silently
        // opted out of both rules and pre-applies its own reading of
        // a contested span unopposed — editing words the user did not
        // say.
        //
        // The Claude repo and session sources vote HERE too, in the
        // same single merge, for exactly the reason the terminal
        // does. They are the strongest sources on the list — a file
        // the agent just edited is better evidence of a spelling
        // than anything on the clipboard — but "strongest" is not
        // "unopposed": when the repo and the clipboard read the same
        // heard span as two DIFFERENT terms, neither is pre-applied,
        // because pre-applying the wrong bytes edits the user's words
        // into something they did not say. Both `.repository`
        // candidates share one bucket by design: the terminal-cwd
        // vocabulary and the joined session's repo are both "the repo
        // the speaker is working in", and they render under one
        // header.
        let merged = PolishContextGrounding.merge([
            PolishContextGrounding.Candidate(
                source: .repository,
                entries: repoVocabularyOutcome.entries,
                isFallbackOnly: repoVocabularyOutcome.isFallbackOnly,
                phoneticEntries: repoVocabularyOutcome.phoneticEntries,
                verificationEntries: repoVocabularyOutcome.verificationCandidates
            ),
            PolishContextGrounding.Candidate(
                source: .repository,
                entries: claudeRepoOutcome.entries,
                isFallbackOnly: claudeRepoOutcome.isFallbackOnly,
                phoneticEntries: claudeRepoOutcome.phoneticEntries,
                verificationEntries: claudeRepoOutcome.verificationCandidates
            ),
            PolishContextGrounding.Candidate(
                source: .terminal,
                entries: screenVocabularyOutcome.entries,
                isFallbackOnly: screenVocabularyOutcome.isFallbackOnly,
                phoneticEntries: screenVocabularyOutcome.phoneticEntries,
                verificationEntries: screenVocabularyOutcome.verificationCandidates
            ),
            PolishContextGrounding.Candidate(
                source: .claude,
                entries: claudeSessionOutcome.entries,
                isFallbackOnly: claudeSessionOutcome.isFallbackOnly,
                phoneticEntries: claudeSessionOutcome.phoneticEntries,
                verificationEntries: claudeSessionOutcome.verificationCandidates
            ),
            PolishContextGrounding.Candidate(
                source: .clipboard,
                entries: clipboardVocabularyOutcome.entries,
                isFallbackOnly: clipboardVocabularyOutcome.isFallbackOnly,
                phoneticEntries: clipboardVocabularyOutcome.phoneticEntries,
                verificationEntries: clipboardVocabularyOutcome.verificationCandidates
            ),
            PolishContextGrounding.Candidate(
                source: .learned,
                entries: learnedVocabularyOutcome.entries,
                isFallbackOnly: learnedVocabularyOutcome.isFallbackOnly,
                phoneticEntries: learnedVocabularyOutcome.phoneticEntries,
                verificationEntries: learnedVocabularyOutcome.verificationCandidates
            ),
        ], maxVerificationPairs: RepoVocabularyMatcher.nominationCap(
            forTranscript: workingText
        ))

        return PolishContextMaterial(
            screenDecision: screenDecision,
            repoVocabularyOutcome: repoVocabularyOutcome,
            claudeRepoSnapshot: claudeRepoSnapshot,
            claudeSessionText: claudeSessionText,
            screenRenderDemand: screenRenderDemand,
            repoRenderDemand: repoRenderDemand,
            allocation: allocation,
            clipboardRenderBudget: clipboardRenderBudget,
            screenRenderBudget: screenRenderBudget,
            repoRenderBudget: repoRenderBudget,
            claudeRenderBudget: claudeRenderBudget,
            claudeRepoPreparation: claudeRepoPreparation,
            claudeSessionPreparation: claudeSessionPreparation,
            clipboardPreparation: clipboardPreparation,
            screenPreparation: screenPreparation,
            learnedProject: learnedProject,
            learnedVocabularyOutcome: learnedVocabularyOutcome,
            merged: merged
        )
    }

    /// What this project's earlier dictations already taught, matched against
    /// the transcript by the same matcher every live source runs.
    ///
    /// No gate beyond polishing itself: a term the speaker has said three
    /// times in this project is their vocabulary, and it travels with the
    /// request the way the hand-written Names and terms list does (owner
    /// ruling, 2026-09-20 — `docs/agent/invariants.md`).
    ///
    /// Reading the terms touches no disk (`LearnedTermStore.snapshot`), and the
    /// index build and match move off the main actor like every other source's
    /// (`PolishContextPreparation`) — bounded work, but the commit path is not
    /// where bounded work belongs either.
    ///
    /// A nil `project` means the app could not establish one, so there is
    /// nothing to read: see `LearnedTermProjectResolver.resolve`.
    private static func learnedTermGrounding(
        store learnedTermStore: LearnedTermStore?,
        project: LearnedTermProjectResolver.Identity?,
        transcript: String
    ) async -> RepoVocabularyMatcher.GroundingOutcome {
        guard let learnedTermStore, let project else { return .empty }
        let terms = learnedTermStore.confirmedTerms(projectKey: project.key)
        guard !terms.isEmpty else { return .empty }
        return await Task.detached(priority: .userInitiated) {
            RepoVocabularyMatcher.groundedCandidates(
                transcript: transcript,
                vocabulary: RepoVocabulary(terms: terms, branch: nil)
            )
        }.value
    }
}
