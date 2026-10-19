import Foundation

/// The spoken commands Live Auto-Paste holds words back for (#1853).
enum LiveSpokenCommand: Equatable, Sendable {
    /// "Go to <name>" and "call this session <name>"
    /// (`DictationSessionController+LiveGoToSession.swift`).
    case goTo
    /// The spoken send trigger (`DictationSessionController+SpokenSend.swift`).
    case send
}

/// Live Auto-Paste's one hold-back (#1853): every partial, final and
/// promotion goes through `spokenCommandGate`, which says whether its words
/// are typed now, held, or decided by a command. Typed words cannot be
/// taken back, so a segment that may still be a command is held. Each
/// command arms itself, acts on a final and types the text it lets go in
/// its own file; this one routes between them.
extension DictationSessionController {
    /// The phrase table, in the order the phrases claim a segment. Go-to
    /// comes first: a segment it holds reaches the send trigger only once
    /// it is known not to be a go-to (#747).
    nonisolated static let liveSpokenCommandRules: [SpokenCommandRule<LiveSpokenCommand>] = [
        SpokenCommandRule(
            phrase: .goTo,
            hold: .whileOpening(SessionVoiceCommandParser.segmentPrefix),
            claimsUnheldFinal: { SessionVoiceCommandParser.command(in: $0) != nil }
        ),
        SpokenCommandRule(phrase: .send, hold: .wholeSegment, claimsUnheldFinal: { _ in true }),
    ]

    /// Session start and end: nothing carries over.
    func resetLiveSpokenCommandsForSession() {
        spokenCommandGate.reset()
        liveGoToLanding = nil
    }

    /// Asked when a segment reaches `phrase`, from the world as it is then.
    private func liveSpokenCommandIsArmed(_ phrase: LiveSpokenCommand) -> Bool {
        switch phrase {
        case .goTo: liveGoToIsArmed
        case .send: liveSpokenSendIsArmed
        }
    }

    // MARK: - The three hooks

    func gateLivePartial(_ delta: String) {
        switch spokenCommandGate.partial(delta, isArmed: { liveSpokenCommandIsArmed($0) }) {
        case .withhold:
            break
        case .deliver:
            typeLivePartial(delta)
        case .release(let held):
            typeLivePartial(held)
        }
    }

    func gateLiveFinal(_ finalText: String, finalized: TranscriptAccumulator.FinalizedSegment) {
        let verdict = spokenCommandGate.final(
            finalText,
            merged: finalized.text,
            startsMidWord: finalized.startsMidWord,
            isArmed: { liveSpokenCommandIsArmed($0) }
        )
        switch verdict {
        case .queued:
            break
        case .decide(let rule):
            decideLiveSpokenCommand(rule: rule, finalText, merged: finalized.text, startsMidWord: finalized.startsMidWord)
        case .deliver:
            if let liveInsertion = finalized.liveInsertion {
                textInsertion.enqueueRealtimeInsertion(liveInsertion)
                noteLiveTextTyped(liveInsertion)
            }
            if let accessibilityError = textInsertion.lastAccessibilityError {
                lastError = accessibilityError
            }
        }
    }

    /// Held words are typed nowhere else: a promotion (stop, dropped
    /// socket) stands in for the final they never got, and they are text,
    /// never a command.
    func gateLivePromotion(_ segment: String, startsMidWord: Bool) {
        switch spokenCommandGate.promotion(segment, startsMidWord: startsMidWord) {
        case .queued, .delivered:
            break
        case .held(let rule):
            deliverHeldLivePromotion(rule: rule, segment, startsMidWord: startsMidWord)
        }
    }

    // MARK: - Routing

    private func decideLiveSpokenCommand(rule: Int, _ finalText: String, merged: String, startsMidWord: Bool) {
        switch spokenCommandGate.rules[rule].phrase {
        case .goTo:
            decideLiveGoToFinal(finalText, merged: merged, startsMidWord: startsMidWord)
        case .send:
            deliverLiveSpokenSendFinal(finalText, merged: merged, startsMidWord: startsMidWord)
        }
    }

    /// `phrase` lets a held final go: the next armed phrase decides it, or
    /// it is typed whole.
    func passLiveSpokenCommandFinal(
        after phrase: LiveSpokenCommand,
        _ finalText: String,
        merged: String,
        startsMidWord: Bool
    ) {
        guard let next = nextArmedLiveSpokenCommand(after: phrase) else {
            typeLiveSpokenSendText(merged, startsMidWord: startsMidWord)
            return
        }
        decideLiveSpokenCommand(rule: next, finalText, merged: merged, startsMidWord: startsMidWord)
    }

    private func deliverHeldLivePromotion(rule: Int, _ segment: String, startsMidWord: Bool) {
        let phrase = spokenCommandGate.rules[rule].phrase
        switch phrase {
        case .goTo:
            guard let next = nextArmedLiveSpokenCommand(after: phrase) else {
                typeLiveSpokenSendText(segment, startsMidWord: startsMidWord)
                return
            }
            deliverHeldLivePromotion(rule: next, segment, startsMidWord: startsMidWord)
        case .send:
            spokenSendLatch.noteNonSubmittingFinal()
            typeLiveSpokenSendText(segment, startsMidWord: startsMidWord)
        }
    }

    private func nextArmedLiveSpokenCommand(after phrase: LiveSpokenCommand) -> Int? {
        guard let rule = spokenCommandGate.rules.firstIndex(where: { $0.phrase == phrase }) else { return nil }
        return spokenCommandGate.nextArmedRule(after: rule, isArmed: { liveSpokenCommandIsArmed($0) })
    }

    /// Delivers the segments that waited, until one of them starts an
    /// action of its own: a go-to, or a spoken send that reads its pane back.
    func drainLiveSpokenCommandQueue() {
        while let next = spokenCommandGate.nextQueued() {
            switch next {
            case .final(let finalText, let merged, let startsMidWord):
                decideLiveSpokenCommand(rule: 0, finalText, merged: merged, startsMidWord: startsMidWord)
            case .promoted(let segment, let startsMidWord):
                deliverHeldLivePromotion(rule: 0, segment, startsMidWord: startsMidWord)
            }
        }
    }

    private func typeLivePartial(_ text: String) {
        textInsertion.enqueueRealtimeInsertion(text)
        noteLiveTextTyped(text)
        if let accessibilityError = textInsertion.lastAccessibilityError {
            lastError = accessibilityError
        }
    }
}
