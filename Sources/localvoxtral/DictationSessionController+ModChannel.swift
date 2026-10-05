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
        static let unanswered = "In the prompt box; it may not be sent"
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
        let generation = sessionStartGeneration
        return ModChannelOverlayCommitter(
            hub: hub,
            sessionID: sessionID,
            submits: submits,
            settled: { [weak self] text, pid, outcome in
                await self?.modChannelCommitSettled(
                    outcome, text: text, preferredAppPID: pid, sessionID: sessionID, terminalPID: targetPID,
                    submits: submits, generation: generation
                )
            }
        )
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
    func modChannelCommitSettled(
        _ outcome: ModChannelCommitOutcome,
        text: String,
        preferredAppPID pid: pid_t?,
        sessionID: String,
        terminalPID: pid_t?,
        submits: Bool,
        generation: UInt64
    ) async {
        switch outcome {
        case .filled, .sent:
            break
        case .queued:
            lastError = ModChannelStatus.queued
        case .filledNotSent:
            lastError = ModChannelStatus.filledNotSent
        case .notRestored:
            lastError = ModChannelStatus.notRestored
        case .refused, .unanswered:
            let typed = await commitOverlayTextTheModDidNotFill(
                text, preferredAppPID: pid, sessionID: sessionID, terminalPID: terminalPID,
                mayHaveLanded: outcome == .unanswered, generation: generation
            )
            // The keys went in while the session's pane was in front, with
            // nothing awaited since: Return follows under the spoken send's
            // own gates.
            guard submits, typed, let terminalPID else { return }
            guard returnSubmitsPrompt(inPID: terminalPID) else {
                Log.dictation.notice("spoken send: Return does not submit in the target app; no Return")
                return
            }
            _ = pressSpokenSendReturn(pid: terminalPID)
        }
    }

    /// The text of a fill the mod did not confirm. One that may have landed
    /// is kept (`keepUndeliveredAgentText`) rather than going in twice. One
    /// that surely did not is typed, but only while the commit's terminal is
    /// frontmost and its focused pane still shows the session: a pid cannot
    /// tell two tabs apart, and the user may have switched since the stop.
    /// Unless keys put the text in the prompt, the next commit does not
    /// continue it.
    ///
    /// - Returns: whether keys put the text in.
    @discardableResult
    func commitOverlayTextTheModDidNotFill(
        _ text: String,
        preferredAppPID pid: pid_t?,
        sessionID: String,
        terminalPID: pid_t?,
        mayHaveLanded: Bool,
        generation: UInt64
    ) async -> Bool {
        var inserted = false
        if sessionStartGeneration != generation {
            keepOverlayTextOfARetiredDictation(text, sessionID: sessionID, generation: generation)
            return false
        }
        if mayHaveLanded {
            lastError = keepUndeliveredAgentText(text)
        } else if await keysReachModSession(sessionID, terminalPID: terminalPID) {
            // The read-back awaited: the next dictation may have started.
            guard sessionStartGeneration == generation else {
                keepOverlayTextOfARetiredDictation(text, sessionID: sessionID, generation: generation)
                return false
            }
            inserted = commitOverlayTextThePromptRelayRefused(
                text, preferredAppPID: pid, sessionID: sessionID, generation: generation
            )
        } else {
            Log.overlay.notice(
                "overlay commit: the mod did not fill and the session's pane is not in front; text kept"
            )
            lastError = keepUndeliveredAgentText(text)
        }
        if !inserted {
            forgetLanding(ofSession: sessionID, generation: generation)
        }
        return inserted
    }

    /// Whether a key typed now would reach `sessionID`'s prompt: `terminalPID`
    /// is frontmost and its focused pane shows the session. The local
    /// questions only (the focused tty, a local herdr's focused pane), so a
    /// cmux surface answers no and keeps its text. The caller types without
    /// awaiting again.
    private func keysReachModSession(_ sessionID: String, terminalPID: pid_t?) async -> Bool {
        guard let terminalPID, let resolver = context.claudeSessionJoinResolver,
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

/// Commits the overlay by asking the session's mod to fill its prompt box,
/// and with `submits` to submit it (#1644). The request is handed off, not
/// awaited. A refusal, or a request the mod never got, settles as surely
/// not landed. A request the mod got and did not answer may still have
/// filled the box, and settles as maybe landed (`docs/agent/invariants.md`,
/// as for the opencode relay). Secure Keyboard Entry does not stop it,
/// since no key is posted.
@MainActor
final class ModChannelOverlayCommitter: OverlayTextCommitting {
    private let hub: ClaudeModChannelHub
    private let sessionID: String
    private let submits: Bool
    /// The text, the pid the commit named, and how it ended.
    private let settled: @MainActor (String, pid_t?, ModChannelCommitOutcome) async -> Void

    init(
        hub: ClaudeModChannelHub,
        sessionID: String,
        submits: Bool = false,
        settled: @escaping @MainActor (String, pid_t?, ModChannelCommitOutcome) async -> Void
    ) {
        self.hub = hub
        self.sessionID = sessionID
        self.submits = submits
        self.settled = settled
    }

    #if DEBUG
    /// Test seam: called once a fill settles, with whether the mod filled.
    static var debugFillSettled: (@MainActor (Bool) -> Void)?
    #endif

    var isAccessibilityTrusted: Bool { true }
    var postsNoKeys: Bool { true }

    func insertTextPrioritizingKeyboard(_ text: String, preferredAppPID: pid_t?) -> TextInsertResult {
        let hub = hub
        let sessionID = sessionID
        let submits = submits
        let settled = settled
        Task { @MainActor in
            let exchange = await hub.exchange(
                .init(kind: submits ? .send : .fill, text: text),
                with: sessionID,
                timeout: DictationSessionController.modChannelFillTimeout
            )
            let outcome = Self.outcome(of: exchange, submits: submits)
            switch outcome {
            case .filled:
                Log.overlay.info("overlay commit: the mod filled the prompt box")
            case .sent:
                Log.overlay.info("overlay commit: the mod filled and submitted the prompt")
            case .queued:
                Log.overlay.info("overlay commit: the mod filled the prompt; its submit waits for the running turn")
            case .filledNotSent:
                Log.overlay.notice(
                    "overlay commit: the mod filled but did not submit (\(exchange.reply?.reason ?? "no reason", privacy: .public))"
                )
            case .notRestored:
                Log.overlay.notice("overlay commit: the mod's submit was dropped and the box did not take the text back")
            case .refused:
                Log.overlay.notice(
                    "overlay commit: the mod did not fill (\(exchange.reply?.reason ?? "not delivered", privacy: .public)); keyboard instead"
                )
            case .unanswered:
                Log.overlay.error("overlay commit: the mod did not answer; text kept")
            }
            await settled(text, preferredAppPID, outcome)
            #if DEBUG
            ModChannelOverlayCommitter.debugFillSettled?([.filled, .sent, .queued, .filledNotSent, .notRestored].contains(outcome))
            #endif
        }
        return .insertedByAccessibility
    }

    func pasteUsingCommandV(_: String, preferredAppPID _: pid_t?) -> Bool {
        false
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
