import ClaudeContextWire
import Foundation
import os

extension DictationSessionController {
    /// Stop: the session finishes once the spoken send in flight and the
    /// segments behind it are done, and text waiting behind a code-fence
    /// paste is pasted (#1664), with the audio recorded up to the stop. The
    /// wait counts as finalizing on every stop path, so a new dictation takes
    /// the recovery that cancels it, and the transcript goes to History as
    /// not inserted.
    func finishLiveAutoPasteSessionAfterPendingText(
        sessionMode: DictationOutputMode,
        finish: @escaping @MainActor (_ sessionAudio: Data?) -> Void
    ) -> Bool {
        // The hold-back's tail first: released behind a paste, it waits too.
        if spokenCommandGate.action == nil, !wasCancelled {
            textInsertion.flushFinalLiveReplacementCorrections()
        }
        guard spokenCommandGate.action != nil || (!wasCancelled && textInsertion.pendingTextWaitsOnPaste) else { return false }
        phase = .finalizing
        statusText = StatusStrings.finalizing
        let sessionAudio = audio.sessionRecording.finish()
        let storedAudio = sessionStoresAudio ? sessionAudio : nil
        let startedAt = sessionStartedAt ?? Date()
        let provider = sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue
        let model = sessionModelName ?? settings.effectiveModelName
        let join = context.claudeSessionJoin.map(AgentCLIJoin.init)
        // The session's mod route, if any, settles after the send and
        // before the record (#1645).
        let modSink = unsettledModRouteSink
        saveInterruptedPolishCommit = { [weak self] in
            guard let self else { return }
            self.saveSessionRecord(
                startedAt: startedAt,
                rawText: self.transcript.currentDictationEventText,
                polishedText: nil,
                polishingDuration: nil,
                provider: provider,
                model: model,
                outputMode: sessionMode.rawValue,
                targetAppBundleID: nil,
                status: .sttCompleted,
                commitSucceeded: false,
                audio: storedAudio,
                joined: join
            )
        }
        polishAndCommitTask = Task { @MainActor [weak self] in
            // An action the queue started after the first one is waited for
            // too, or the cleanup would cancel it and drop what follows it.
            while let action = self?.spokenCommandGate.action {
                await action.value
                guard !Task.isCancelled else { return }
            }
            if self?.wasCancelled == false {
                self?.textInsertion.flushFinalLiveReplacementCorrections()
            }
            while let insertion = self?.textInsertion, self?.wasCancelled == false,
                  insertion.pendingTextWaitsOnPaste {
                await insertion.pastesSettled()
                guard !Task.isCancelled else { return }
            }
            if let modSink {
                await self?.settleModRoute(modSink)
            }
            guard let self, !Task.isCancelled else { return }
            self.saveInterruptedPolishCommit = nil
            finish(sessionAudio)
        }
        return true
    }

    /// The words a Live stop's wait had not typed yet, in order: the text
    /// pending behind a paste, then the segments queued behind a spoken
    /// send (#1882). Both are emptied, so nothing types them later.
    func drainUntypedLiveTail() -> String {
        var tail = textInsertion.drainPendingInsertionText()
        for segment in spokenCommandGate.takeQueue() {
            let text: String
            let startsMidWord: Bool
            switch segment {
            case .final(_, let merged, let midWord):
                (text, startsMidWord) = (merged, midWord)
            case .promoted(let segment, let midWord):
                (text, startsMidWord) = (segment, midWord)
            }
            let separator = startsMidWord || tail.last?.isWhitespace != false || text.first?.isWhitespace == true
                ? "" : " "
            tail += separator + text
        }
        return tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
