import Foundation
import os

/// The spoken send trigger (#318): dictation that ends in "send it" or
/// "send now" is inserted without those words, then Return is pressed in the
/// app the text went to. Opt-in per output mode, terminals only, never under
/// Secure Keyboard Entry, and never without a target PID. Logs say what was
/// decided and never what was said.
extension DictationSessionController {
    // MARK: - Overlay Buffer

    /// Runs at stop, before the dictionary and the polisher see the text.
    /// When the dictation ends in the trigger and every gate passes, the
    /// trigger is cut from the dictation event and the PID to press Return in
    /// is returned. Otherwise the text is left as dictated and nil returned.
    func stripOverlaySpokenSendTrigger() -> pid_t? {
        guard settings.overlaySpokenSendEnabled else { return nil }
        let action = SendNowCommandParser.parse(transcript.currentDictationEventText)
        let remainder: String
        switch action {
        case .pressReturn:
            remainder = ""
        case .insertTextAndPressReturn(let text):
            remainder = text
        case .insertText, .none:
            return nil
        }
        guard let pid = overlayBufferCoordinator.commitTargetAppPID else {
            Log.dictation.notice("spoken send: no target app; trigger kept as text")
            return nil
        }
        let verdict = TerminalTargetDetector.verdict(
            forBundleID: dependencies.bundleIdentifier(pid),
            userBundleIDs: settings.userTerminalAppBundleIDs
        )
        guard verdict.isTerminalLike else {
            Log.dictation.notice(
                "spoken send: target is not a terminal (\(verdict.reason.rawValue, privacy: .public)); trigger kept as text"
            )
            return nil
        }
        guard !TerminalTargetDetector.isSecureKeyboardEntryEnabled() else {
            Log.dictation.notice("spoken send: Secure Keyboard Entry is on; trigger kept as text")
            return nil
        }
        transcript.currentDictationEventText = remainder
        refreshOverlayBufferSession()
        Log.dictation.notice(
            "spoken send: trigger removed before commit; Return follows in pid=\(pid, privacy: .public) text_empty=\(remainder.isEmpty, privacy: .public)"
        )
        return pid
    }

    /// After the overlay commit: Return only when the text landed. A
    /// clipboard fallback or a failed insert means the prompt is not in the
    /// terminal, and a Return would submit whatever is.
    func pressOverlaySpokenSendReturnIfNeeded(
        pid: pid_t?,
        commit: StopCommitCoordinator.CommitResult
    ) {
        guard let pid else { return }
        guard commit.outcome == .succeeded else {
            Log.dictation.notice("spoken send: commit did not insert the text; no Return")
            return
        }
        _ = pressSpokenSendReturn(pid: pid)
    }

    // MARK: - Live Auto-Paste

    /// Session start, after the target verdict and the live target PID.
    func configureLiveSpokenSendForSession() {
        spokenSendLatch.reset()
        liveSpokenSendTypedSinceReturn = false
        guard isLiveAutoPasteModeEnabled, settings.liveSpokenSendEnabled else {
            isLiveSpokenSendActive = false
            return
        }
        guard sessionTargetIsTerminalLike else {
            isLiveSpokenSendActive = false
            Log.dictation.notice("spoken send: target is not a terminal; live typing unchanged")
            return
        }
        isLiveSpokenSendActive = true
        Log.dictation.notice("spoken send: on; each segment is typed when its final arrives")
    }

    /// A final of a Live Auto-Paste session with the trigger on. `merged` is
    /// the accumulator's segment, built for live typing: when partials and
    /// the final disagree it glues them together ("send" + "Send it." gives
    /// "send Send it."), because typed partials cannot be taken back. Here
    /// none were typed, so the backend's final is the segment, unless the
    /// held partials ran past it: then the merge starts with the final and
    /// keeps the words after it.
    func deliverLiveSpokenSendFinal(_ finalText: String, merged: String) {
        let final = finalText.trimmed
        guard !final.isEmpty else {
            deliverLiveSpokenSendSegment(merged, finalText: merged)
            return
        }
        let mergedWords = SendNowCommandParser.normalizedSegment(merged)
        let finalWords = SendNowCommandParser.normalizedSegment(final)
        let mergedExtendsFinal = mergedWords == finalWords
            || mergedWords.hasPrefix(finalWords + " ")
        deliverLiveSpokenSendSegment(mergedExtendsFinal ? merged : final, finalText: final)
    }

    /// One finalized segment of a Live Auto-Paste session with the trigger
    /// on. None of it was typed while it was spoken. `finalText` is the
    /// backend's final as it arrived, which the resubmit latch compares.
    func deliverLiveSpokenSendSegment(_ segment: String, finalText: String) {
        let action = SendNowCommandParser.parse(segment)
        if action.pressesReturn {
            // Claimed before anything is typed or pressed: a repeated final
            // must not do either a second time.
            guard spokenSendLatch.claimSubmission(of: finalText) else {
                Log.dictation.notice("spoken send: repeated final ignored")
                return
            }
        } else {
            spokenSendLatch.noteNonSubmittingFinal()
        }

        let targetPID = overlayBufferCoordinator.commitTargetAppPID
        if action.pressesReturn, targetPID == nil {
            Log.dictation.notice("spoken send: no target app; no Return")
        }
        for step in SendNowPlan.steps(for: action, targetPID: targetPID) {
            switch step {
            case .insert(let text, _):
                let separator = liveSpokenSendTypedSinceReturn ? " " : ""
                textInsertion.enqueueRealtimeInsertion(separator + text)
                liveSpokenSendTypedSinceReturn = true
                if let accessibilityError = textInsertion.lastAccessibilityError {
                    lastError = accessibilityError
                }
            case .pressReturn(let pid):
                // The hold-back stream keeps the last word until it knows the
                // word is complete; the Return must come after it.
                textInsertion.flushFinalLiveReplacementCorrections()
                guard !textInsertion.hasPendingInsertionText else {
                    Log.dictation.notice("spoken send: text not delivered yet; no Return")
                    continue
                }
                if pressSpokenSendReturn(pid: pid) {
                    liveSpokenSendTypedSinceReturn = false
                }
            }
        }
    }

    // MARK: - Shared

    /// Secure Keyboard Entry is sampled again here: it swallows synthetic
    /// keys while reporting success, and it may have come on since the text
    /// was judged.
    private func pressSpokenSendReturn(pid: pid_t) -> Bool {
        guard !TerminalTargetDetector.isSecureKeyboardEntryEnabled() else {
            Log.dictation.notice("spoken send: Secure Keyboard Entry is on; no Return")
            return false
        }
        let pressed = textInsertion.pressReturn(inAppPID: pid)
        if pressed {
            Log.dictation.notice("spoken send: Return pressed in pid=\(pid, privacy: .public)")
        } else {
            Log.dictation.notice(
                "spoken send: Return not pressed; pid=\(pid, privacy: .public) is not frontmost"
            )
        }
        return pressed
    }
}
