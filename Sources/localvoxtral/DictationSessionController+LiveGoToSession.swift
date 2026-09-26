import ClaudeContextWire
import Foundation
import os

/// Where a Live Auto-Paste segment stands with "go to <name>" (#747).
enum LiveGoToSegmentMode {
    /// No delta of this segment has arrived.
    case undecided
    /// Held: what was heard so far may still read "go to".
    case holding
    /// Held until the final: it opens with "go to".
    case possibleCommand
    /// Held: a go-to ahead of it has not finished.
    case behindGoTo
    /// Not a go-to: typed as if there were no hold-back.
    case passThrough
}

/// A segment that ended while a go-to was resolving or focusing.
enum LiveGoToQueuedSegment {
    case final(String, merged: String, startsMidWord: Bool)
    case promoted(String, startsMidWord: Bool)
}

/// "Go to <name>" in Live Auto-Paste (#747): a segment that is only that
/// phrase, naming a live joined session, brings its pane forward instead of
/// being typed. Words are typed as they stream and cannot be taken back, so a
/// segment is held while what was heard can still read "go to", and one that
/// opens with it is held until its final. Anything else is released at once:
/// "Good" is typed as soon as the third letter rules out "go to". Nothing is
/// held while no session is live. Segments that end while the pane comes
/// forward wait, then land in it. The name lookup and the focus are Overlay
/// Buffer's (`SessionNavigator`, `SessionPaneFocusing`).
extension DictationSessionController {
    /// Session start: nothing carries over.
    func resetLiveGoToForSession() {
        liveGoToTask?.cancel()
        liveGoToTask = nil
        liveGoToQueuedSegments = []
        liveGoToSegmentMode = .undecided
        liveGoToHeldText = ""
    }

    /// A partial. True when the go-to hold-back took it: nothing else may
    /// type it.
    func liveGoToHoldsPartial(_ delta: String) -> Bool {
        if liveGoToSegmentMode == .undecided {
            if liveGoToTask != nil {
                liveGoToSegmentMode = .behindGoTo
            } else if sessionNavigator?.hasLiveSessions == true {
                liveGoToSegmentMode = .holding
            } else {
                liveGoToSegmentMode = .passThrough
            }
        }
        switch liveGoToSegmentMode {
        case .passThrough, .undecided:
            return false
        case .behindGoTo:
            liveGoToHeldText += delta
            return true
        case .holding, .possibleCommand:
            liveGoToHeldText += delta
            switch GoToSessionCommandParser.segmentPrefix(liveGoToHeldText) {
            case .undecided:
                liveGoToSegmentMode = .holding
            case .possibleCommand:
                liveGoToSegmentMode = .possibleCommand
            case .ordinary:
                releaseLiveGoToHeldPartials()
            }
            return true
        }
    }

    /// A final. True when the go-to hold-back delivered it.
    func liveGoToHandlesFinal(_ finalText: String, merged: String, startsMidWord: Bool) -> Bool {
        let mode = liveGoToSegmentMode
        liveGoToSegmentMode = .undecided
        liveGoToHeldText = ""
        switch mode {
        case .passThrough:
            return false
        case .undecided:
            // A final with no partial before it.
            if liveGoToTask != nil {
                liveGoToQueuedSegments.append(.final(finalText, merged: merged, startsMidWord: startsMidWord))
                return true
            }
            guard sessionNavigator?.hasLiveSessions == true,
                  GoToSessionCommandParser.spokenName(in: finalText) != nil
            else { return false }
        case .behindGoTo where liveGoToTask != nil:
            liveGoToQueuedSegments.append(.final(finalText, merged: merged, startsMidWord: startsMidWord))
            return true
        case .behindGoTo, .holding, .possibleCommand:
            break
        }
        decideLiveGoToFinal(finalText, merged: merged, startsMidWord: startsMidWord)
        return true
    }

    /// A held segment promoted without a final (stop, dropped socket): text,
    /// never a command, as with the spoken send trigger. True when the go-to
    /// hold-back delivered it.
    func liveGoToHandlesPromotion(_ segment: String, startsMidWord: Bool) -> Bool {
        let mode = liveGoToSegmentMode
        liveGoToSegmentMode = .undecided
        liveGoToHeldText = ""
        switch mode {
        case .passThrough, .undecided:
            return false
        case .behindGoTo where liveGoToTask != nil:
            liveGoToQueuedSegments.append(.promoted(segment, startsMidWord: startsMidWord))
        case .behindGoTo, .holding, .possibleCommand:
            typeLiveGoToHeldSegment(segment, startsMidWord: startsMidWord)
        }
        return true
    }

    /// Stop: the session finishes once every go-to and the segments behind
    /// them are done, with the audio recorded up to the stop. The wait counts
    /// as finalizing on every stop path, so a new dictation takes the
    /// recovery that cancels it, and the transcript goes to History as not
    /// inserted.
    func finishLiveAutoPasteSessionAfterGoTo(
        sessionMode: DictationOutputMode,
        finish: @escaping @MainActor (_ sessionAudio: Data?) -> Void
    ) -> Bool {
        guard liveGoToTask != nil else { return false }
        isFinalizingStop = true
        statusText = StatusStrings.finalizing
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
            // A go-to the queue started after the first one is waited for
            // too, or the cleanup would cancel it and drop what follows it.
            while let goTo = self?.liveGoToTask {
                await goTo.value
                guard !Task.isCancelled else { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.saveInterruptedPolishCommit = nil
            finish(sessionAudio)
        }
        return true
    }

    // MARK: - Private

    /// The segment turned out not to be a go-to: what was held is typed as
    /// the partials would have been, unless the spoken send trigger withholds
    /// the segment, and then its final types it whole.
    private func releaseLiveGoToHeldPartials() {
        liveGoToSegmentMode = .passThrough
        let held = liveGoToHeldText
        liveGoToHeldText = ""
        guard !liveSpokenSendWithholdsSegment() else { return }
        textInsertion.enqueueRealtimeInsertion(held)
        noteLiveTextTyped(held)
        if let accessibilityError = textInsertion.lastAccessibilityError {
            lastError = accessibilityError
        }
    }

    private func decideLiveGoToFinal(_ finalText: String, merged: String, startsMidWord: Bool) {
        // Only the backend's final names a session, as only it can trigger a
        // send: the accumulator's merge can hold words the final dropped.
        guard let navigator = sessionNavigator,
              let spokenName = GoToSessionCommandParser.spokenName(in: finalText)
        else {
            deliverLiveGoToHeldFinal(finalText, merged: merged, startsMidWord: startsMidWord)
            return
        }
        liveGoToTask = Task { @MainActor [weak self] in
            let resolution = await navigator.resolve(spokenName: spokenName)
            guard let self, !Task.isCancelled else { return }
            switch resolution {
            case .unknown:
                Log.dictation.notice("live go to session: no live session has that name; typing it as text")
                self.deliverLiveGoToHeldFinal(finalText, merged: merged, startsMidWord: startsMidWord)
            case .ambiguous(let count):
                Log.dictation.notice("live go to session: \(count, privacy: .public) panes have that name; nothing done")
                self.statusText = GoToSessionStatus.ambiguous
            case .resolved(let session):
                // What the terminal hold-back still keeps belongs to the pane
                // it was dictated into, not to the one coming forward.
                self.textInsertion.flushFinalLiveReplacementCorrections()
                let outcome = await navigator.focuser.focusPane(of: session)
                guard !Task.isCancelled else { return }
                Log.dictation.notice("live go to session: \(String(describing: outcome), privacy: .public)")
                switch outcome {
                case .focused, .unverified:
                    // The relay writes into the pane the dictation started
                    // in; from here on the words go where the user went.
                    self.textInsertion.endPromptRelay()
                case .paneNotFound, .unsupported:
                    break
                }
                if let status = Self.status(for: outcome) {
                    self.statusText = status
                }
            }
            self.liveGoToTask = nil
            self.drainLiveGoToQueue()
        }
    }

    /// Delivers the segments that waited, until one of them is itself a
    /// go-to.
    private func drainLiveGoToQueue() {
        while liveGoToTask == nil, !liveGoToQueuedSegments.isEmpty {
            switch liveGoToQueuedSegments.removeFirst() {
            case .final(let finalText, let merged, let startsMidWord):
                decideLiveGoToFinal(finalText, merged: merged, startsMidWord: startsMidWord)
            case .promoted(let segment, let startsMidWord):
                typeLiveGoToHeldSegment(segment, startsMidWord: startsMidWord)
            }
        }
    }

    /// A held final that is not a command: typed whole, through the spoken
    /// send trigger when it withholds the segment.
    private func deliverLiveGoToHeldFinal(_ finalText: String, merged: String, startsMidWord: Bool) {
        if liveSpokenSendWithholdsSegment() {
            deliverLiveSpokenSendFinal(finalText, merged: merged, startsMidWord: startsMidWord)
            return
        }
        liveSpokenSendSegmentMode = .undecided
        typeLiveSpokenSendText(merged, startsMidWord: startsMidWord)
    }

    private func typeLiveGoToHeldSegment(_ segment: String, startsMidWord: Bool) {
        if liveSpokenSendWithholdsSegment() {
            deliverPromotedLiveSpokenSendSegment(segment, startsMidWord: startsMidWord)
            return
        }
        liveSpokenSendSegmentMode = .undecided
        typeLiveSpokenSendText(segment, startsMidWord: startsMidWord)
    }
}
