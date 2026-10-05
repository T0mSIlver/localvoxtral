import ClaudeContextWire
import Foundation
import Synchronization
import localvoxtralCore

/// A mod on the far end of the channel, as `localvoxtral-mod` behaves: it
/// fills appends in order until one is refused or out of order, and an
/// `ack` answers how many filled and starts the next stream. A `cancel`
/// keeps every append that arrived before it from filling, once held ones
/// are released (#1805).
package final class FakeClaudeMod: Sendable {
    package struct State {
        package var box = ""
        package var filled = 0
        package var ended = false
        package var kinds: [ClaudeModChannelWire.Kind] = []
        package var submitted: [String] = []
        package var acksAnswered = 0
        package var cancels = 0
        /// Appends a slow fill holds, each with the `cancels` it arrived
        /// after.
        package var held: [(message: ClaudeModChannelWire.Message, cancels: Int)] = []
    }

    package let state = Mutex(State())
    /// The text of an append the box refuses.
    package let refuses: String?
    /// How many `ack`s it answers before it goes silent.
    package let acksToAnswer: Int
    package let knowsAppend: Bool
    /// Whether appends wait for `releaseHeldFills`, as behind a slow fill.
    package let holdsFills: Bool
    /// The reason a `send` is refused with, the box left as it is.
    package let refusesSend: String?
    /// Counts every `send` written to it.
    package let sends = EventCount()
    /// Counts every append written to it, filled or not.
    package let appends = EventCount()

    package init(
        refuses: String? = nil,
        acksToAnswer: Int = .max,
        knowsAppend: Bool = true,
        holdsFills: Bool = false,
        refusesSend: String? = nil
    ) {
        self.refuses = refuses
        self.acksToAnswer = acksToAnswer
        self.knowsAppend = knowsAppend
        self.holdsFills = holdsFills
        self.refusesSend = refusesSend
    }

    /// Fills the held appends in order, as the slow fill ahead of them ends.
    package func releaseHeldFills() {
        state.withLock { state in
            let held = state.held
            state.held = []
            for (message, cancels) in held {
                guard cancels == state.cancels else {
                    state.ended = true
                    continue
                }
                fill(message, in: &state)
            }
        }
    }

    private func fill(_ message: ClaudeModChannelWire.Message, in state: inout State) {
        guard !state.ended, message.seq == state.filled + 1, message.text != refuses else {
            state.ended = true
            return
        }
        state.box += message.text ?? ""
        state.filled += 1
    }

    package var box: String { state.withLock { $0.box } }
    package var kinds: [ClaudeModChannelWire.Kind] { state.withLock { $0.kinds } }
    package var submitted: [String] { state.withLock { $0.submitted } }

    /// Returns the token `detach` takes, as the broker holds it.
    @discardableResult
    package func attach(to hub: ClaudeModChannelHub, sessionID: String = "s1") -> UInt64? {
        hub.attach(sessionID: sessionID, channel: .init(
            write: { [self] line in
                guard let message = ClaudeModChannelWire.decode(
                    ClaudeModChannelWire.Message.self, from: line.dropLast()
                ) else { return false }
                if let reply = handle(message, sessionID: sessionID) { hub.deliver(reply) }
                return true
            },
            close: {}
        ))
    }

    private func handle(_ message: ClaudeModChannelWire.Message, sessionID: String) -> ClaudeModChannelWire.Reply? {
        state.withLock { state -> ClaudeModChannelWire.Reply? in
            state.kinds.append(message.kind)
            if message.kind == .append { appends.increment() }
            guard knowsAppend || (message.kind != .append && message.kind != .ack) else {
                return message.kind == .append
                    ? nil : .init(sessionID: sessionID, id: message.id, ok: false, reason: "unknown_kind")
            }
            switch message.kind {
            case .append:
                if holdsFills {
                    state.held.append((message, state.cancels))
                } else {
                    fill(message, in: &state)
                }
                return nil
            case .cancel:
                state.cancels += 1
                return nil
            case .ack:
                guard state.acksAnswered < acksToAnswer else { return nil }
                state.acksAnswered += 1
                defer {
                    state.filled = 0
                    state.ended = false
                }
                return .init(sessionID: sessionID, id: message.id, ok: true, seq: state.filled)
            case .send:
                sends.increment()
                if let refusesSend {
                    return .init(sessionID: sessionID, id: message.id, ok: false, reason: refusesSend)
                }
                state.submitted.append(state.box + (message.text ?? ""))
                state.box = ""
                return .init(sessionID: sessionID, id: message.id, ok: true, submitted: true)
            default:
                return .init(sessionID: sessionID, id: message.id, ok: false, reason: "unknown_kind")
            }
        }
    }
}
