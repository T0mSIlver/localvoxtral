import ClaudeContextWire
import Foundation
import os

/// Where a go-to moved the words this dictation.
enum LiveGoToLanding {
    /// Its pane, read back.
    case verified(sessionID: String)
    /// A pane came forward, but not provably the session's.
    case unverified
}

/// "Go to <name>" in Live Auto-Paste (#747): a segment that is only that
/// phrase, naming a live joined session, brings its pane forward instead of
/// being typed. `spokenCommandGate` holds a segment while what was heard can
/// still read "go to", and one that opens with it until its final; anything
/// else is released at once: "Good" is typed as soon as the third letter
/// rules out "go to". Nothing is held while no session is live. Segments
/// that end while the pane comes forward wait, then land in it. The name
/// lookup and the focus are Overlay Buffer's (`SessionNavigator`,
/// `SessionPaneFocusing`).
extension DictationSessionController {
    /// Whether a segment that reaches go-to is held: only while a session
    /// is live.
    var liveGoToIsArmed: Bool {
        sessionNavigator?.hasLiveSessions == true
    }

    /// The session "call this session" names: the one the dictation joined,
    /// or the one a go-to brought forward since. Nil after a go-to whose pane
    /// did not read back as the session's.
    var liveThisSessionID: String? {
        switch liveGoToLanding {
        case .verified(let sessionID)?: sessionID
        case .unverified?: nil
        case nil: context.claudeSessionJoin?.snapshot.sessionID
        }
    }

    /// Stop: the session finishes once every go-to and the segments behind
    /// them are done, and text waiting behind a code-fence paste is pasted
    /// (#1664), with the audio recorded up to the stop. The wait counts
    /// as finalizing on every stop path, so a new dictation takes the
    /// recovery that cancels it, and the transcript goes to History as not
    /// inserted.
    func finishLiveAutoPasteSessionAfterGoTo(
        sessionMode: DictationOutputMode,
        finish: @escaping @MainActor (_ sessionAudio: Data?) -> Void
    ) -> Bool {
        // The hold-back's tail first: released behind a paste, it waits too.
        if spokenCommandGate.action == nil, !wasCancelled {
            textInsertion.flushFinalLiveReplacementCorrections()
        }
        guard spokenCommandGate.action != nil || (!wasCancelled && textInsertion.pendingTextWaitsOnPaste) else { return false }
        isFinalizingStop = true
        statusText = StatusStrings.finalizing
        let sessionAudio = audio.sessionRecording.finish()
        let storedAudio = sessionStoresAudio ? sessionAudio : nil
        let startedAt = sessionStartedAt ?? Date()
        let provider = sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue
        let model = sessionModelName ?? settings.effectiveModelName
        let join = context.claudeSessionJoin.map(AgentCLIJoin.init)
        // The session's mod route, if any, settles after the go-to and
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
            // A go-to the queue started after the first one is waited for
            // too, or the cleanup would cancel it and drop what follows it.
            while let goTo = self?.spokenCommandGate.action {
                await goTo.value
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
    /// pending behind a paste, then the segments queued behind a go-to
    /// (#1882). Both are emptied, so nothing types them later. A queued
    /// final shaped like a voice command is kept: only its resolution, which
    /// never ran, could say it types nothing ("go to the tests" with no
    /// such session is typed as text).
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

    // MARK: - Acting

    /// A final go-to holds, or a queued one: a command acts, anything else
    /// goes on to the next phrase.
    func decideLiveGoToFinal(_ finalText: String, merged: String, startsMidWord: Bool) {
        // Only the backend's final names a session, as only it can trigger a
        // send: the accumulator's merge can hold words the final dropped.
        guard let navigator = sessionNavigator,
              let command = SessionVoiceCommandParser.command(in: finalText)
        else {
            passLiveSpokenCommandFinal(after: .goTo, finalText, merged: merged, startsMidWord: startsMidWord)
            return
        }
        // A voice command is a final that submits nothing: the same
        // submission after it is said again, not a duplicate final.
        spokenSendLatch.noteNonSubmittingFinal()
        let spokenName: String
        switch command {
        case .goTo(let name):
            spokenName = name
        case .nameThisSession(let nickname):
            if nameSession(nickname, sessionID: liveThisSessionID, navigator: navigator) {
                statusText = GoToSessionStatus.named
            } else {
                passLiveSpokenCommandFinal(after: .goTo, finalText, merged: merged, startsMidWord: startsMidWord)
            }
            return
        }
        spokenCommandGate.action = Task { @MainActor [weak self] in
            // Assigned before this body runs.
            let task = self?.spokenCommandGate.action
            let resolution = await navigator.resolve(spokenName: spokenName)
            guard let self, !Task.isCancelled else { return }
            switch resolution {
            case .unknown:
                Log.dictation.notice("live go to session: no live session has that name; typing it as text")
                self.passLiveSpokenCommandFinal(after: .goTo, finalText, merged: merged, startsMidWord: startsMidWord)
            case .ambiguous(let count):
                Log.dictation.notice("live go to session: \(count, privacy: .public) panes have that name; nothing done")
                self.statusText = GoToSessionStatus.ambiguous
            case .resolved(let session):
                // What the terminal hold-back still keeps belongs to the pane
                // it was dictated into, not to the one coming forward.
                self.textInsertion.flushFinalLiveReplacementCorrections()
                // A release that failed (insertion refused mid-dictation)
                // would be retried into the pane coming forward (#1663).
                if self.textInsertion.hasPendingInsertionText {
                    let undelivered = self.textInsertion.drainPendingInsertionText()
                    Log.dictation.notice(
                        "live go to session: \(undelivered.count, privacy: .public) chars not delivered before the focus; kept, not typed"
                    )
                    self.lastError = self.keepUndeliveredAgentText(undelivered)
                }
                let outcome = await navigator.focuser.focusPane(of: session)
                guard !Task.isCancelled else { return }
                Log.dictation.notice("live go to session: \(String(describing: outcome), privacy: .public)")
                switch outcome {
                case .focused:
                    // The relay writes into the pane the dictation started
                    // in; from here on the words go where the user went.
                    self.textInsertion.retirePromptRelay()
                    self.liveGoToLanding = .verified(sessionID: session.sessionID)
                case .unverified:
                    self.textInsertion.retirePromptRelay()
                    self.liveGoToLanding = .unverified
                case .paneNotFound, .unsupported:
                    break
                }
                if let status = Self.status(for: outcome) {
                    self.statusText = status
                }
            }
            // A name that resolved to nothing was delivered as a spoken send,
            // which may have started its own pane read-back: that action holds
            // the queue now and drains it when it is done.
            guard self.spokenCommandGate.action == task else { return }
            self.spokenCommandGate.action = nil
            self.drainLiveSpokenCommandQueue()
        }
    }
}
