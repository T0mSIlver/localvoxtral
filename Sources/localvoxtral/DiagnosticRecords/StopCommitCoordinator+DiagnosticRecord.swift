import Foundation

extension StopCommitCoordinator {
    /// The capture record's inputs for one polished stop-commit, assembled
    /// from the gathered material, the built request and the prologue's
    /// sample. Construction only: `writeDiagnosticRecordIfEnabled` is what checks
    /// the runtime opt-in, and the caller runs this AFTER the commit and the
    /// session record so capture latency lands on the tail of the task, never
    /// on the user's paste.
    ///
    /// `committedText` and `polishedOutput` are the placeholder-bearing
    /// strings on purpose: the clipboard PAYLOAD follows the session-record
    /// rule and never enters a persisted record.
    static func diagnosticRecordInputs(
        material: PolishContextMaterial,
        assembly: PolishRequestAssembler.Assembly,
        capture: Capture,
        targetBundleID: String?,
        targetIsTerminalLike: Bool,
        outputMode: String,
        promptProfile: String?,
        polishingEndpointURL: URL?,
        polishModel: String?,
        rawTranscript: String,
        workingText: String,
        polishedOutput: String?,
        committedText: String?,
        polishSeconds: Double?
    ) -> DiagnosticRecordInputs {
        DiagnosticRecordInputs(
            session: DiagnosticRecord.Session(
                targetBundleID: targetBundleID,
                targetKind: targetIsTerminalLike ? "terminal-like" : "other",
                outputMode: outputMode,
                promptProfile: promptProfile,
                endpointClass: polishingEndpointURL.map {
                    DiagnosticRecordBuilder.endpointClass(of: $0)
                },
                polishModel: polishModel
            ),
            join: capture.claudeJoin,
            // Filled from the tap inside writeDiagnosticRecordIfEnabled.
            joinAbstentions: [],
            screenDecision: material.screenDecision,
            // Value inequality is the swap signal: only the herdr reconcile in
            // the gatherer reassigns the gathered decision (a consent
            // withdrawal changes `screenDecision` only), and a failed
            // pane.read returns the fallback (equal). A successful pane.read
            // that happens to EQUAL the fallback mislabels only the route —
            // the decision and cause still tell the true story. Intentional.
            socketPaneSwapApplied: capture.socketPaneStart != nil
                && material.gatheredScreenDecision != capture.screenDecision,
            targetBundleID: targetBundleID,
            demands: [
                .repository: material.repoRenderDemand,
                .terminal: material.screenRenderDemand,
                .claude: material.claudeSessionText.count,
                .clipboard: material.clipboardContext?.retainedCharacterCount ?? 0,
            ],
            grants: material.allocation,
            rendered: [
                .repository: assembly.repoBlock != nil
                    ? material.claudeRepoPreparation.excerpt.count : 0,
                .terminal: assembly.screenBlock != nil
                    ? material.screenPreparation.excerpt.count : 0,
                .claude: assembly.claudeBlock != nil
                    ? material.claudeSessionPreparation.excerpt.count : 0,
                .clipboard: assembly.clipboardBlock != nil
                    ? material.clipboardPreparation.excerpt.count : 0,
            ],
            repoVocabularyHarvest: nil,
            repoVocabularyOutcome: material.repoVocabularyOutcome,
            claudeRepoSnapshot: material.claudeRepoSnapshot,
            claudeRepoOutcome: material.claudeRepoOutcome,
            claudeRepoRenderedExcerpt: assembly.repoBlock != nil
                ? material.claudeRepoPreparation.excerpt : nil,
            claudeSessionText: material.claudeSessionText.isEmpty
                ? nil : material.claudeSessionText,
            claudeSessionOutcome: material.claudeSessionOutcome,
            claudeSessionRenderedExcerpt: assembly.claudeBlock != nil
                ? material.claudeSessionPreparation.excerpt : nil,
            clipboardRetainedText: material.clipboardContext?.retainedText,
            clipboardOutcome: material.clipboardVocabularyOutcome,
            clipboardRenderedExcerpt: assembly.clipboardBlock != nil
                ? material.clipboardPreparation.excerpt : nil,
            screenOutcome: material.screenVocabularyOutcome,
            screenRenderedExcerpt: assembly.screenBlock != nil
                ? material.screenPreparation.excerpt : nil,
            text: DiagnosticRecord.Text(
                rawTranscript: rawTranscript,
                workingText: workingText,
                groundedText: assembly.groundedWorkingText,
                systemPrompt: assembly.request.systemPrompt,
                userPrompts: assembly.request.userPrompts,
                polishedOutput: polishedOutput,
                committedText: committedText
            ),
            polishSeconds: polishSeconds,
            withheldPrompt: capture.claudeJoin?.snapshot.latestPriorUserPrompt
        )
    }
}
