import ClaudeContextWire
import Foundation
import os

/// A spoken stop phrase (#1696): an Overlay Buffer dictation that is only
/// one of the user's stop phrases ends the joined Claude Code session's
/// running turn through its mod (`$.turn.abort`). Only the joined session,
/// only with its mod attached, and never by a key: an Escape posted
/// anywhere else would cancel whatever that app was doing. Like go-to, the
/// phrase is a command: nothing is inserted and nothing goes to History.
/// docs/agent/invariants.md, "A stop phrase ends only the joined session's
/// turn".
extension DictationSessionController {
    enum SpokenAbortStatus {
        static let stopped = "Stopped Claude's turn"
        static let noTurn = "Claude had no turn running"
        static let noMod = "No Claude Code session with the mod"
        static let failed = "Couldn't stop Claude's turn"
    }

    /// Whether `text`, said alone, is one of the user's stop phrases.
    func isSpokenAbort(_ text: String) -> Bool {
        SpokenAbortPhrases.isStopPhrase(text, phrases: settings.spokenAbortPhrases)
    }

    /// Runs at stop, before every other spoken command, for a text the
    /// stop's second pass gave; the first pass's text is recognized before
    /// the destination guards. Returns true when the dictation is a stop
    /// phrase: the stop then ends as a command.
    func startSpokenAbortIfSpoken(
        sessionMode: DictationOutputMode,
        sample: OverlayStopSample
    ) -> Bool {
        guard isSpokenAbort(transcript.currentDictationEventText) else { return false }
        startSpokenAbort(sessionMode: sessionMode, join: sample.capture?.claudeJoin ?? context.claudeSessionJoin)
        return true
    }

    /// Asks `join`'s mod to end its turn and ends the stop as a command.
    func startSpokenAbort(sessionMode: DictationOutputMode, join: ClaudeSessionJoin?) {
        overlayBufferCoordinator.reset()
        guard let hub = context.claudeModChannels, let sessionID = modChannelSessionID(join: join) else {
            Log.backends.notice("stop phrase: no joined Claude Code session with its mod; nothing stopped, no key")
            finishSpokenAbort(sessionMode: sessionMode, status: SpokenAbortStatus.noMod)
            return
        }
        Log.dictation.notice("stop phrase: asking the joined session's mod to end its turn")
        polishAndCommitTask = Task { @MainActor [weak self] in
            let exchange = await hub.exchange(
                .init(kind: .abort), with: sessionID, timeout: Self.modChannelFillTimeout
            )
            guard let self, !Task.isCancelled else { return }
            self.finishSpokenAbort(sessionMode: sessionMode, status: Self.spokenAbortStatus(of: exchange))
        }
    }

    private func finishSpokenAbort(sessionMode: DictationOutputMode, status: String) {
        completeStoppedSessionCleanup(
            sessionMode: sessionMode,
            overlayCommitOutcome: nil,
            shouldCommitOverlay: true
        )
        statusText = status
    }

    /// The popover's sentence for the mod's answer, logged on the way.
    static func spokenAbortStatus(of exchange: ClaudeModChannelHub.Exchange) -> String {
        switch exchange {
        case .replied(let reply) where reply.ok:
            Log.dictation.notice("stop phrase: the mod ended the running turn")
            return SpokenAbortStatus.stopped
        case .replied(let reply) where reply.reason == ClaudeModChannelWire.Reply.noTurnReason:
            Log.dictation.notice("stop phrase: the session had no turn running")
            return SpokenAbortStatus.noTurn
        case .replied(let reply):
            Log.backends.error(
                "stop phrase: the mod refused (\(reply.reason ?? "no reason", privacy: .public)); nothing stopped, no key"
            )
            return SpokenAbortStatus.failed
        case .notDelivered:
            Log.backends.error("stop phrase: the mod did not get the request; nothing stopped, no key")
            return SpokenAbortStatus.failed
        case .unanswered:
            Log.backends.error("stop phrase: the mod did not answer; the turn may or may not have ended")
            return SpokenAbortStatus.failed
        }
    }
}
