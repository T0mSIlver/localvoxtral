import Foundation

/// Turns the merged grounding material and the prompt templates into the
/// polish request: the vocabulary sections in the `{{replacement_dictionary}}`
/// slot, the pre-applied working text, the reference-context blocks and the
/// provenance summary. Pure: everything it needs is in `Input`, and the
/// request it builds is pinned byte for byte by `PolishRequestGoldenTests`.
enum PolishRequestAssembler {
    struct Input {
        let merged: PolishContextGrounding.Merged
        let templateCarriesDictionarySlot: Bool
        let replacementDictionaryPrompt: String
        let workingText: String
        let clipboardPayload: String?
        let promptTemplates: LLMPromptTemplates
        let screenDecision: TerminalScreenContextDecision
        let claudeRepoSnapshot: ClaudeRepoSnapshot?
        let claudeRepoPreparation: ClaudeRepoContextPreparation
        let claudeSessionPreparation: PolishContextPreparation
        let clipboardPreparation: PolishContextPreparation
        let screenPreparation: PolishContextPreparation
        let capturedClaudeJoin: ClaudeSessionJoin?
        let capturedClipboardContext: PolishClipboardContext?
        let repoRenderBudget: Int
        let screenRenderBudget: Int
        let claudeRenderBudget: Int
        let clipboardRenderBudget: Int
        /// Agent proposals among the learned entries (#609): pre-applied,
        /// but not listed under the learned header, which tells the model
        /// the speaker has used the spelling before.
        var learnedProposals: Set<String> = []
    }

    struct Assembly {
        let request: LLMPolishingRequest
        let groundedWorkingText: String
        let polishContextSummary: String?
        let repoBlock: PolishContextBlock?
        let screenBlock: PolishContextBlock?
        let claudeBlock: PolishContextBlock?
        let clipboardBlock: PolishContextBlock?
        let repoVocabularyCount: Int
        let clipboardVocabularyCount: Int
    }

    /// The request `assemble` builds when nothing grounds the polish: no
    /// vocabulary, no pre-applied spelling, no context block. Early polish
    /// (#709) sends it for each piece, and the stop reuses the pieces only
    /// when its own assembled request equals this one for the whole text.
    static func bareRequest(workingText: String, templates: LLMPromptTemplates) -> LLMPolishingRequest {
        LLMPolishingRequest(
            inputText: workingText,
            systemPrompt: templates.systemContent,
            userPrompts: templates.renderedUserPrompts(inputText: workingText, replacementDictionary: "")
        )
    }

    static func assemble(_ input: Input) -> Assembly {
        let merged = input.merged
        let templateCarriesDictionarySlot = input.templateCarriesDictionarySlot
        let workingText = input.workingText
        let clipboardPayload = input.clipboardPayload
        let promptTemplates = input.promptTemplates
        let screenDecision = input.screenDecision
        let claudeRepoSnapshot = input.claudeRepoSnapshot
        let claudeRepoPreparation = input.claudeRepoPreparation
        let claudeSessionPreparation = input.claudeSessionPreparation
        let clipboardPreparation = input.clipboardPreparation
        let screenPreparation = input.screenPreparation
        let capturedClaudeJoin = input.capturedClaudeJoin
        let capturedClipboardContext = input.capturedClipboardContext
        let repoRenderBudget = input.repoRenderBudget
        let screenRenderBudget = input.screenRenderBudget
        let claudeRenderBudget = input.claudeRenderBudget
        let clipboardRenderBudget = input.clipboardRenderBudget
        var replacementDictionarySection = input.replacementDictionaryPrompt

        let learnedVocabularyEntries = merged.entries(from: .learned)
            .filter { !input.learnedProposals.contains($0.replaceWith) }
        let repoVocabularyEntries = merged.entries(from: .repository)
        let clipboardVocabularyEntries = merged.entries(from: .clipboard)
        let screenVocabularyEntries = merged.entries(from: .terminal)
        let claudeVocabularyEntries = merged.entries(from: .claude)
        let repoVocabularyCount = repoVocabularyEntries.count
        let clipboardVocabularyCount = clipboardVocabularyEntries.count
        let screenVocabularyCount = screenVocabularyEntries.count
        let claudeVocabularyCount = claudeVocabularyEntries.count

        // Sections are rendered from the MERGED entries, never the
        // per-source matches: a span the merge abstained on must
        // not survive as a prompt hint the model could apply by
        // hand. Appended to the replacement-dictionary section so
        // the entries land in the `{{replacement_dictionary}}` slot
        // both profiles already carry — dynamic-suffix side of the
        // prompt-cache split, never the cached prefix.
        if !repoVocabularyEntries.isEmpty, templateCarriesDictionarySlot {
            replacementDictionarySection = RepoVocabularyMatcher.appendedPromptSection(
                base: replacementDictionarySection,
                entries: repoVocabularyEntries
            )
            Log.polishing.info(
                "Repo vocabulary attached: \(repoVocabularyCount, privacy: .public) entries"
            )
        }

        if !clipboardVocabularyEntries.isEmpty, templateCarriesDictionarySlot {
            replacementDictionarySection =
                RepoVocabularyMatcher.appendedPromptSection(
                    base: replacementDictionarySection,
                    entries: clipboardVocabularyEntries,
                    header: RepoVocabularyMatcher.clipboardVocabularyHeader
                )
        }
        if clipboardVocabularyCount > 0 {
            // Counts only — entity content is clipboard content.
            Log.polishing.info(
                "Clipboard vocabulary attached: clipboard-vocab:\(clipboardVocabularyCount, privacy: .public)"
            )
        }

        // Rendered from the MERGED entries like every other source —
        // a span the merge abstained on must not reappear here as a
        // prompt hint. Hint entries need the dictionary slot;
        // pre-application does not.
        if !screenVocabularyEntries.isEmpty, templateCarriesDictionarySlot {
            replacementDictionarySection =
                RepoVocabularyMatcher.appendedPromptSection(
                    base: replacementDictionarySection,
                    entries: screenVocabularyEntries,
                    header: RepoVocabularyMatcher.terminalScreenVocabularyHeader
                )
        }
        if screenVocabularyCount > 0 {
            // Counts only — entity content is screen content.
            Log.polishing.info(
                "Terminal screen vocabulary attached: screen-vocab:\(screenVocabularyCount, privacy: .public)"
            )
        }

        if !claudeVocabularyEntries.isEmpty, templateCarriesDictionarySlot {
            replacementDictionarySection =
                RepoVocabularyMatcher.appendedPromptSection(
                    base: replacementDictionarySection,
                    entries: claudeVocabularyEntries,
                    header: RepoVocabularyMatcher.claudeSessionVocabularyHeader
                )
        }
        if claudeVocabularyCount > 0 {
            // Counts only — entity content is session content.
            Log.polishing.info(
                "Claude session vocabulary attached: claude-vocab:\(claudeVocabularyCount, privacy: .public)"
            )
        }

        if !learnedVocabularyEntries.isEmpty, templateCarriesDictionarySlot {
            replacementDictionarySection =
                RepoVocabularyMatcher.appendedPromptSection(
                    base: replacementDictionarySection,
                    entries: learnedVocabularyEntries,
                    header: RepoVocabularyMatcher.learnedVocabularyHeader
                )
        }
        if !learnedVocabularyEntries.isEmpty {
            // Counts only — the terms are the speaker's own words.
            Log.polishing.info(
                "Learned vocabulary attached: learned-vocab:\(learnedVocabularyEntries.count, privacy: .public)"
            )
        }

        // Render from the MERGED pairs only: a span the merge
        // pre-applied or abstained-and-dropped must not reappear.
        // These remain untrusted suggestions for the model to
        // verify against context, deliberately never pre-applied.
        if !merged.verificationPairs.isEmpty && templateCarriesDictionarySlot {
            replacementDictionarySection =
                RepoVocabularyMatcher.appendedVerificationSection(
                    base: replacementDictionarySection,
                    pairs: merged.verificationPairs
                )
            Log.polishing.info(
                "Verification candidates attached: \(merged.verificationPairs.count, privacy: .public)"
            )
        }

        // Exact repo/clipboard bytes and their ASR spans have
        // already been selected by the deterministic matcher. Put
        // those bytes into the working text before the single LLM
        // call instead of relying on a generative model to copy a
        // prompt hint exactly. The same mappings remain in the
        // prompt as provenance/context. Boundary checks make this
        // a no-op if a recorded span is no longer independently
        // replaceable.
        // `merged.all`, never a concatenation of the per-source
        // entries: the merge is what already resolved agreement and
        // conflict ACROSS sources, and re-assembling its inputs by
        // hand would reintroduce exactly the duplicates and
        // contested spans it dropped. Terminal entries are in here
        // because the terminal is a candidate in the merge above.
        let groundingEntries = merged.all
        let groundedWorkingText: String
        if clipboardPayload != nil {
            // The payload placeholder is a commit-control token,
            // not dictation. Ground every surrounding segment but
            // keep each placeholder byte-exact so its integrity
            // count and final substitution cannot be bypassed by a
            // vocabulary term with the same normalized body.
            groundedWorkingText = workingText
                .components(separatedBy: ClipboardPayloadMacro.placeholder)
                .map {
                    RepoVocabularyMatcher.preapplying(
                        entries: groundingEntries,
                        to: $0
                    )
                }
                .joined(separator: ClipboardPayloadMacro.placeholder)
        } else {
            groundedWorkingText = RepoVocabularyMatcher.preapplying(
                entries: groundingEntries,
                to: workingText
            )
        }
        if groundedWorkingText != workingText {
            Log.polishing.info(
                "Technical grounding pre-applied: repo=\(repoVocabularyCount, privacy: .public), terminal=\(screenVocabularyCount, privacy: .public), claude=\(claudeVocabularyCount, privacy: .public), clipboard=\(clipboardVocabularyCount, privacy: .public)"
            )
        }

        var userPrompts = promptTemplates.renderedUserPrompts(
            inputText: groundedWorkingText,
            replacementDictionary: replacementDictionarySection
        )
        // Reference-context blocks are prepended to the FINAL user
        // message, letting the polish model fix near-miss spelling
        // of technical terms against what the user copied and what
        // was on their screen.
        //
        // ONE `attaching` call with the blocks ordered by
        // `allocationRank` (terminal, then clipboard). The composer
        // owns the two invariants for every source: context rides
        // INSIDE the last message (a separate message between prefix
        // and suffix invalidated polishd's single-slot checkpoint on
        // every request, and the cold 4B re-prefill blew the polish
        // client timeout — field, 2026-07-11), and it is prepended
        // so the transcript stays LAST. Two sequential prepends keep
        // both invariants too, but silently REVERSE source order —
        // the array is the form that cannot get that wrong.
        //
        // Both excerpts were already selected off-actor above: at or
        // below its grant a source is attached verbatim; above it,
        // the excerpt is the transcript-relevant selection rather
        // than the head of the buffer.
        //
        // The screen block is nil unless the decision is `.render`,
        // which requires the captured pane to be positively joined
        // to one live Claude session — so plain, unjoined Ghostty
        // scrollback contributes vocabulary only and never an
        // excerpt.
        let repoBlock = claudeRepoSnapshot?.contextBlock(
            excerpt: claudeRepoPreparation.excerpt,
            renderBudget: repoRenderBudget
        )
        let screenBlock = screenDecision.contextBlock(
            excerpt: screenPreparation.excerpt,
            renderBudget: screenRenderBudget
        )
        let claudeBlock = capturedClaudeJoin?.snapshot.claudeContextBlock(
            excerpt: claudeSessionPreparation.excerpt,
            renderBudget: claudeRenderBudget
        )
        let clipboardBlock = capturedClipboardContext?.contextBlock(
            excerpt: clipboardPreparation.excerpt,
            renderBudget: clipboardRenderBudget
        )
        // Ordered by `allocationRank` — repository, terminal, claude,
        // clipboard — the same fixed order the budget allocated in.
        let contextBlocks = [repoBlock, screenBlock, claudeBlock, clipboardBlock]
            .compactMap { $0 }
        if !contextBlocks.isEmpty {
            userPrompts = PolishContextBlock.attaching(contextBlocks, to: userPrompts)
        }
        if let clipboardBlock {
            Log.polishing.info(
                "Polish clipboard context attached: \(clipboardBlock.summary, privacy: .public)"
            )
        }
        if let screenBlock {
            Log.polishing.info(
                "Polish terminal screen context attached: \(screenBlock.summary, privacy: .public)"
            )
        }
        if let repoBlock {
            // Count-only by construction: the summary is the
            // collector's provenance line, which is numbers and
            // fixed slugs. Repository contents never reach a log.
            Log.polishing.info(
                "Polish Claude repository context attached: \(repoBlock.summary, privacy: .public)"
            )
        }
        if let claudeBlock {
            Log.polishing.info(
                "Polish Claude session context attached: \(claudeBlock.summary, privacy: .public)"
            )
        }

        // Provenance stays count-only. The screen is recorded only
        // when it actually contributed (an excerpt, terms, or both)
        // — a dropped capture is not worth a summary line. Ordered
        // clipboard-then-screen to match the existing session-record
        // format.
        var capturedPolishContextSummary: String? = clipboardBlock?.summary
        if screenVocabularyCount > 0 || screenBlock != nil {
            // The block's summary when one was rendered (it reports
            // the TRIMMED count); the decision's otherwise.
            let screenSummary =
                screenBlock?.summary ?? screenDecision.provenanceSummary
            capturedPolishContextSummary = capturedPolishContextSummary
                .map { "\($0) \(screenSummary)" } ?? screenSummary
        }

        let request = LLMPolishingRequest(
            inputText: groundedWorkingText,
            systemPrompt: promptTemplates.systemContent,
            userPrompts: userPrompts
        )

        return Assembly(
            request: request,
            groundedWorkingText: groundedWorkingText,
            polishContextSummary: capturedPolishContextSummary,
            repoBlock: repoBlock,
            screenBlock: screenBlock,
            claudeBlock: claudeBlock,
            clipboardBlock: clipboardBlock,
            repoVocabularyCount: repoVocabularyCount,
            clipboardVocabularyCount: clipboardVocabularyCount
        )
    }
}
