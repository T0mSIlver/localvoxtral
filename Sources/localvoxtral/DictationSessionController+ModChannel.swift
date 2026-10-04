import ClaudeContextWire
import Foundation

/// Overlay Buffer commits into a Claude Code session's prompt box through
/// its mod (#1409): `$.prompt.fill` puts the text at the cursor, with no key
/// posted. A fill that surely did not land gives the text back to the
/// keyboard, the way the opencode prompt relay does, and only while keys
/// would still reach the session's prompt.
extension DictationSessionController {
    /// How long a fill may take before it counts as unanswered: longer than
    /// the mod gives its own reply (3 s), so a slow reply is not mistaken
    /// for a lost one.
    static let modChannelFillTimeout: Duration = .seconds(5)

    /// The committer that fills `join`'s session through its mod, or nil:
    /// no mod attached, a session that is not a local Claude Code one, or a
    /// surface where a fill is not yet known to show (Claude Desktop, a
    /// browser tab), which keep inserting by keyboard until a hand check
    /// says otherwise.
    func modChannelCommitter(join: ClaudeSessionJoin?, targetPID: pid_t?) -> ModChannelOverlayCommitter? {
        guard let join, let hub = context.claudeModChannels,
              join.snapshot.agent == .claude,
              join.snapshot.origin.isLocalAuthenticated
        else { return nil }
        let localTerminal: [ClaudeSessionJoinMechanism] = [.ttyDevice, .herdrPane, .cmuxSurface]
        guard localTerminal.contains(join.mechanism) else { return nil }
        let sessionID = join.snapshot.sessionID
        guard hub.isAttached(sessionID) else { return nil }
        Log.overlay.info("overlay commit: through the session's mod")
        let generation = sessionStartGeneration
        return ModChannelOverlayCommitter(
            hub: hub,
            sessionID: sessionID,
            notFilled: { [weak self] text, pid, mayHaveLanded in
                await self?.commitOverlayTextTheModDidNotFill(
                    text, preferredAppPID: pid, sessionID: sessionID, terminalPID: targetPID,
                    mayHaveLanded: mayHaveLanded, generation: generation
                )
            }
        )
    }

    /// The text of a fill the mod did not confirm. One that may have landed
    /// is kept (`keepUndeliveredAgentText`) rather than going in twice. One
    /// that surely did not is typed, but only while the commit's terminal is
    /// frontmost and its focused pane still shows the session: a pid cannot
    /// tell two tabs apart, and the user may have switched since the stop.
    /// Unless keys put the text in the prompt, the next commit does not
    /// continue it.
    func commitOverlayTextTheModDidNotFill(
        _ text: String,
        preferredAppPID pid: pid_t?,
        sessionID: String,
        terminalPID: pid_t?,
        mayHaveLanded: Bool,
        generation: UInt64
    ) async {
        var inserted = false
        if sessionStartGeneration != generation {
            keepOverlayTextOfARetiredDictation(text, sessionID: sessionID)
            return
        }
        if mayHaveLanded {
            lastError = keepUndeliveredAgentText(text)
        } else if await keysReachModSession(sessionID, terminalPID: terminalPID) {
            // The read-back awaited: the next dictation may have started.
            guard sessionStartGeneration == generation else {
                keepOverlayTextOfARetiredDictation(text, sessionID: sessionID)
                return
            }
            inserted = commitOverlayTextThePromptRelayRefused(text, preferredAppPID: pid, sessionID: sessionID)
        } else {
            Log.overlay.notice(
                "overlay commit: the mod did not fill and the session's pane is not in front; text kept"
            )
            lastError = keepUndeliveredAgentText(text)
        }
        if !inserted, lastOverlayCommitLanding?.sessionID == sessionID {
            lastOverlayCommitLanding = nil
        }
    }

    /// Whether a key typed now would reach `sessionID`'s prompt: `terminalPID`
    /// is frontmost and its focused pane shows the session. The local
    /// questions only (the focused tty, a local herdr's focused pane), so a
    /// cmux surface answers no and keeps its text. The caller types without
    /// awaiting again.
    private func keysReachModSession(_ sessionID: String, terminalPID: pid_t?) async -> Bool {
        guard let terminalPID, let resolver = context.claudeSessionJoinResolver,
              let target = TerminalScreenContextSource.frontmostTarget(), target.pid == terminalPID,
              await resolver.sessionShown(target: target) == sessionID
        else { return false }
        // The pane lookup awaited: another app may have come forward since.
        return TerminalScreenContextSource.frontmostTarget()?.pid == terminalPID
    }
}

/// Commits the overlay by asking the session's mod to fill its prompt box.
/// The fill is handed off, not awaited. A refusal, or a request the mod
/// never got, goes to `notFilled` as surely not landed. A request the mod
/// got and did not answer may still have filled the box, and goes there as
/// maybe landed (`docs/agent/invariants.md`, as for the opencode relay).
/// Secure Keyboard Entry does not stop it, since no key is posted.
@MainActor
final class ModChannelOverlayCommitter: OverlayTextCommitting {
    private let hub: ClaudeModChannelHub
    private let sessionID: String
    /// The text, the pid the commit named, and whether the fill may have
    /// landed.
    private let notFilled: @MainActor (String, pid_t?, Bool) async -> Void

    init(
        hub: ClaudeModChannelHub,
        sessionID: String,
        notFilled: @escaping @MainActor (String, pid_t?, Bool) async -> Void
    ) {
        self.hub = hub
        self.sessionID = sessionID
        self.notFilled = notFilled
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
        let notFilled = notFilled
        Task { @MainActor in
            let exchange = await hub.exchange(
                .init(kind: .fill, text: text),
                with: sessionID,
                timeout: DictationSessionController.modChannelFillTimeout
            )
            let filled = exchange.reply?.ok == true
            switch exchange {
            case .replied(let reply) where reply.ok:
                Log.overlay.info("overlay commit: the mod filled the prompt box")
            case .replied(let reply):
                Log.overlay.notice(
                    "overlay commit: the mod did not fill (\(reply.reason ?? "no reason", privacy: .public)); keyboard instead"
                )
                await notFilled(text, preferredAppPID, false)
            case .notDelivered:
                Log.overlay.notice("overlay commit: the fill never reached the mod; keyboard instead")
                await notFilled(text, preferredAppPID, false)
            case .unanswered:
                Log.overlay.error("overlay commit: the mod did not answer the fill; text kept")
                await notFilled(text, preferredAppPID, true)
            }
            #if DEBUG
            ModChannelOverlayCommitter.debugFillSettled?(filled)
            #endif
        }
        return .insertedByAccessibility
    }

    func pasteUsingCommandV(_: String, preferredAppPID _: pid_t?) -> Bool {
        false
    }
}
