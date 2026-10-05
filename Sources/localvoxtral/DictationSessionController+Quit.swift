import ClaudeContextWire
import Foundation
import os

extension DictationSessionController {
    /// Quit during a dictation: the stop sends its final commit, and the quit
    /// waits for the backend's last words before `saveStoppedDictationForQuit`
    /// saves the record. speechd flushes its tail only on a final commit
    /// (#1756). The finalization is bounded short, as the sleep stop's is
    /// (#1584); when it ends, by the answer or the bound, `reply` lets the
    /// quit go on, possibly before this returns. False, and no `reply`, when
    /// nothing is worth the wait: no dictation is listening, or its backend
    /// is not known to answer a final commit.
    func finalizeDictationBeforeQuit(then reply: @escaping @MainActor () -> Void) -> Bool {
        guard isDictating, backendAnswersFinalCommits || sessionUsesManagedSpeechHelper else { return false }
        Log.backends.notice("quit during a dictation; waiting for the backend's last words")
        quitFinalizationReply = reply
        quitHoldsStoppedSession = true
        stopDictation(
            reason: "app terminating",
            finalizationTimeout: TimingConstants.quitStopFinalizationTimeout
        )
        return true
    }

    /// The stop's finalization ended while a quit waited on it: the record is
    /// left to `saveStoppedDictationForQuit`, which saves it not inserted, so
    /// nothing is typed or polished while the app quits.
    func endQuitFinalization() {
        let reply = quitFinalizationReply
        quitFinalizationReply = nil
        stopFinalizationTask?.cancel()
        stopFinalizationTask = nil
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = nil
        cancelRealtimeReconnect()
        activeRealtimeClient.disconnect()
        guard let reply else { return }
        Log.backends.notice("quit: the stop's finalization ended; saving the dictation")
        reply()
    }

    /// Quit: a stopped dictation still owed its commit is saved to History
    /// as not inserted, synchronously, so the quit's History drain writes
    /// it. Waiting on the polish (#1284), on the final transcript (#1296),
    /// or on an addressed send's delivery (#1667).
    /// A dictation still running is stopped here first: the terminate
    /// observer's stop runs in a Task, after the drain if at all (#1568).
    func saveStoppedDictationForQuit() {
        quitHoldsStoppedSession = false
        quitFinalizationReply = nil
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
