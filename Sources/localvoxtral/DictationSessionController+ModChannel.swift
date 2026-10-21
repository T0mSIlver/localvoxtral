import ClaudeContextWire
import Foundation

/// Overlay Buffer commits into a Claude Code session's prompt box through
/// its mod (#1409): `$.prompt.fill` puts the text at the cursor, with no key
/// posted. A fill that surely did not land gives the text back to the
/// keyboard, the way the opencode prompt relay does, and only while keys
/// would still reach the session's prompt. A spoken send asks the mod to
/// submit too (#1644).
extension DictationSessionController {
    enum ModChannelStatus {
        static let queued = "Sent; it runs after the current turn"
        static let filledNotSent = "In the prompt box, not sent"
        static let notRestored = "Not sent, and not back in the prompt box"
    }

    /// How long a fill may take before it counts as unanswered: longer than
    /// the mod gives its own reply (3 s), so a slow reply is not mistaken
    /// for a lost one.
    static let modChannelFillTimeout: Duration = .seconds(5)

    /// The committer that fills `join`'s session through its mod, or nil:
    /// no mod attached, a session that is not a local Claude Code one, or a
    /// surface the mod cannot fill: Claude Desktop's Code tab binds no box
    /// (`no_composer`, #1643), and a browser tab is unmeasured. Both keep
    /// inserting by keyboard.
    ///
    /// With `submits`, the mod submits the box after the fill, and a fill
    /// it refused is typed and followed by Return under the same gates as
    /// any spoken send's.
    func modChannelCommitter(
        join: ClaudeSessionJoin?, targetPID: pid_t?, submits: Bool = false
    ) -> ModChannelOverlayCommitter? {
        guard let hub = context.claudeModChannels, let sessionID = modChannelSessionID(join: join) else { return nil }
        Log.overlay.info("overlay commit: through the session's mod submits=\(submits, privacy: .public)")
        return ModChannelOverlayCommitter(
            hub: hub, sessionID: sessionID, terminalPID: targetPID, submits: submits, generation: sessionStartGeneration
        )
    }

    /// Hands `text` to `mod` and acts on its answer once it comes: the
    /// commit itself ends at the hand-off.
    func handOffOverlayCommit(_ text: String, to mod: ModChannelOverlayCommitter, preferredAppPID pid: pid_t?) {
        mod.handedOff = true
        Task { @MainActor [weak self] in
            let outcome = await mod.deliver(text)
            await self?.modChannelCommitSettled(outcome, text: text, preferredAppPID: pid, mod: mod)
            #if DEBUG
            ModChannelOverlayCommitter.debugFillSettled?(outcome.isDelivered)
            #endif
        }
    }

    /// The joined session whose mod takes the commit, or nil: no mod
    /// attached, or a join the mod may not fill
    /// (`ClaudePromptDraft.fillsPrompt`). A remote session's mod counts
    /// once it polls through the forward (#1412).
    func modChannelSessionID(join: ClaudeSessionJoin?) -> String? {
        guard let join, let hub = context.claudeModChannels,
              ClaudePromptDraft.fillsPrompt(through: join)
        else { return nil }
        let sessionID = join.snapshot.sessionID
        return hub.isAttached(sessionID) ? sessionID : nil
    }

    /// What the app does once the mod answered, or did not.
    private func modChannelCommitSettled(
        _ outcome: PromptDeliveryOutcome,
        text: String,
        preferredAppPID pid: pid_t?,
        mod: ModChannelOverlayCommitter
    ) async {
        switch outcome {
        case .delivered(let submitted, let status):
            // A lone send phrase's empty send submitted the box (#1870): the
            // landing of the fill before it no longer describes the prompt.
            if text.isEmpty, submitted {
                forgetOverlayCommitLanding(inSession: mod.sessionID, committedBy: mod.generation)
            }
            if let status {
                lastError = status
            }
        case .refused where text.isEmpty, .mayHaveLanded where text.isEmpty:
            await submitTheDraftTheModDidNotSend(
                outcome, sessionID: mod.sessionID, terminalPID: mod.terminalPID, generation: mod.generation
            )
        case .refused, .mayHaveLanded:
            // A fill that surely did not land is typed only while the
            // commit's terminal is frontmost and its focused pane still
            // shows the session: a pid cannot tell two tabs apart, and the
            // user may have switched since the stop.
            let keysReach = outcome == .refused
                ? await keysReachModSession(mod.sessionID, terminalPID: mod.terminalPID)
                : false
            let typed = settleUndeliveredOverlayText(
                text, outcome: outcome, keysReachPrompt: keysReach,
                sessionID: mod.sessionID, generation: mod.generation, preferredAppPID: pid
            )
            // The keys went in while the session's pane was in front, with
            // nothing awaited since: Return follows under the spoken send's
            // own gates.
            guard mod.submits, typed, let terminalPID = mod.terminalPID else { return }
            guard returnSubmitsPrompt(inPID: terminalPID) else {
                Log.dictation.notice("spoken send: Return does not submit in the target app; no Return")
                return
            }
            _ = pressSpokenSendReturn(pid: terminalPID)
        }
    }

    /// A lone send phrase the mod did not submit (#1870): there is no text
    /// to type or keep. A refusal changed nothing in the box, so Return
    /// submits it under the spoken send's gates, only while keys would reach
    /// the session's prompt. An unanswered send may have submitted, so no
    /// Return.
    private func submitTheDraftTheModDidNotSend(
        _ outcome: PromptDeliveryOutcome, sessionID: String, terminalPID: pid_t?, generation: UInt64
    ) async {
        guard outcome == .refused else {
            Log.dictation.notice("spoken send: the mod did not answer the submit; no Return")
            return
        }
        guard sessionStartGeneration == generation, let terminalPID,
              await keysReachModSession(sessionID, terminalPID: terminalPID),
              sessionStartGeneration == generation
        else {
            Log.dictation.notice("spoken send: the mod refused the submit and the session's pane is not in front; no Return")
            return
        }
        guard returnSubmitsPrompt(inPID: terminalPID) else {
            Log.dictation.notice("spoken send: Return does not submit in the target app; no Return")
            return
        }
        if pressSpokenSendReturn(pid: terminalPID) {
            forgetOverlayCommitLanding(inSession: sessionID, committedBy: generation)
        }
    }

    /// Whether a key typed now would reach `sessionID`'s prompt: `terminalPID`
    /// is frontmost and its focused pane shows the session. The local
    /// questions only (the focused tty, a local herdr's focused pane), so a
    /// cmux surface answers no and keeps its text. The caller types without
    /// awaiting again.
    private func keysReachModSession(_ sessionID: String, terminalPID: pid_t?) async -> Bool {
        // A permission or a question holds the pane: keys would answer it (#1914).
        guard sessionNavigator?.showsDialog(sessionID: sessionID) != true,
              let terminalPID, let resolver = context.claudeSessionJoinResolver,
              let target = TerminalScreenContextSource.frontmostTarget(), target.pid == terminalPID,
              await resolver.shows(sessionID, target: target)
        else { return false }
        // The pane lookup awaited: another app may have come forward since.
        return TerminalScreenContextSource.frontmostTarget()?.pid == terminalPID
    }
}

/// How a commit through the mod ended.
enum ModChannelCommitOutcome: Equatable {
    /// The box holds the text.
    case filled
    /// Filled and submitted.
    case sent
    /// Filled; the submit waits for the session's running turn.
    case queued
    /// Filled, and the submit did not happen: the text is in the box.
    case filledNotSent
    /// Filled, then a hook dropped the submit and the box did not take the
    /// text back (#1803): the mod keeps it, and no key types it.
    case notRestored
    /// The mod refused, or never got the request: nothing changed.
    case refused
    /// The mod got the request and did not answer: it may have landed.
    case unanswered
}

/// One overlay commit through the session's mod: `fill` puts the text at
/// the cursor, and with `submits` `send` submits it too (#1644). A refusal,
/// or a request the mod never got, is surely not landed. A request the mod
/// got and did not answer may still have filled the box
/// (`docs/agent/invariants.md`, as for the opencode relay). Secure Keyboard
/// Entry does not stop it, since no key is posted.
@MainActor
final class ModChannelOverlayCommitter {
    private let hub: ClaudeModChannelHub
    let sessionID: String
    /// The terminal the commit named: where a refused text may be typed.
    let terminalPID: pid_t?
    let submits: Bool
    /// The start generation of the dictation that commits: an answer that
    /// comes after the next dictation started is judged as this one's.
    let generation: UInt64
    /// Whether the commit handed this committer its text. The overlay
    /// commits nothing for an empty buffer, so a lone send phrase never does.
    var handedOff = false

    init(hub: ClaudeModChannelHub, sessionID: String, terminalPID: pid_t?, submits: Bool, generation: UInt64) {
        self.hub = hub
        self.sessionID = sessionID
        self.terminalPID = terminalPID
        self.submits = submits
        self.generation = generation
    }

    #if DEBUG
    /// Test seam: called once a fill settled, with whether the mod filled.
    static var debugFillSettled: (@MainActor (Bool) -> Void)?
    #endif

    func deliver(_ text: String) async -> PromptDeliveryOutcome {
        let exchange = await hub.exchange(
            .init(kind: submits ? .send : .fill, text: text),
            with: sessionID,
            timeout: DictationSessionController.modChannelFillTimeout
        )
        let outcome = Self.outcome(of: exchange, submits: submits)
        typealias Status = DictationSessionController.ModChannelStatus
        switch outcome {
        case .filled:
            Log.overlay.info("overlay commit: the mod filled the prompt box")
            return .delivered(submitted: false, status: nil)
        case .sent:
            Log.overlay.info("overlay commit: the mod filled and submitted the prompt")
            return .delivered(submitted: true, status: nil)
        case .queued:
            Log.overlay.info("overlay commit: the mod filled the prompt; its submit waits for the running turn")
            return .delivered(submitted: true, status: Status.queued)
        case .filledNotSent:
            Log.overlay.notice(
                "overlay commit: the mod filled but did not submit (\(exchange.reply?.reason ?? "no reason", privacy: .public))"
            )
            return .delivered(submitted: false, status: Status.filledNotSent)
        case .notRestored:
            Log.overlay.notice("overlay commit: the mod's submit was dropped and the box did not take the text back")
            return .delivered(submitted: false, status: Status.notRestored)
        case .refused:
            Log.overlay.notice(
                "overlay commit: the mod did not fill (\(exchange.reply?.reason ?? "not delivered", privacy: .public)); keyboard instead"
            )
            return .refused
        case .unanswered:
            Log.overlay.error("overlay commit: the mod did not answer; text kept")
            return .mayHaveLanded
        }
    }

    static func outcome(of exchange: ClaudeModChannelHub.Exchange, submits: Bool) -> ModChannelCommitOutcome {
        switch exchange {
        case .replied(let reply) where reply.ok:
            guard submits else { return .filled }
            guard reply.submitted == true else {
                return reply.reason == ClaudeModChannelWire.Reply.notRestoredReason ? .notRestored : .filledNotSent
            }
            return reply.queued == true ? .queued : .sent
        case .replied, .notDelivered:
            return .refused
        case .unanswered:
            return .unanswered
        }
    }
}
