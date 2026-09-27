import Foundation
import os

/// Reviewing a ready draft by voice (#927). With no agent in the needs-you
/// queue, the answer shortcut opens the oldest shown draft in an Overlay
/// Buffer dictation that shows that one draft. At stop the words decide:
/// "file it" files it as shown, "drop it" discards it, anything else is a
/// change the drafter reruns with (`QuickCaptureSpokenReview`). Nothing is
/// inserted into the focused app. The stop is the commit path's, and the
/// voice stop (#839) ends it on "file it" or "drop it" alone, or on a send
/// phrase after a change.
extension DictationSessionController {
    /// Opens the oldest shown draft, after showing the held ones: the press
    /// itself is a break. False when no draft waits. The draft stays in the
    /// cue: filing, dropping or redrafting it takes it out through the Inbox.
    func openOldestReadyDraft() -> Bool {
        guard settings.agentAttentionEnabled, let attention = agentAttention, let inbox = quickCaptureInbox else {
            return false
        }
        attention.reachedBreak()
        for entry in attention.shownDraftsOldestFirst {
            guard let snapshot = inbox.reviewSnapshot(entry.id) else {
                attention.removeDraft(id: entry.id)
                continue
            }
            Log.dictation.notice("answer shortcut: opening a ready draft")
            startDictation(outputMode: .overlayBuffer, quickCapture: false, draftReview: snapshot)
            return true
        }
        return false
    }

    /// The review's stop: the words are saved in History, then applied to
    /// the draft; the overlay closes as a quick capture's does.
    func commitDraftReview(_ review: QuickCaptureDraftSnapshot, sessionMode: DictationOutputMode) {
        let sessionAudio = audio.sessionRecording.finish()
        let text = transcript.currentDictationEventText.trimmingCharacters(in: .whitespacesAndNewlines)
        saveSessionRecord(
            startedAt: sessionStartedAt ?? Date(),
            rawText: text,
            polishedText: nil,
            polishingDuration: nil,
            provider: sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue,
            model: sessionModelName ?? settings.effectiveModelName,
            outputMode: DictationSessionRecord.quickCaptureOutputMode,
            targetAppBundleID: nil,
            status: .sttCompleted,
            commitSucceeded: true,
            quickCaptureDestination: "Inbox",
            audio: sessionStoresAudio ? sessionAudio : nil,
            joined: nil
        )
        overlayBufferCoordinator.reset()
        completeStoppedSessionCleanup(sessionMode: sessionMode, overlayCommitOutcome: nil, shouldCommitOverlay: true)
        let spoken = QuickCaptureSpokenReview.parse(text, sendPhrases: settings.spokenSendTriggerPhrases)
        guard let inbox = quickCaptureInbox else {
            Log.dictation.error("draft review: no Inbox installed; nothing done")
            statusText = QuickCaptureReviewStatus.gone
            return
        }
        let outcome = inbox.applySpokenReview(spoken, to: review)
        draftReviewTask = outcome.task
        statusText = outcome.status
    }

    /// "file it" or "drop it" alone stops a review by voice, like a send
    /// phrase: the review never presses Return, so no send gate applies.
    func draftReviewStopsByVoice(_ text: String) -> Bool {
        sessionDraftReview != nil && settings.overlaySpokenSendEnabled
            && (QuickCaptureSpokenReview.isCommand(text)
                || SpokenStopRule.endsInSendPhrase(text, phrases: settings.spokenSendTriggerPhrases))
    }
}
