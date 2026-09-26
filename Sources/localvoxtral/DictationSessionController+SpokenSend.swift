import Foundation
import os

/// The spoken send trigger (#318): dictation that ends in "send it" or
/// "send now" is inserted without those words, then Return is pressed in the
/// app the text went to. Opt-in per output mode, only in an app on
/// `ReturnSubmitsAppList` (by bundle ID), never under Secure Keyboard Entry. Logs say what was decided and
/// never what was said.
/// How an Overlay Buffer commit is sent once it landed.
enum OverlaySpokenSend: Equatable {
    /// Return, pressed in this app while it is frontmost.
    case returnKey(pid_t)
    /// The opencode prompt relay's submit, after its append (#719).
    case promptRelaySubmit
}

extension DictationSessionController {
    // MARK: - Overlay Buffer

    /// Runs at stop, before the dictionary and the polisher see the text.
    /// When the dictation ends in the trigger and every gate passes, the
    /// trigger is cut from the dictation event and how to send is returned.
    /// Otherwise the text is left as dictated and nil returned. With a
    /// healthy prompt relay the commit goes to the pane's prompt, so no
    /// frontmost-app or Secure Keyboard Entry gate applies.
    func stripOverlaySpokenSendTrigger() -> OverlaySpokenSend? {
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
        if textInsertion.promptRelayTakesText {
            transcript.currentDictationEventText = remainder
            refreshOverlayBufferSession()
            Log.dictation.notice(
                "spoken send: trigger removed before commit; the prompt relay submits text_empty=\(remainder.isEmpty, privacy: .public)"
            )
            return .promptRelaySubmit
        }
        guard let pid = overlayBufferCoordinator.commitTargetAppPID else {
            Log.dictation.notice("spoken send: no target app; trigger kept as text")
            return nil
        }
        guard returnSubmitsPrompt(inPID: pid) else {
            Log.dictation.notice("spoken send: Return does not submit in the target app; trigger kept as text")
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
        return .returnKey(pid)
    }

    /// After the overlay commit: send only when the text landed. A
    /// clipboard fallback or a failed insert means the prompt is not in the
    /// target app, and a Return would submit whatever is. The relay's submit
    /// queues behind its append, and is dropped if that append fails.
    func sendOverlaySpokenSendIfNeeded(
        _ spokenSend: OverlaySpokenSend?,
        commit: StopCommitCoordinator.CommitResult
    ) {
        guard let spokenSend else { return }
        guard commit.outcome == .succeeded else {
            Log.dictation.notice("spoken send: commit did not insert the text; no Return")
            return
        }
        switch spokenSend {
        case .returnKey(let pid):
            _ = pressSpokenSendReturn(pid: pid)
        case .promptRelaySubmit:
            textInsertion.promptRelaySink?.submit()
            Log.dictation.notice("spoken send: submit handed to the prompt relay")
        }
    }

    // MARK: - Live Auto-Paste
    //
    // Every decision is taken when it is needed, from the app frontmost at
    // that moment: nothing captured at session start or connect time takes
    // part. A segment's partials are withheld only while an app where Return
    // submits is frontmost; only a non-empty backend final can trigger; the
    // Return goes to that frontmost app, and only when every live insertion
    // since the last Return sent (or the session start) landed in it.

    /// Session start: nothing carries over from the previous dictation.
    func resetLiveSpokenSendForSession() {
        spokenSendLatch.reset()
        liveSpokenSendTypedSinceReturn = false
        liveSpokenSendReturnPressed = false
        liveSpokenSendTypedWord = ""
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
            let withholds = settings.liveSpokenSendEnabled
                && (textInsertion.promptRelayTakesText || frontmostReturnSubmitsPID() != nil)
            liveSpokenSendSegmentMode = withholds ? .withheld : .typedLive
        }
        return liveSpokenSendSegmentMode == .withheld
    }

    /// A final of a withheld segment. Only the backend's non-empty final can
    /// trigger: the accumulator's merge keeps partial words the final dropped
    /// and glues a disagreeing partial onto it, so it is typed as text and
    /// never parsed. The cost: when the final is not empty, words only a
    /// partial had are not typed.
    func deliverLiveSpokenSendFinal(_ finalText: String, merged: String, startsMidWord: Bool) {
        liveSpokenSendSegmentMode = .undecided
        let final = finalText.trimmed
        guard !final.isEmpty else {
            spokenSendLatch.noteNonSubmittingFinal()
            typeLiveSpokenSendText(merged, startsMidWord: startsMidWord)
            return
        }
        let action = SendNowCommandParser.parse(final)
        switch action {
        case .none:
            return
        case .insertText(let text):
            spokenSendLatch.noteNonSubmittingFinal()
            typeLiveSpokenSendText(text, startsMidWord: startsMidWord)
        case .pressReturn, .insertTextAndPressReturn:
            // Claimed before anything is typed or pressed: a repeated final
            // must not do either a second time.
            guard spokenSendLatch.claimSubmission(of: final) else {
                Log.dictation.notice("spoken send: repeated final ignored")
                return
            }
            // The relay puts the text in the pane's prompt whatever is
            // frontmost, and its submit follows the appends in order.
            if textInsertion.promptRelayTakesText {
                if case .insertTextAndPressReturn(let text) = action {
                    typeLiveSpokenSendText(text, startsMidWord: startsMidWord)
                }
                submitLiveSpokenSendThroughPromptRelay()
                return
            }
            // The Return is decided before anything is typed: the trigger is
            // cut only when it will be sent. Otherwise the final is typed
            // whole, and no spoken word is lost.
            guard let pid = liveSpokenSendReturnTarget() else {
                typeLiveSpokenSendText(final, startsMidWord: startsMidWord)
                return
            }
            if case .insertTextAndPressReturn(let text) = action {
                typeLiveSpokenSendText(text, startsMidWord: startsMidWord)
            }
            pressLiveSpokenSendReturn(in: pid)
        }
    }

    /// A withheld segment promoted without a final (stop, dropped socket):
    /// typed as text, never a trigger.
    func deliverPromotedLiveSpokenSendSegment(_ segment: String, startsMidWord: Bool) {
        let mode = liveSpokenSendSegmentMode
        liveSpokenSendSegmentMode = .undecided
        guard mode == .withheld else { return }
        spokenSendLatch.noteNonSubmittingFinal()
        typeLiveSpokenSendText(segment, startsMidWord: startsMidWord)
    }

    /// Live text was typed: the next withheld segment needs a space before
    /// it, unless it finishes the word this text ends on.
    func noteLiveTextTyped(_ text: String) {
        liveSpokenSendTypedSinceReturn = true
        if let lastSpace = text.lastIndex(where: \.isWhitespace) {
            liveSpokenSendTypedWord = String(text[text.index(after: lastSpace)...])
        } else {
            liveSpokenSendTypedWord += text
        }
    }

    func typeLiveSpokenSendText(_ text: String, startsMidWord: Bool) {
        var text = text
        guard !text.isEmpty else { return }
        // A space only after text in the same app: the last recorded landing
        // must be the app in front now. No landing yet (the hold-back stream
        // still holds it) means that text will land here too. A landing
        // under Secure Keyboard Entry is nil and never matches.
        let lastLanding = textInsertion.liveInsertionTargetPIDs.last
        let sameApp = lastLanding.map { $0 != nil && $0 == textInsertion.frontmostApplicationPID() } ?? true
        // A segment a new generation started mid-word finishes the word
        // typed last (#536): "Pleas" + "e help", not "Pleas e help".
        // A new generation may hear the word's end again ("information" +
        // "ation overload"); that repeat is dropped, as in the dictation event.
        let continuesTypedWord = liveSpokenSendTypedSinceReturn && sameApp
            && startsMidWord && liveSpokenSendTypedWord.last?.isLetter == true
        if continuesTypedWord {
            let overlap = TextMergingAlgorithms.joinOverlap(
                existing: liveSpokenSendTypedWord, incoming: text, incomingStartsMidWord: true)
            text = String(text.dropFirst(overlap))
            guard !text.isEmpty else { return }
        }
        let separator = liveSpokenSendTypedSinceReturn && sameApp && !continuesTypedWord ? " " : ""
        textInsertion.enqueueRealtimeInsertion(separator + text)
        noteLiveTextTyped(text)
        if let accessibilityError = textInsertion.lastAccessibilityError {
            lastError = accessibilityError
        }
    }

    /// The frontmost app a Return may go to right now, or nil.
    private func liveSpokenSendReturnTarget() -> pid_t? {
        guard !TerminalTargetDetector.isSecureKeyboardEntryEnabled() else {
            Log.dictation.notice("spoken send: Secure Keyboard Entry is on; no Return")
            return nil
        }
        guard let pid = frontmostReturnSubmitsPID() else {
            Log.dictation.notice("spoken send: Return does not submit in the frontmost app; no Return")
            return nil
        }
        // The record is cleared only by a Return sent, never by a refusal:
        // once text has landed elsewhere (or under Secure Keyboard Entry), no
        // later trigger can submit the app's own prompt in its place.
        guard textInsertion.liveInsertionTargetPIDs.allSatisfy({ $0 == pid }) else {
            if !liveSpokenSendBlockLogged {
                liveSpokenSendBlockLogged = true
                Log.dictation.notice(
                    "spoken send: text went to another app; no Return for the rest of this dictation"
                )
            }
            return nil
        }
        return pid
    }

    private func pressLiveSpokenSendReturn(in pid: pid_t) {
        // The hold-back stream keeps the last word until it knows the word is
        // complete; the Return must come after it.
        textInsertion.flushFinalLiveReplacementCorrections()
        guard !textInsertion.hasPendingInsertionText else {
            Log.dictation.notice("spoken send: text not delivered yet; no Return")
            return
        }
        // Checked again: the text just typed is in the record now.
        guard liveSpokenSendReturnTarget() == pid else { return }
        guard pressSpokenSendReturn(pid: pid) else { return }
        textInsertion.clearLiveInsertionTargetPIDs()
        liveSpokenSendTypedSinceReturn = false
        liveSpokenSendReturnPressed = true
        liveSpokenSendTypedWord = ""
    }

    /// The relay's counterpart of `pressLiveSpokenSendReturn`: every word
    /// released first, then the submit, queued behind the appends. Refused
    /// when the relay failed on the way, since that text went to the keys.
    private func submitLiveSpokenSendThroughPromptRelay() {
        textInsertion.flushFinalLiveReplacementCorrections()
        guard !textInsertion.hasPendingInsertionText, textInsertion.promptRelayTakesText,
              let sink = textInsertion.promptRelaySink
        else {
            Log.dictation.notice("spoken send: text not handed to the prompt relay; no submit")
            return
        }
        sink.submit()
        Log.dictation.notice("spoken send: submit handed to the prompt relay")
        textInsertion.clearLiveInsertionTargetPIDs()
        liveSpokenSendTypedSinceReturn = false
        liveSpokenSendReturnPressed = true
        liveSpokenSendTypedWord = ""
    }

    /// The frontmost app's PID when it is on `ReturnSubmitsAppList`. Nil
    /// when it is not, or cannot be read.
    private func frontmostReturnSubmitsPID() -> pid_t? {
        guard let pid = textInsertion.frontmostApplicationPID(),
              returnSubmitsPrompt(inPID: pid)
        else { return nil }
        return pid
    }

    private func returnSubmitsPrompt(inPID pid: pid_t) -> Bool {
        ReturnSubmitsAppList.contains(
            dependencies.bundleIdentifier(pid),
            userTerminalBundleIDs: settings.userTerminalAppBundleIDs
        )
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
