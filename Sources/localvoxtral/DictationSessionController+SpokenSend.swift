import Foundation
import os

/// The spoken send trigger (#318): dictation that ends in "send it" or
/// "send now" is inserted without those words, then Return is pressed in the
/// app the text went to. Opt-in per output mode, terminals only (by bundle
/// ID), never under Secure Keyboard Entry. Logs say what was decided and
/// never what was said.
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
        guard isOnTerminalList(pid: pid) else {
            Log.dictation.notice("spoken send: target is not on the terminal list; trigger kept as text")
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
    //
    // Every decision is taken when it is needed, from the app frontmost at
    // that moment: nothing captured at session start or connect time takes
    // part. A segment's partials are withheld only while a terminal is
    // frontmost; only a non-empty backend final can trigger; the Return goes
    // to the frontmost terminal, and only when every live insertion since the
    // last Return sent (or the session start) landed in that same app.

    /// Session start: nothing carries over from the previous dictation.
    func resetLiveSpokenSendForSession() {
        spokenSendLatch.reset()
        liveSpokenSendTypedSinceReturn = false
        liveSpokenSendSegmentMode = .undecided
        liveSpokenSendBlockLogged = false
        textInsertion.clearLiveInsertionTargetPIDs()
    }

    /// Whether the current segment's text is held back until its final. Taken
    /// at the segment's first insertion and kept for the rest of it: a segment
    /// half typed live cannot have its trigger removed, and one half withheld
    /// must be typed whole at its final.
    func liveSpokenSendWithholdsSegment() -> Bool {
        if liveSpokenSendSegmentMode == .undecided {
            let withholds = settings.liveSpokenSendEnabled && frontmostTerminalPID() != nil
            liveSpokenSendSegmentMode = withholds ? .withheld : .typedLive
        }
        return liveSpokenSendSegmentMode == .withheld
    }

    /// A final of a withheld segment. Only the backend's non-empty final can
    /// trigger: the accumulator's merge keeps partial words the final dropped
    /// and glues a disagreeing partial onto it, so it is typed as text and
    /// never parsed. The cost: when the final is not empty, words only a
    /// partial had are not typed.
    func deliverLiveSpokenSendFinal(_ finalText: String, merged: String) {
        liveSpokenSendSegmentMode = .undecided
        let final = finalText.trimmed
        guard !final.isEmpty else {
            spokenSendLatch.noteNonSubmittingFinal()
            typeLiveSpokenSendText(merged)
            return
        }
        let action = SendNowCommandParser.parse(final)
        switch action {
        case .none:
            return
        case .insertText(let text):
            spokenSendLatch.noteNonSubmittingFinal()
            typeLiveSpokenSendText(text)
        case .pressReturn, .insertTextAndPressReturn:
            // Claimed before anything is typed or pressed: a repeated final
            // must not do either a second time.
            guard spokenSendLatch.claimSubmission(of: final) else {
                Log.dictation.notice("spoken send: repeated final ignored")
                return
            }
            if case .insertTextAndPressReturn(let text) = action {
                typeLiveSpokenSendText(text)
            }
            pressLiveSpokenSendReturnIfAllowed()
        }
    }

    /// A withheld segment promoted without a final (stop, dropped socket):
    /// typed as text, never a trigger.
    func deliverPromotedLiveSpokenSendSegment(_ segment: String) {
        let mode = liveSpokenSendSegmentMode
        liveSpokenSendSegmentMode = .undecided
        guard mode == .withheld else { return }
        spokenSendLatch.noteNonSubmittingFinal()
        typeLiveSpokenSendText(segment)
    }

    private func typeLiveSpokenSendText(_ text: String) {
        guard !text.isEmpty else { return }
        let separator = liveSpokenSendTypedSinceReturn ? " " : ""
        textInsertion.enqueueRealtimeInsertion(separator + text)
        liveSpokenSendTypedSinceReturn = true
        if let accessibilityError = textInsertion.lastAccessibilityError {
            lastError = accessibilityError
        }
    }

    private func pressLiveSpokenSendReturnIfAllowed() {
        // The hold-back stream keeps the last word until it knows the word is
        // complete; the Return must come after it.
        textInsertion.flushFinalLiveReplacementCorrections()
        guard !textInsertion.hasPendingInsertionText else {
            Log.dictation.notice("spoken send: text not delivered yet; no Return")
            return
        }
        guard let pid = frontmostTerminalPID() else {
            Log.dictation.notice("spoken send: frontmost app is not on the terminal list; no Return")
            return
        }
        // The record is cleared only by a Return sent, never by a refusal:
        // once text has landed elsewhere, no later trigger can submit the
        // terminal's own prompt in its place.
        guard textInsertion.liveInsertionTargetPIDs.allSatisfy({ $0 == pid }) else {
            if !liveSpokenSendBlockLogged {
                liveSpokenSendBlockLogged = true
                Log.dictation.notice(
                    "spoken send: text went to another app; no Return for the rest of this dictation"
                )
            }
            return
        }
        guard pressSpokenSendReturn(pid: pid) else { return }
        textInsertion.clearLiveInsertionTargetPIDs()
        liveSpokenSendTypedSinceReturn = false
    }

    /// The frontmost app's PID when its bundle ID is on the built-in or the
    /// Settings > Terminals list. Nil when it is not, or cannot be read.
    private func frontmostTerminalPID() -> pid_t? {
        guard let pid = textInsertion.frontmostApplicationPID(),
              isOnTerminalList(pid: pid)
        else { return nil }
        return pid
    }

    /// Terminal by bundle ID only. The AX probe reads the element focused
    /// now, which need not belong to `pid`.
    private func isOnTerminalList(pid: pid_t) -> Bool {
        let bundleID = dependencies.bundleIdentifier(pid)
        return TerminalTargetDetector.isTerminalLikeBundleID(bundleID)
            || bundleID.map(settings.userTerminalAppBundleIDs.contains) == true
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
