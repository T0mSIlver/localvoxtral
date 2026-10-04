import ClaudeContextWire
import Foundation
import os

extension DictationSessionController {
    /// Quit: a stopped dictation still owed its commit is saved to History
    /// as not inserted, synchronously, so the quit's History drain writes
    /// it. Waiting on the polish (#1284), on the final transcript (#1296),
    /// or on an addressed send's delivery (#1667).
    /// A dictation still running is stopped here first: the terminate
    /// observer's stop runs in a Task, after the drain if at all (#1568).
    func saveStoppedDictationForQuit() {
        if isDictating {
            stopDictation(reason: "app terminating")
        }
        // Before the cancel: a delivery the commit awaits will not answer
        // before the process exits (#1667).
        saveHandedOffAddressedCommitsForQuit()
        if cancelPolishingForNewSessionIfNeeded() { return }
        guard isFinalizingStop, !isCompletingStoppedSession, !wasCancelled else { return }
        if sessionIsQuickCapture, sessionDraftReview == nil {
            // A capture's commit is local and synchronous: the words so far
            // go to History and the Inbox, as the stop would file them.
            Log.persistence.notice("quit before the final transcript; filing the quick capture so far")
            finishStoppedSession(promotePendingSegment: true)
            return
        }
        // A draft review is not applied: its spoken command may be cut short.
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
