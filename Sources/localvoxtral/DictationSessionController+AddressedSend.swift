import ClaudeContextWire
import Foundation
import os

/// "… send that to <name>" (#723 step 3): an Overlay Buffer dictation that
/// ends in that phrase, naming a live session, is committed to that session
/// and submitted, never to the focused app. A name no session has leaves
/// the dictation as text. The phrase is cut before the dictionary and the
/// polisher; the rest is polished as usual and delivered after. Logs say
/// what was decided, never the name or the text. docs/agent/invariants.md,
/// "Send that to <name> writes only into the named session".
extension DictationSessionController {
    enum AddressedSendStatus {
        static let unsupported = "Can't send to that session yet"
        static let notSent = StatusStrings.agentPromptTextKeptInHistory
        static let typedNotSubmitted = "Typed but not sent; the pane changed"
    }

    /// What became of an addressed commit.
    struct AddressedCommit {
        /// The overlay's commit outcome, nil when the overlay never committed.
        var outcome: OverlayBufferCommitOutcome?
        /// Whether the text reached the session's prompt.
        var inserted: Bool
        /// The popover's one sentence; nil when the text was sent.
        var status: String?
        /// A new dictation cancelled the commit after the text was handed
        /// over: the record is still saved, but the stop's cleanup and
        /// status belong to the new dictation now.
        var superseded = false

        static func notSent(_ status: String) -> AddressedCommit {
            AddressedCommit(outcome: nil, inserted: false, status: status)
        }
    }

    /// Runs at stop, after the go-to check and before the spoken send
    /// trigger. Returns true when the dictation ends in the phrase: a task
    /// then resolves the name and either commits the rest to that session
    /// or commits the whole text as dictated.
    func startAddressedSendIfSpoken(
        sessionMode: DictationOutputMode,
        sample: OverlayStopSample
    ) -> Bool {
        guard let navigator = sessionNavigator,
              let addressed = SessionVoiceCommandParser.addressedDictation(in: transcript.currentDictationEventText)
        else { return false }
        let text = transcript.currentDictationEventText
        let historyJoin = (sample.capture?.claudeJoin ?? context.claudeSessionJoin).map(AgentCLIJoin.init)
        // Until the name resolves this is still a dictation: one a new
        // dictation interrupts goes to History as not inserted.
        saveInterruptedPolishCommit = { [weak self] in
            self?.saveSessionRecord(
                startedAt: sample.record.startedAt,
                rawText: text,
                polishedText: nil,
                polishingDuration: nil,
                provider: sample.record.provider,
                model: sample.record.model,
                outputMode: sample.record.outputMode,
                targetAppBundleID: sample.record.targetAppBundleID,
                status: .sttCompleted,
                commitSucceeded: false,
                audio: sample.record.audio,
                joined: historyJoin
            )
        }
        polishAndCommitTask = Task { @MainActor [weak self] in
            let resolution = await navigator.resolve(spokenName: addressed.spokenName)
            guard let self, !Task.isCancelled else { return }
            switch resolution {
            case .unknown:
                Log.dictation.notice("send to session: no live session has that name; committing it as text")
                self.saveInterruptedPolishCommit = nil
                self.commitOverlayBufferText(sessionMode: sessionMode, sample: sample, goToChecked: true)
            case .ambiguous(let count):
                Log.dictation.notice(
                    "send to session: \(count, privacy: .public) panes have that name; nothing sent, text kept in History"
                )
                let saveNotInserted = self.saveInterruptedPolishCommit
                self.saveInterruptedPolishCommit = nil
                saveNotInserted?()
                self.overlayBufferCoordinator.reset()
                self.completeStoppedSessionCleanup(
                    sessionMode: sessionMode,
                    overlayCommitOutcome: nil,
                    shouldCommitOverlay: true
                )
                self.statusText = GoToSessionStatus.ambiguous
                return
            case .resolved(let session):
                Log.dictation.notice("send to session: name resolved; the phrase is cut before commit")
                self.transcript.currentDictationEventText = addressed.text
                self.refreshOverlayBufferSession()
                self.commitOverlayBufferText(
                    sessionMode: sessionMode,
                    sample: sample,
                    goToChecked: true,
                    addressedTo: session
                )
            }
            // The commit hands off to its own task; this one ends with it,
            // so whoever awaits the commit awaits all of it.
            await self.polishAndCommitTask?.value
        }
        return true
    }

    /// Commits the overlay's text into `session` and submits it. Nil when a
    /// new dictation cancelled it before the text was handed over: the
    /// canceller saves it to History. Cancelled after, it is `superseded`,
    /// and its record is saved here. The text never goes to the focused
    /// app: a route that refuses keeps it in History, and a pane that is not
    /// the session's gets no key.
    func commitOverlayAddressed(to session: ClaudeSessionSnapshot) async -> AddressedCommit? {
        var route = AddressedSessionRoute.unsupported(.noTTY)
        if let resolver = context.claudeSessionJoinResolver {
            route = await resolver.addressedRoute(for: session)
        }
        guard !Task.isCancelled else { return nil }
        switch route {
        case .unsupported:
            saveInterruptedPolishCommit = nil
            return .notSent(AddressedSendStatus.unsupported)
        case .prompt(let route):
            saveInterruptedPolishCommit = nil
            return await commitOverlayThroughAddressedRoute(route)
        case .terminalPane:
            return await commitOverlayIntoTerminalPane(of: session)
        }
    }

    /// The stop's cleanup after an addressed commit, and its one sentence.
    /// Correction learning and term proposals are skipped: they key on the
    /// join of the pane the dictation started in, not the named session.
    func finishAddressedCommit(_ addressed: AddressedCommit, sessionMode: DictationOutputMode) {
        guard !addressed.superseded else { return }
        if case .failed(let message)? = addressed.outcome {
            lastError = message
        }
        completeStoppedSessionCleanup(
            sessionMode: sessionMode,
            overlayCommitOutcome: addressed.outcome,
            shouldCommitOverlay: true
        )
        if let status = addressed.status {
            statusText = status
        }
    }

    private func commitOverlayThroughAddressedRoute(_ route: any AgentPromptRoute) async -> AddressedCommit {
        let sink = AgentPromptSink(
            route: route,
            kept: { _ in Log.dictation.notice("send to session: route refused the text; kept in History") },
            // `AddressedPromptRoute` turns every refusal into a keep.
            fallback: { _ in }
        )
        let committer = PromptRelayOverlayCommitter(sink: sink) { _, _ in }
        let commit = StopCommitCoordinator.commit(
            overlay: overlayBufferCoordinator,
            textInsertion: committer,
            autoCopyEnabled: settings.autoCopyEnabled
        )
        sink.submit()
        await sink.waitUntilIdle()
        let delivered = sink.isHealthy
        Log.dictation.notice("send to session: \(route.name, privacy: .public) delivered=\(delivered, privacy: .public)")
        return AddressedCommit(
            outcome: commit.outcome,
            inserted: delivered,
            status: delivered ? nil : AddressedSendStatus.notSent,
            superseded: Task.isCancelled
        )
    }

    /// The owner's Return ruling on #723: the pane is brought forward, and
    /// only when its tty reads back as the session's is the text typed.
    /// Return follows only when it still does after the typing, the terminal
    /// is frontmost, and Secure Keyboard Entry is off.
    private func commitOverlayIntoTerminalPane(of session: ClaudeSessionSnapshot) async -> AddressedCommit? {
        guard let navigator = sessionNavigator else {
            saveInterruptedPolishCommit = nil
            return .notSent(AddressedSendStatus.unsupported)
        }
        let focus = await navigator.focusPane(sessionID: session.sessionID)
        guard !Task.isCancelled else { return nil }
        saveInterruptedPolishCommit = nil
        Log.dictation.notice("send to session: \(String(describing: focus), privacy: .public)")
        guard case .focused(let bundleID)? = focus else {
            if case .unsupported? = focus { return .notSent(AddressedSendStatus.unsupported) }
            return .notSent(AddressedSendStatus.notSent)
        }
        guard let pid = textInsertion.frontmostApplicationPID(),
              dependencies.bundleIdentifier(pid) == bundleID
        else {
            Log.dictation.notice("send to session: the terminal is not frontmost after the focus; nothing typed")
            return .notSent(AddressedSendStatus.notSent)
        }
        guard !TerminalTargetDetector.isSecureKeyboardEntryEnabled() else {
            Log.dictation.notice("send to session: Secure Keyboard Entry is on; nothing typed")
            return .notSent(AddressedSendStatus.notSent)
        }
        let commit = StopCommitCoordinator.commit(
            overlay: overlayBufferCoordinator,
            textInsertion: PinnedAppOverlayCommitter(textInsertion: textInsertion, pid: pid),
            autoCopyEnabled: settings.autoCopyEnabled
        )
        guard commit.outcome == .succeeded else {
            Log.dictation.notice("send to session: the text did not land in the pane; no Return")
            return AddressedCommit(outcome: commit.outcome, inserted: false, status: nil)
        }
        // Through the navigator: the registry is asked again after the
        // read-back, so an agent that exited meanwhile gets no Return (#1219).
        let stillThere = await navigator.focusedPaneShows(sessionID: session.sessionID, bundleID: bundleID)
        // A new dictation took over during the read-back: its target is not
        // this pane. The typed text is still recorded.
        guard !Task.isCancelled else {
            Log.dictation.notice("send to session: a new dictation started before the Return; no Return")
            return AddressedCommit(
                outcome: commit.outcome,
                inserted: true,
                status: AddressedSendStatus.typedNotSubmitted,
                superseded: true
            )
        }
        guard stillThere, returnSubmitsPrompt(inPID: pid), pressSpokenSendReturn(pid: pid) else {
            Log.dictation.notice("send to session: the pane changed after typing; no Return")
            return AddressedCommit(
                outcome: commit.outcome,
                inserted: true,
                status: AddressedSendStatus.typedNotSubmitted
            )
        }
        return AddressedCommit(outcome: commit.outcome, inserted: true, status: nil)
    }
}

/// Types the overlay's text into one app, the named session's terminal,
/// whatever the overlay latched as its target at start.
@MainActor
final class PinnedAppOverlayCommitter: OverlayTextCommitting {
    private let textInsertion: TextInsertionService
    private let pid: pid_t

    init(textInsertion: TextInsertionService, pid: pid_t) {
        self.textInsertion = textInsertion
        self.pid = pid
    }

    var isAccessibilityTrusted: Bool { textInsertion.isAccessibilityTrusted }

    func insertTextPrioritizingKeyboard(_ text: String, preferredAppPID _: pid_t?) -> TextInsertResult {
        textInsertion.insertTextPrioritizingKeyboard(text, preferredAppPID: pid)
    }

    func pasteUsingCommandV(_ text: String, preferredAppPID _: pid_t?) -> Bool {
        textInsertion.pasteUsingCommandV(text, preferredAppPID: pid)
    }
}
