import ClaudeContextWire
import Foundation
import os

/// "Send that to <name>" into a local Claude Code session through its mod
/// (#1693; owner ruling 2026-10-04, overriding #723's focus-before-Return
/// for these sessions only): the mod fills at its cursor and submits, by
/// session id, so the pane need not be in front and no key is posted. A mod
/// that refused, or never got the request, leaves the send to the session's
/// usual route. docs/agent/invariants.md, "Send that to <name> writes only
/// into the named session".
extension DictationSessionController {
    /// How an addressed send through the mod ended.
    enum AddressedModSend {
        /// Done, or kept: the usual route must not run.
        case finished(AddressedCommit)
        /// The mod refused or never got it: nothing changed in the session.
        case fallBack
        /// A new dictation cancelled it before the text was handed over.
        case cancelled
    }

    /// Whether the named session's mod takes the send: a Claude Code session
    /// with its mod attached, outside Claude Desktop, where a fill is not
    /// yet known to show (#1643). A remote session's mod counts once it
    /// polls through the forward (#1412); a refusal there keeps the text,
    /// since a remote session has no other addressed route.
    func addressedSendGoesThroughMod(_ session: ClaudeSessionSnapshot) -> Bool {
        guard let hub = context.claudeModChannels,
              session.agent == .claude,
              session.desktopSessionID == nil
        else { return false }
        return hub.isAttached(session.sessionID)
    }

    /// Reads the session's prompt box for the leading space, hands the
    /// overlay's text to the mod's `send`, and maps its answer. A reply the
    /// mod got and did not give may have submitted, so it is kept, never sent
    /// again another way; a `session_changed` refusal is kept too, since the
    /// pane now shows another session (#1651).
    func commitOverlayAddressedThroughMod(session: ClaudeSessionSnapshot) async -> AddressedModSend {
        guard let hub = context.claudeModChannels else { return .fallBack }
        let sessionID = session.sessionID
        // The dictation that sends: a reply that comes after a new one
        // committed must not forget that one's landing.
        let generation = sessionStartGeneration
        let read = await hub.readPromptDraft(of: sessionID, timeout: ClaudePromptDraft.readTimeout)
        guard !Task.isCancelled else { return .cancelled }
        // A detach without a clean bye leaves the session's registry entry,
        // whose tty and pid still match the pane after `/clear`: the usual
        // route would type into the session that replaced it.
        guard case .read(let draft) = read else {
            Log.backends.error("send to session: the mod's process left that session; nothing sent, text kept")
            saveInterruptedPolishCommit = nil
            return .finished(.notSent(AddressedSendStatus.notSent))
        }

        // The box decides the space; a mod that did not say what it holds
        // leaves the last commit's evidence, as for the typed route (#802).
        let needsSpace = draft?.commitNeedsLeadingSpace ?? lastCommitContinuesPrompt(of: session)
        let capture = CapturingOverlayCommitter()
        let committer: any OverlayTextCommitting = needsSpace ? LeadingSpaceOverlayCommitter(base: capture) : capture
        let commit = StopCommitCoordinator.commit(
            overlay: overlayBufferCoordinator,
            textInsertion: committer,
            autoCopyEnabled: settings.autoCopyEnabled
        )
        guard let text = capture.text else { return .fallBack }
        // Handed over: a cancel from here no longer saves the record, and
        // a quit does (#1667), until a refusal gives the text back to the
        // usual route.
        let saveIfInterrupted = saveInterruptedPolishCommit
        saveInterruptedPolishCommit = nil
        let handedOff = handOffAddressedCommit(saveNotInserted: saveIfInterrupted, releasesEscape: true)

        let exchange = await hub.exchange(
            .init(kind: .send, text: text), with: sessionID, timeout: Self.modChannelFillTimeout
        )
        let superseded = Task.isCancelled
        switch exchange {
        case .replied(let reply) where reply.ok:
            if reply.submitted == true {
                forgetOverlayCommitLanding(inSession: sessionID, committedBy: generation)
                let queued = reply.queued == true
                Log.dictation.notice("send to session: the mod submitted queued=\(queued, privacy: .public)")
                return .finished(AddressedCommit(
                    outcome: commit.outcome, inserted: true,
                    status: queued ? ModChannelStatus.queued : nil,
                    superseded: superseded, handedOff: handedOff
                ))
            }
            Log.backends.notice(
                "send to session: the mod filled but did not submit (\(reply.reason ?? "no reason", privacy: .public))"
            )
            return .finished(AddressedCommit(
                outcome: commit.outcome, inserted: true, status: ModChannelStatus.filledNotSent,
                superseded: superseded, handedOff: handedOff
            ))
        case .replied(let reply) where reply.reason == ClaudeModChannelWire.Reply.sessionChangedReason:
            Log.backends.error("send to session: the mod's process left that session; nothing sent, text kept")
            return .finished(AddressedCommit(
                outcome: commit.outcome, inserted: false, status: AddressedSendStatus.notSent,
                superseded: superseded, handedOff: handedOff
            ))
        case .unanswered:
            Log.backends.error("send to session: the mod did not answer; it may have submitted, so the text is kept")
            return .finished(AddressedCommit(
                outcome: commit.outcome, inserted: false, status: AddressedSendStatus.notSent,
                superseded: superseded, handedOff: handedOff
            ))
        case .replied(let reply):
            Log.backends.error(
                "send to session: the mod refused (\(reply.reason ?? "no reason", privacy: .public)); the session's own route instead"
            )
        case .notDelivered:
            Log.backends.error("send to session: the mod did not get the request; the session's own route instead")
        }
        // A new dictation owns the keys now: no route may focus or type.
        guard !superseded else {
            return .finished(AddressedCommit(
                outcome: commit.outcome, inserted: false, status: AddressedSendStatus.notSent, superseded: true,
                handedOff: handedOff
            ))
        }
        takeBackAddressedCommit(handedOff)
        saveInterruptedPolishCommit = saveIfInterrupted
        return .fallBack
    }
}

/// Takes the overlay's commit text and inserts nothing, so the caller can
/// hand it to the mod and still commit through another route if the mod
/// refuses.
@MainActor
final class CapturingOverlayCommitter: OverlayTextCommitting {
    private(set) var text: String?

    var isAccessibilityTrusted: Bool { true }
    var postsNoKeys: Bool { true }

    func insertTextPrioritizingKeyboard(_ text: String, preferredAppPID _: pid_t?) -> TextInsertResult {
        self.text = text
        return .insertedByAccessibility
    }

    func pasteUsingCommandV(_: String, preferredAppPID _: pid_t?) -> Bool {
        false
    }
}
