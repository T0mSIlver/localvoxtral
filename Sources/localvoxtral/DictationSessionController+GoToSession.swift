import ClaudeContextWire
import Foundation
import os

/// "Go to <name>" (#723 step 1): an Overlay Buffer dictation that is only
/// that phrase, naming a live joined session, brings the session's pane to
/// the front instead of being inserted. Nothing is typed and no Return is
/// pressed. A name no session has leaves the dictation as text. Logs say what
/// was decided, never the name.
extension DictationSessionController {
    enum GoToSessionStatus {
        static let ambiguous = "More than one session has that name"
        static let unsupported = "Can't bring that session forward yet"
        static let paneNotFound = "Couldn't find that session's window"
    }

    /// Runs at stop, before the spoken send trigger, the dictionary and the
    /// polisher. Returns true when the dictation is a go-to phrase: a task
    /// then resolves the name and either finishes the session as a command
    /// or commits the text as dictated.
    func startGoToSessionIfSpoken(
        sessionMode: DictationOutputMode,
        sample: OverlayStopSample
    ) -> Bool {
        guard let navigator = sessionNavigator,
              let spokenName = GoToSessionCommandParser.spokenName(in: transcript.currentDictationEventText)
        else { return false }
        let text = transcript.currentDictationEventText
        // Only what the history keeps: the closure outlives the stop, and a
        // join can hold an ssh forward open.
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
            let resolution = await navigator.resolve(spokenName: spokenName)
            guard let self, !Task.isCancelled else { return }
            switch resolution {
            case .unknown:
                Log.dictation.notice("go to session: no live session has that name; committing it as text")
                self.saveInterruptedPolishCommit = nil
                self.commitOverlayBufferText(sessionMode: sessionMode, sample: sample, goToChecked: true)
                // The commit may hand off to a polish task; this one ends
                // with it, so whoever awaits the commit awaits all of it.
                await self.polishAndCommitTask?.value
            case .ambiguous(let count):
                Log.dictation.notice("go to session: \(count, privacy: .public) panes have that name; nothing done")
                self.finishGoToSession(sessionMode: sessionMode, status: GoToSessionStatus.ambiguous)
            case .resolved(let session):
                // The phrase was a command: the panel goes before the pane
                // comes forward.
                self.saveInterruptedPolishCommit = nil
                self.overlayBufferCoordinator.reset()
                let outcome = await navigator.focuser.focusPane(of: session)
                guard !Task.isCancelled else { return }
                Log.dictation.notice("go to session: \(String(describing: outcome), privacy: .public)")
                self.finishGoToSession(sessionMode: sessionMode, status: Self.status(for: outcome))
            }
        }
        return true
    }

    /// The popover's one sentence, or nil when the pane came forward.
    static func status(for outcome: SessionPaneFocusOutcome) -> String? {
        switch outcome {
        case .focused, .unverified: nil
        case .paneNotFound: GoToSessionStatus.paneNotFound
        case .unsupported: GoToSessionStatus.unsupported
        }
    }

    private func finishGoToSession(sessionMode: DictationOutputMode, status: String?) {
        saveInterruptedPolishCommit = nil
        overlayBufferCoordinator.reset()
        completeStoppedSessionCleanup(
            sessionMode: sessionMode,
            overlayCommitOutcome: nil,
            shouldCommitOverlay: true
        )
        if let status {
            statusText = status
        }
    }
}
