import ClaudeContextWire
import Foundation
import os

extension DictationSessionController {
    /// Quit: a stopped dictation still owed its commit is saved to History
    /// as not inserted, synchronously, so the quit's History drain writes
    /// it. Waiting on the polish (#1284) or on the final transcript (#1296).
    func saveStoppedDictationForQuit() {
        if cancelPolishingForNewSessionIfNeeded() { return }
        guard isFinalizingStop, !isCompletingStoppedSession, !wasCancelled else { return }
        Log.persistence.notice("quit before the final transcript; saving the text so far as not inserted")

        stopFinalizationTask?.cancel()
        stopFinalizationTask = nil
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = nil
        _ = promotePendingRealtimeTextToLatestSegment()
        let sessionMode = sessionOutputMode ?? settings.dictationOutputMode
        let sessionAudio = audio.sessionRecording.finish()
        saveSessionRecord(
            startedAt: sessionStartedAt ?? Date(),
            rawText: transcript.currentDictationEventText,
            polishedText: nil,
            polishingDuration: nil,
            provider: sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue,
            model: sessionModelName ?? settings.effectiveModelName,
            outputMode: sessionMode.rawValue,
            targetAppBundleID: nil,
            status: .sttCompleted,
            commitSucceeded: false,
            audio: sessionStoresAudio ? sessionAudio : nil,
            joined: context.claudeSessionJoin.map(AgentCLIJoin.init)
        )
        completeStoppedSessionCleanup(
            sessionMode: sessionMode,
            overlayCommitOutcome: nil,
            shouldCommitOverlay: false
        )
        overlayBufferCoordinator.reset()
    }
}
