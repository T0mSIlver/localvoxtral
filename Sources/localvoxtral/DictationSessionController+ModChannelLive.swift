import Foundation

/// Live Auto-Paste through a Claude Code session's mod (#1645): the deltas
/// go down the channel unanswered (`ClaudeModPromptRoute`), so the stop asks
/// the mod how far it got before the record says whether everything landed.
extension DictationSessionController {
    /// Starts the stop's wait for the mod's `ack` and returns true, or false
    /// when the dictation has no mod route to settle. `finish` runs once the
    /// route settled: what the mod did not fill was typed or kept by then.
    func finishLiveAutoPasteSessionAfterModAck(
        sessionMode: DictationOutputMode,
        finish: @escaping @MainActor (_ sessionAudio: Data?) -> Void
    ) -> Bool {
        guard let sink = textInsertion.promptRelaySink, sink.isHealthy,
              sink.route is ClaudeModPromptRoute
        else { return false }
        isFinalizingStop = true
        statusText = StatusStrings.finalizing
        // Every word the hold-back stream holds goes to the mod before the
        // ack counts. A cancel types nothing more (#1222).
        if !wasCancelled {
            textInsertion.flushFinalLiveReplacementCorrections()
        }
        sink.finish()
        let sessionAudio = audio.sessionRecording.finish()
        let storedAudio = sessionStoresAudio ? sessionAudio : nil
        let startedAt = sessionStartedAt ?? Date()
        let provider = sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue
        let model = sessionModelName ?? settings.effectiveModelName
        let join = context.claudeSessionJoin.map(AgentCLIJoin.init)
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
            await sink.waitUntilIdle()
            guard let self, !Task.isCancelled else { return }
            self.saveInterruptedPolishCommit = nil
            finish(sessionAudio)
        }
        return true
    }
}
