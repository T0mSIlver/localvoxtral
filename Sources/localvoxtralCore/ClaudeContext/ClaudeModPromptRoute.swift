import ClaudeContextWire
import Foundation
import Synchronization

/// Live Auto-Paste into a local Claude Code session through its mod (#1645):
/// each delta goes down the mod channel as an unanswered `append`, which the
/// mod fills at the cursor with `$.prompt.fill`, so no key is posted and
/// Secure Keyboard Entry cannot swallow it.
///
/// An append answers `delivered` once it is written: waiting for a reply per
/// delta would cost a reply process each. The stop's `ack` (`settle`) says
/// how many the mod filled, in order; the rest did not land. A spoken send
/// asks the same before it submits. An `ack` the mod never answers leaves
/// every unconfirmed append possibly filled, so none of them is typed: they
/// stay in History (`docs/agent/invariants.md`).
package final class ClaudeModPromptRoute: AgentPromptRoute {
    package let name = "Claude Code mod"
    /// The mod fills newlines and trailing spaces as text: no key is posted
    /// that could submit the prompt or confirm an autocomplete.
    package var takesUnsanitizedText: Bool { true }
    package let sessionID: String
    private let hub: ClaudeModChannelHub
    private let ackTimeout: Duration
    private let submitTimeout: Duration
    /// Whether a key typed now reaches this session's prompt: asked before
    /// text that surely did not land is typed.
    private let keysReachThePrompt: @Sendable () async -> Bool

    private struct State {
        /// The stream's appends written since the last `ack`, in order.
        var written: [String] = []
        /// What a failed submit's `ack` found, for the sink's `settle`.
        var settled: AgentPromptSettlement?
    }

    private let state = Mutex(State())

    package init(
        hub: ClaudeModChannelHub,
        sessionID: String,
        ackTimeout: Duration = .seconds(5),
        submitTimeout: Duration = .seconds(5),
        keysReachThePrompt: @escaping @Sendable () async -> Bool
    ) {
        self.hub = hub
        self.sessionID = sessionID
        self.ackTimeout = ackTimeout
        self.submitTimeout = submitTimeout
        self.keysReachThePrompt = keysReachThePrompt
    }

    /// The route for `sessionID` when its mod answers an `ack`, which a mod
    /// older than `append` does not, or nil. The `ack` also ends whatever
    /// stream an earlier dictation left open.
    package static func opened(
        hub: ClaudeModChannelHub,
        sessionID: String,
        timeout: Duration = .seconds(1),
        keysReachThePrompt: @escaping @Sendable () async -> Bool
    ) async -> ClaudeModPromptRoute? {
        guard hub.isAttached(sessionID) else { return nil }
        let exchange = await hub.exchange(.init(kind: .ack, seq: 0), with: sessionID, timeout: timeout)
        guard let reply = exchange.reply, reply.ok, reply.seq != nil else {
            Log.claudeContext.notice(
                "Claude Code mod: no append stream (\(exchange.reply?.reason ?? "unanswered", privacy: .public)); live text goes another way"
            )
            return nil
        }
        return ClaudeModPromptRoute(hub: hub, sessionID: sessionID, keysReachThePrompt: keysReachThePrompt)
    }

    package func deliver(_ call: AgentPromptCall) async -> AgentPromptDelivery {
        switch call {
        case .append(let text):
            let seq = state.withLock { $0.written.count + 1 }
            guard hub.post(.init(kind: .append, text: text, seq: seq), to: sessionID) else {
                Log.backends.notice("Claude Code mod: append \(seq, privacy: .public) not written")
                return await keysReachThePrompt() ? .typeInstead : .keepInHistory
            }
            state.withLock { $0.written.append(text) }
            return .delivered
        case .submit:
            let settlement = await ack()
            guard settlement.unlanded.isEmpty else {
                state.withLock { $0.settled = settlement }
                return settlement.outcome
            }
            let exchange = await hub.exchange(.init(kind: .send, text: ""), with: sessionID, timeout: submitTimeout)
            let reply = exchange.reply
            if reply?.ok == true, reply?.submitted == true {
                Log.backends.notice("Claude Code mod: spoken send submitted queued=\(reply?.queued == true, privacy: .public)")
            } else {
                // The text is in the box either way; only the submit is
                // missing, and no key may stand in for it.
                Log.backends.notice(
                    "Claude Code mod: spoken send not submitted (\(reply?.reason ?? "unanswered", privacy: .public)); the text stays in the box"
                )
            }
            return .delivered
        }
    }

    package func settle() async -> AgentPromptSettlement {
        if let settled = state.withLock({ state -> AgentPromptSettlement? in
            defer { state.settled = nil }
            return state.settled
        }) {
            return settled
        }
        return await ack()
    }

    /// Asks the mod how far the stream got, and starts the next one.
    private func ack() async -> AgentPromptSettlement {
        let written = state.withLock { state -> [String] in
            defer { state.written = [] }
            return state.written
        }
        guard !written.isEmpty else { return .allLanded }
        let exchange = await hub.exchange(.init(kind: .ack, seq: written.count), with: sessionID, timeout: ackTimeout)
        switch exchange {
        case .replied(let reply) where reply.ok && reply.seq != nil:
            let filled = min(max(0, reply.seq ?? 0), written.count)
            guard filled < written.count else { return .allLanded }
            Log.backends.notice(
                "Claude Code mod: filled \(filled, privacy: .public) of \(written.count, privacy: .public) appends"
            )
            let rest = Array(written[filled...])
            return AgentPromptSettlement(unlanded: rest, outcome: await keysReachThePrompt() ? .typeInstead : .keepInHistory)
        case .notDelivered:
            // The channel is gone: the mod may have filled any of them.
            Log.backends.notice("Claude Code mod: ack not delivered; \(written.count, privacy: .public) appends kept")
            return AgentPromptSettlement(unlanded: written, outcome: .keepInHistory)
        case .replied, .unanswered:
            Log.backends.notice("Claude Code mod: no ack; \(written.count, privacy: .public) appends kept")
            return AgentPromptSettlement(unlanded: written, outcome: .keepInHistory)
        }
    }
}
