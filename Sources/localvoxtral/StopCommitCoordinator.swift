import Foundation

/// Everything in the stop-commit that decides what reaches the polisher, and
/// the commit around it: the transcript's preparation (replacement
/// dictionary, payload macro), the profile and templates, the sample it takes
/// of the world before the async task starts, the two clipboard gates, the
/// gather-assemble-send step, the overlay commit, the record's provenance,
/// and — in a dogfood build — the capture record. The session's stop-commit
/// (`DictationSessionController+StopCommit.swift`) supplies its inputs — the
/// transcript, the replacement dictionary latched at start, the commit target
/// whose bundle ID picks the profile — and applies the outcome;
/// `PolishRequestGoldenTests` pins what those inputs produce.
///
/// It touches nothing but what it is handed — `capture` clears the
/// context's captures, `commit` inserts through the overlay, `polish`
/// records learned terms — and it never reads or writes the view model, so
/// the ordering rules below hold wherever the commit is driven from.
enum StopCommitCoordinator {
    // MARK: - Prologue

    /// What the commit sampled of the world at stop, before it handed off to
    /// the polish task.
    ///
    /// These four are taken TOGETHER and pre-Task on purpose: the repo-
    /// vocabulary await inside the task runs to `RepoVocabularyPipeline.deadline`
    /// (3 s) in the worst case, and anything
    /// re-read after it would describe a different moment than the one the
    /// user stopped in.
    struct Capture {
        let clipboardContext: PolishClipboardContext?
        let screenDecision: TerminalScreenContextDecision
        let claudeJoin: ClaudeSessionJoin?
        let socketPaneStart: SocketPaneScreenCapture?
    }

    /// Samples the world for one stop-commit, and — with no endpoint — tears
    /// down what would otherwise leak into the next session.
    ///
    /// Opt-in clipboard grounding is read HERE, pre-Task, right next to the
    /// payload-macro clipboard read in the caller, so both features observe
    /// the SAME pasteboard state: a copy landing during the repo-vocabulary
    /// await must not make the context ground against different text than the
    /// payload macro substitutes. When the setting is off OR the polishing
    /// endpoint is not permitted (loopback-only without the trusted-endpoint
    /// opt-in), the pasteboard is never read (privacy).
    @MainActor
    static func capture(
        endpointURL: URL?,
        settings: SettingsStore,
        context: SessionContextResolver,
        pasteboardReader: @MainActor () -> any PasteboardReading
    ) -> Capture {
        guard let endpointURL else {
            // No endpoint: nothing to ground for, and neither the capture nor
            // the join must survive into a later session's reconciliation.
            // Nothing will read this join's remote herdr tunnel either, so it
            // goes now rather than at the handle's deinit.
            context.terminalScreenStartCapture = nil
            context.claudeSessionJoin = nil
            context.socketPaneStartCapture = nil
            context.closeRemoteHerdrForwards()
            return Capture(
                clipboardContext: nil,
                screenDecision: .drop(reason: .noStartCapture),
                claudeJoin: nil,
                socketPaneStart: nil
            )
        }

        let clipboardContext = polishClipboardContext(
            endpointURL: endpointURL,
            settings: settings,
            pasteboardReader: pasteboardReader
        )
        // Reconciled HERE, pre-Task, for the same reason as the clipboard read
        // above: the stop-time re-read must sample the screen at commit, not
        // after the repo-vocabulary await has let up to 3 s of agent output scroll
        // past — which would report every session as mutated.
        let screenDecision = context.terminalScreenContextDecision(
            endpointURL: endpointURL
        )
        // AFTER the screen decision, never before: that call is what asks the
        // authorizer about the join, and consuming it first would clear it out
        // from under the question and silently withdraw every raw screen
        // attachment.
        let claudeJoin = context.consumeClaudeSessionJoin()
        let socketPaneStart = context.consumeSocketPaneStartCapture()

        return Capture(
            clipboardContext: clipboardContext,
            screenDecision: screenDecision,
            claudeJoin: claudeJoin,
            socketPaneStart: socketPaneStart
        )
    }

    // MARK: - Clipboard gates

    /// Reads a capped clipboard excerpt for polish grounding, but ONLY when the
    /// opt-in setting is on AND the polishing endpoint is loopback. Both guards
    /// short-circuit BEFORE the reader resolves, so a disabled toggle or a
    /// remote endpoint means the pasteboard is never touched at all (privacy:
    /// no read). The endpoint gate keeps the Settings promise honest: the
    /// polishing endpoint is user-configurable and may point at a cloud
    /// provider, which must never receive clipboard content.
    @MainActor
    static func polishClipboardContext(
        endpointURL: URL,
        settings: SettingsStore,
        pasteboardReader: @MainActor () -> any PasteboardReading
    ) -> PolishClipboardContext? {
        guard settings.polishClipboardContextEnabled else { return nil }
        guard PolishContextClipboardReader.isPermittedContextEndpoint(
            endpointURL,
            trustedEndpointEnabled: settings.polishContextTrustedEndpointEnabled
        ) else {
            Log.polishing.info(
                "Polish clipboard context skipped: polishing endpoint is not permitted (loopback-only without the trusted-endpoint opt-in)"
            )
            return nil
        }
        return PolishContextClipboardReader.readClipboardContext(
            from: pasteboardReader()
        )
    }

    /// Result of the spoken clipboard-paste macro over the (replacement-applied)
    /// working text: `placeholderText` carries the placeholder in place of each
    /// marker when the macro fired (else it is the input unchanged), `payload`
    /// is the sanitized clipboard string to substitute back at commit (nil when
    /// the macro did not fire), and `summary` is the count-only provenance note
    /// for the session record (nil when the macro did not fire).
    struct ClipboardPayloadMacroOutcome {
        let placeholderText: String
        let payload: String?
        let summary: String?
    }

    /// Applies the spoken clipboard-paste macro to `text` when the setting is on
    /// AND a marker phrase is present. Reads the clipboard exactly ONCE (through
    /// the shared `PolishContextClipboardReader` readability rules — concealed/
    /// transient/empty are skipped). An unreadable clipboard leaves the
    /// transcript unchanged and logs one content-free line. When the setting is
    /// off or no marker was spoken, the pasteboard is never touched.
    @MainActor
    static func clipboardPayloadMacro(
        applyingTo text: String,
        settings: SettingsStore,
        pasteboardReader: @MainActor () -> any PasteboardReading
    ) -> ClipboardPayloadMacroOutcome {
        guard settings.clipboardPayloadMacroEnabled else {
            return ClipboardPayloadMacroOutcome(placeholderText: text, payload: nil, summary: nil)
        }
        guard !ClipboardPayloadMacro.detectMarkers(in: text).isEmpty else {
            return ClipboardPayloadMacroOutcome(placeholderText: text, payload: nil, summary: nil)
        }
        guard let payload = PolishContextClipboardReader.readableSanitizedString(
            from: pasteboardReader()
        ) else {
            Log.polishing.info(
                "Clipboard payload macro: marker spoken but clipboard unreadable; transcript left unchanged"
            )
            return ClipboardPayloadMacroOutcome(placeholderText: text, payload: nil, summary: nil)
        }
        let replaced = ClipboardPayloadMacro.replaceMarkersWithPlaceholder(in: text)
        Log.polishing.info(
            "Clipboard payload macro fired: \(replaced.count, privacy: .public) marker(s), payload:\(payload.count, privacy: .public)ch"
        )
        return ClipboardPayloadMacroOutcome(
            placeholderText: replaced.text,
            payload: payload,
            summary: "payload:\(payload.count)ch"
        )
    }

    /// Substitutes the clipboard payload back into `text` (replacing the macro
    /// placeholder). A no-op when the macro did not fire (`payload == nil`).
    static func substitutingPayload(_ text: String, payload: String?) -> String {
        guard let payload else { return text }
        return ClipboardPayloadMacro.substitutePayload(in: text, payload: payload)
    }

    // MARK: - Commit

    /// The overlay commit and what the caller has to do with it: `succeeded`
    /// rides into the session record, `failureMessage` into `lastError`.
    struct CommitResult {
        let outcome: OverlayBufferCommitOutcome
        let succeeded: Bool
        let failureMessage: String?
    }

    @MainActor
    static func commit(
        overlay: any OverlayBufferSessionCoordinating,
        textInsertion: any OverlayTextCommitting,
        autoCopyEnabled: Bool
    ) -> CommitResult {
        let outcome = overlay.commitIfNeeded(
            using: textInsertion,
            autoCopyEnabled: autoCopyEnabled
        )
        if case .failed(let failureMessage) = outcome {
            return CommitResult(outcome: outcome, succeeded: false, failureMessage: failureMessage)
        }
        return CommitResult(outcome: outcome, succeeded: true, failureMessage: nil)
    }

    // MARK: - Polish inputs

    /// Everything applied to the transcript without a model: the file's rules
    /// when exact replacement is on, then the casing rules of the user's
    /// terms. Nil when there is nothing to apply.
    @MainActor
    static func effectiveReplacementDictionary(
        settings: SettingsStore,
        appConfigStore: any AppConfigServing
    ) -> ReplacementDictionary? {
        let fileEntries = settings.replacementDictionaryEnabled
            ? appConfigStore.loadReplacementDictionary()
            : ReplacementDictionary(entries: [])
        let effective = fileEntries.adding(speakerTerms: settings.polishSpeakerTerms)
        return effective.entries.isEmpty ? nil : effective
    }

    /// Polishing prompt profile for a stop-commit: `.agent` iff the user has the
    /// agent profile enabled AND the dictation goes to a coding agent: the
    /// captured target bundle ID is terminal-like (built-in terminal
    /// allowlist, or the user's Settings → Terminals list — the successor of
    /// `terminal_apps.toml`), or the dictation joined a Claude Desktop Code-tab
    /// session. Mirrors the live-mode target combination (allowlist + user
    /// bundle IDs); the AX-probe verdict is deliberately not consulted here —
    /// the polish switch keys off the app identity, not the focused field's
    /// writability.
    ///
    /// Claude Desktop goes by the join, not its bundle ID: the same app hosts
    /// a plain chat, where the agent profile's backticks and joined paths
    /// would be wrong, and only the join proves focus was in a Code-tab
    /// session.
    @MainActor
    static func polishProfile(
        forTargetBundleID bundleID: String?,
        claudeJoin: ClaudeSessionJoin?,
        settings: SettingsStore
    ) -> PolishPromptProfile {
        guard settings.agentPolishProfileEnabled else { return .standard }
        if claudeJoin?.mechanism == .desktopSession { return .agent }
        guard let bundleID, !bundleID.isEmpty else { return .standard }
        if TerminalTargetDetector.isTerminalLikeBundleID(bundleID) { return .agent }
        if settings.userTerminalAppBundleIDs.contains(bundleID) { return .agent }
        return .standard
    }

    /// Folds one dictation's resolved spellings into the learned terms.
    ///
    /// Cheap enough for the commit path: an in-memory merge. The file write is
    /// the store's own background work.
    /// A nil `project` means the app could not establish which project this
    /// dictation belongs to, and nothing is learned from it — see
    /// `LearnedTermProjectResolver.resolve`.
    static func recordLearnedTerms(
        merged: PolishContextGrounding.Merged,
        project: LearnedTermProjectResolver.Identity?,
        store learnedTermStore: LearnedTermStore?
    ) {
        guard let learnedTermStore, let project else { return }
        let observations = PolishContextSource.allCases.flatMap { source in
            merged.entries(from: source).map {
                LearnedTermObservation(term: $0.replaceWith, source: source)
            }
        }
        guard !observations.isEmpty else { return }
        learnedTermStore.record(observations, project: project)
    }

    /// The transcript on its way to the polisher, and what the commit keeps
    /// back from it.
    struct Preparation {
        /// Nil when polishing is off or has no configuration.
        let polishingConfig: LLMPolishingConfiguration?
        /// The transcript as recognized: the record's `rawText`.
        let originalText: String
        /// After the replacement dictionary and the payload macro. Carries the
        /// placeholder, never the payload.
        let workingText: String
        let clipboardPayload: String?
        let payloadProvenanceSummary: String?
        /// Set when polishing is on but has no configuration to send to.
        let configurationFailure: (message: String, technicalDetails: String?)?
    }

    /// `latchedReplacementDictionary` is the one the session latched at
    /// start; without one, the dictionary is loaded now.
    @MainActor
    static func prepare(
        originalText: String,
        latchedReplacementDictionary: ReplacementDictionary?,
        settings: SettingsStore,
        appConfigStore: any AppConfigServing,
        pasteboardReader: @MainActor () -> any PasteboardReading
    ) -> Preparation {
        let polishingConfig = settings.llmPolishingConfiguration
        let replacementAppliedText =
            (latchedReplacementDictionary
                ?? effectiveReplacementDictionary(settings: settings, appConfigStore: appConfigStore))?
                .apply(to: originalText) ?? originalText
        // Spoken clipboard-paste macro (Overlay Buffer only): after the
        // replacement dictionary and BEFORE the polish request is built,
        // swap each spoken marker for the env-var-shaped placeholder and
        // read the clipboard once. The placeholder — not the payload —
        // flows through polish and persistence. Both profiles enforce its
        // occurrence count before the real payload is substituted at
        // commit. No marker or setting off: a no-op that never touches the
        // pasteboard.
        let clipboardMacro = clipboardPayloadMacro(
            applyingTo: replacementAppliedText,
            settings: settings,
            pasteboardReader: pasteboardReader
        )
        // In Mistral mode the endpoint is pinned, so the only way to get no
        // configuration is a missing key — and "set a valid endpoint URL"
        // would send the user hunting for a field that is not on the pane.
        let configurationFailure: (message: String, technicalDetails: String?)? =
            settings.llmPolishingEnabled && polishingConfig == nil
            ? (
                settings.polishingBackendMode == .mistralAPI
                    ? "Mistral API key missing. Add it in Settings → Engines."
                    : "Set a valid LLM polishing endpoint URL in Settings.",
                settings.polishingBackendMode == .mistralAPI
                    ? "No Mistral API key is configured; the polish request was not sent."
                    : "Settings value could not be normalized to an HTTP endpoint URL."
            )
            : nil
        return Preparation(
            polishingConfig: polishingConfig,
            originalText: originalText,
            workingText: clipboardMacro.placeholderText,
            clipboardPayload: clipboardMacro.payload,
            payloadProvenanceSummary: clipboardMacro.summary,
            configurationFailure: configurationFailure
        )
    }

    /// The templates the request is rendered from: the profile's pair, the
    /// reference guide, then the user's About-you block and terms. The one
    /// place this is assembled; the prompt-cache warmup calls it too, so the
    /// fixed start it warms is the one real requests send.
    @MainActor
    static func promptTemplates(
        profile: PolishPromptProfile,
        settings: SettingsStore,
        appConfigStore: any AppConfigServing
    ) -> LLMPromptTemplates {
        appConfigStore.loadLLMPromptTemplates(profile: profile)
            .withReferenceGuide()
            .withSpeakerProfile(settings.polishSpeakerProfile, terms: settings.polishSpeakerTerms)
    }

    // MARK: - Polish

    /// What one polish produced: the gathered material and the assembled
    /// request (the dogfood capture reads both), and the reply.
    struct PolishOutcome {
        struct Polished {
            /// The model's reply as it came back.
            let polishedText: String
            /// What the classifier let through. Carries the placeholder,
            /// never the payload.
            let committedText: String
            let durationSeconds: Double
        }

        enum Reply {
            /// The working text was blank, so no request was sent.
            case notSent
            case polished(Polished)
            /// The request failed. A nil failure is one the commit path only
            /// logs.
            case failed(PolishOutcomeClassifier.Failure?)
        }

        let material: PolishContextMaterial
        let assembly: PolishRequestAssembler.Assembly
        let reply: Reply
    }

    /// Everything one polish reads besides the prepared transcript.
    struct PolishInput {
        let preparation: Preparation
        let configuration: LLMPolishingConfiguration
        let promptTemplates: LLMPromptTemplates
        let capture: Capture
        let settings: SettingsStore
        let textInsertion: TextInsertionService
        let context: SessionContextResolver
        let repoVocabularyGrounding: any RepoVocabularyGrounding
        let learnedTermStore: LearnedTermStore?
        let service: any LLMPolishingServicing
    }

    /// Gathers, records what the dictation taught, assembles, and sends. Nil
    /// means the commit was cancelled at one of the checkpoints, and the caller
    /// must change nothing.
    @MainActor
    static func polish(_ input: PolishInput) async -> PolishOutcome? {
        let workingText = input.preparation.workingText
        let clipboardPayload = input.preparation.clipboardPayload
        let capture = input.capture
        // The polisher never sees replacement_dictionary.toml (owner
        // ruling 2026-09-18): its `matches` are predictions of recognizer
        // errors, and the model is better off with the user's terms in the
        // About-you block. The file's rules still apply locally, in
        // `prepare`. The `{{replacement_dictionary}}` slot stays: the
        // vocabulary sections ride in it.
        let replacementDictionaryPrompt = ""
        // Repo vocabulary rides in the `{{replacement_dictionary}}`
        // slot; a user template without that placeholder (removing it is
        // explicitly supported) silently drops the section in
        // renderTemplate, so the whole vocabulary path — AX read, git
        // subprocess, provenance — is skipped up front when the ACTIVE
        // template can't carry it.
        let templateCarriesDictionarySlot =
            input.promptTemplates.supportsReplacementDictionary
        // A repo match also votes against every other grounding source.
        // Even without a render slot, keep that vote when another source
        // can pre-apply an exact spelling; otherwise a contested span can
        // be edited unopposed. With no slot and no independent source,
        // the repo result has no consumer and the expensive pipeline is
        // skipped entirely.
        let needsRepoGroundingForConflictSafety =
            capture.clipboardContext != nil
            || capture.screenDecision.vocabularyGroundingText != nil
            || capture.claudeJoin != nil

        // Everything the request is built from, gathered in one
        // step with the same off-actor hops and checkpoints; nil
        // means the commit was cancelled at one of them.
        guard let material = await PolishContextGatherer.gather(PolishContextGatherer.Input(
            settings: input.settings,
            textInsertion: input.textInsertion,
            context: input.context,
            repoVocabularyGrounding: input.repoVocabularyGrounding,
            learnedTermStore: input.learnedTermStore,
            endpointURL: input.configuration.endpointURL,
            workingText: workingText,
            capturedScreenDecision: capture.screenDecision,
            capturedSocketPaneStart: capture.socketPaneStart,
            capturedClaudeJoin: capture.claudeJoin,
            capturedClipboardContext: capture.clipboardContext,
            templateCarriesDictionarySlot: templateCarriesDictionarySlot,
            needsRepoGroundingForConflictSafety: needsRepoGroundingForConflictSafety
        )) else { return nil }

        guard !Task.isCancelled else { return nil }

        // What this dictation taught, remembered for the next one
        // in the same project. Recorded from the MERGED entries
        // and nowhere else: a span the merge abstained on is not
        // evidence of a spelling, and a verification pair is a
        // question put to the model, not an answer.
        recordLearnedTerms(
            merged: material.merged,
            project: material.learnedProject,
            store: input.learnedTermStore
        )

        // Sections, pre-application, prompts, blocks and provenance
        // are one pure step over the merged material; the request
        // it builds is pinned by PolishRequestGoldenTests.
        let assembly = PolishRequestAssembler.assemble(PolishRequestAssembler.Input(
            merged: material.merged,
            templateCarriesDictionarySlot: templateCarriesDictionarySlot,
            replacementDictionaryPrompt: replacementDictionaryPrompt,
            workingText: workingText,
            clipboardPayload: clipboardPayload,
            promptTemplates: input.promptTemplates,
            screenDecision: material.screenDecision,
            claudeRepoSnapshot: material.claudeRepoSnapshot,
            claudeRepoPreparation: material.claudeRepoPreparation,
            claudeSessionPreparation: material.claudeSessionPreparation,
            clipboardPreparation: material.clipboardPreparation,
            screenPreparation: material.screenPreparation,
            capturedClaudeJoin: capture.claudeJoin,
            capturedClipboardContext: capture.clipboardContext,
            repoRenderBudget: material.repoRenderBudget,
            screenRenderBudget: material.screenRenderBudget,
            claudeRenderBudget: material.claudeRenderBudget,
            clipboardRenderBudget: material.clipboardRenderBudget
        ))

        guard !workingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PolishOutcome(material: material, assembly: assembly, reply: .notSent)
        }
        do {
            let result = try await input.service.polish(
                request: assembly.request,
                configuration: input.configuration
            )

            // Trust the polishing model for both prompt profiles.
            // Human evaluation found deterministic token repair
            // could undo useful formatting and reconstruction.
            //
            // Placeholder-count integrity stays independent of
            // that trust: a duplicated placeholder would paste
            // the payload twice, while dropping one of two
            // would lose a requested paste. It is the classifier
            // that compares standalone counts against the
            // grounded pre-polish text and, on mismatch,
            // discards the polish and returns that
            // placeholder-bearing text.
            let committedText = PolishOutcomeClassifier.committedText(
                polished: result.polishedText,
                groundedWorkingText: assembly.groundedWorkingText,
                clipboardPayload: clipboardPayload
            )

            guard !Task.isCancelled else { return nil }

            return PolishOutcome(
                material: material,
                assembly: assembly,
                reply: .polished(PolishOutcome.Polished(
                    polishedText: result.polishedText,
                    committedText: committedText,
                    durationSeconds: result.durationSeconds
                ))
            )
        } catch {
            guard !Task.isCancelled else { return nil }
            let failure = PolishOutcomeClassifier.failure(
                for: error,
                endpointURL: input.configuration.endpointURL
            )
            Log.polishing.error(
                "LLM polishing failed: \(error.localizedDescription, privacy: .public)"
            )
            return PolishOutcome(material: material, assembly: assembly, reply: .failed(failure))
        }
    }

    // MARK: - Record provenance

    /// Combines the clipboard polish-context, payload-macro, and repo-vocabulary
    /// provenance notes into the single `polishContextSummary` record field
    /// (counts only): `clipboard:24ch+payload:1532ch+vocab:3`, any subset, or nil.
    static func mergedPolishProvenanceSummary(
        context: String?,
        payload: String?,
        vocabulary: String? = nil
    ) -> String? {
        let parts = [context, payload, vocabulary].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "+")
    }

    /// The vocabulary half of the record's `polishContextSummary` (counts
    /// only): `vocab:3`, `clipboard-vocab:2`, both joined by `+`, or nil.
    static func vocabularyProvenance(
        repoVocabularyCount: Int,
        clipboardVocabularyCount: Int
    ) -> String? {
        let parts = [
            repoVocabularyCount > 0 ? "vocab:\(repoVocabularyCount)" : nil,
            clipboardVocabularyCount > 0
                ? "clipboard-vocab:\(clipboardVocabularyCount)" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "+")
    }
}
