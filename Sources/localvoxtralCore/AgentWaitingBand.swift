import ClaudeContextWire
import Foundation

/// Tells each attached Claude Code mod which other Claude Code sessions wait
/// for the user, for one line in the band above its prompt (#1695): the
/// in-session place of the #717 cue. Names only: the app never has what an
/// agent said, and the band never shows it.
///
/// It sends a session's mod a `state` message with `waiting` whenever that
/// session's list changes, and again when the mod attaches, since a new or
/// reloaded mod starts blank. A mod clears the line itself when its channel
/// ends, or when a remote poll fails, so no heartbeat keeps it alive; the hub
/// reports a remote mod that started over as an attach (#1799).
@MainActor
package final class AgentWaitingBand {
    private let hub: ClaudeModChannelHub
    private var queue = AgentAttentionQueue()
    /// What each attached mod was last told.
    private var sent: [String: [String]] = [:]

    package init(hub: ClaudeModChannelHub) {
        self.hub = hub
    }

    /// The other Claude Code sessions waiting for the user, as `sessionID`'s
    /// band names them, oldest first.
    package static func names(in queue: AgentAttentionQueue, for sessionID: String) -> [String] {
        queue.answerOrder
            .filter { $0.kind == .waiting && $0.agent == .claude && $0.sessionID != sessionID }
            .map(\.name)
    }

    /// The queue changed: every attached mod whose list changed hears it.
    package func update(_ queue: AgentAttentionQueue) {
        self.queue = queue
        let attached = hub.attachedSessionIDs()
        sent = sent.filter { attached.contains($0.key) }
        for sessionID in attached.sorted() { post(to: sessionID) }
    }

    /// `sessionID`'s mod attached: it starts blank, so it hears the list
    /// unless nobody waits.
    package func attached(sessionID: String) {
        sent[sessionID] = nil
        post(to: sessionID)
    }

    private func post(to sessionID: String) {
        let names = Self.names(in: queue, for: sessionID)
        guard names != sent[sessionID, default: []] else { return }
        if hub.post(.init(kind: .state, waiting: names), to: sessionID) {
            sent[sessionID] = names
        } else {
            Log.claudeContext.error("Mod channel: waiting band not delivered")
        }
    }
}
