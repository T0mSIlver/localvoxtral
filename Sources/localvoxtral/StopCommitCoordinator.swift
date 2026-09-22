import Foundation

/// The stop-commit's dealings with everything that is not the polish request
/// itself: the sample it takes of the world before the async task starts, the
/// two clipboard gates, the overlay commit, the record's vocabulary
/// provenance, and — in a dogfood build — the capture record.
///
/// It touches nothing but what it is handed — `capture` clears the
/// context's captures, `commit` inserts through the overlay — and it never
/// reads or writes the view model, so the ordering rules below hold
/// wherever the commit is driven from.
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

    // MARK: - Record provenance

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
