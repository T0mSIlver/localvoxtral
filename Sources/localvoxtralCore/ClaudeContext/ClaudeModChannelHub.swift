import ClaudeContextWire
import Foundation
import Synchronization

/// The open channels to Claude Code sessions' mods (#1408), by session id,
/// and the requests waiting on their replies.
///
/// The broker attaches a channel when a session's `--attach` process
/// connects and detaches it when that connection ends; the app sends through
/// `send`. One channel per session, the first: a second attach while it is
/// open is refused, so two publishers for one session (the session open in
/// two windows) cannot take the channel from each other in a loop. A
/// reloaded mod or a restarted publisher closes its old connection first,
/// and its retry lands once the broker has seen that.
///
/// A send names its session exactly and never falls back to another one
/// (`docs/agent/invariants.md`): no channel, a failed write or no reply in
/// time all answer nil, and the caller keeps its own path.
public final class ClaudeModChannelHub: Sendable {
    /// One attached connection, as the broker hands it over.
    package struct Channel: Sendable {
        /// Writes one whole line; false when the peer is gone.
        var write: @Sendable (Data) -> Bool
        /// Ends the connection, which ends the broker's hold on it.
        var close: @Sendable () -> Void

        package init(write: @escaping @Sendable (Data) -> Bool, close: @escaping @Sendable () -> Void) {
            self.write = write
            self.close = close
        }
    }

    private struct Attached {
        var token: UInt64
        var channel: Channel
        /// The mod said its session is ending (`bye`): the detach that
        /// follows ends the session.
        var isEnding = false
    }

    private struct Pending {
        var sessionID: String
        var continuation: CheckedContinuation<Exchange, Never>
        /// The reply timeout; cancelled by whichever answer comes first.
        var timer: Task<Void, Never>?
    }

    private struct State {
        var channels: [String: Attached] = [:]
        var pending: [String: Pending] = [:]
        var nextToken: UInt64 = 1
    }

    private let state = Mutex(State())

    #if DEBUG
    /// Test seam: fires after each attach (true) and detach (false), so a
    /// socket test awaits the event instead of polling `isAttached`.
    private let debugAttachHook = Mutex<(@Sendable (Bool) -> Void)?>(nil)

    package func debugConfigureAttachHook(_ hook: (@Sendable (Bool) -> Void)?) {
        debugAttachHook.withLock { $0 = hook }
    }
    #endif
    private let attachObserver = Mutex<(@Sendable (String) -> Void)?>(nil)
    private let maxChannels: Int
    private let sleep: @Sendable (Duration) async -> Void
    private let makeID: @Sendable () -> String

    /// - Parameters:
    ///   - maxChannels: sessions that may hold a channel at once. Each holds
    ///     a broker thread.
    ///   - sleep: the reply timeout's clock; tests pass one they advance.
    public init(
        maxChannels: Int = 64,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        makeID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.maxChannels = maxChannels
        self.sleep = sleep
        self.makeID = makeID
    }

    /// Whether any session has a mod listening: the cheap question asked
    /// before any lookup that would find one.
    public var hasAttachedChannels: Bool {
        state.withLock { !$0.channels.isEmpty }
    }

    /// Whether `sessionID` has a mod listening right now.
    public func isAttached(_ sessionID: String) -> Bool {
        state.withLock { $0.channels[sessionID] != nil }
    }

    /// The sessions that have a mod listening right now.
    public func attachedSessionIDs() -> Set<String> {
        state.withLock { Set($0.channels.keys) }
    }

    /// Called with the session's id after each attach, on the broker's
    /// thread and under its lock: hand the work off, never block. A message
    /// posted from it waits for the attach's answer, which is the
    /// connection's first line.
    public func observeAttach(_ observer: (@Sendable (String) -> Void)?) {
        attachObserver.withLock { $0 = observer }
    }

    /// How a request ended, told apart where it matters: a request the mod
    /// never got can go another way, while one it got and did not answer may
    /// still have done its work.
    public enum Exchange: Equatable, Sendable {
        case replied(ClaudeModChannelWire.Reply)
        /// No channel, an encoding over the cap, or a failed write.
        case notDelivered
        /// Written, then no reply in time or the channel closed.
        case unanswered

        public var reply: ClaudeModChannelWire.Reply? {
            if case .replied(let reply) = self { return reply }
            return nil
        }
    }

    /// Sends `message` to the mod of `sessionID` and waits for its reply.
    ///
    /// - Returns: the reply, or nil when the session has no channel, the
    ///   write failed, or no reply came within `timeout`.
    public func send(
        _ message: ClaudeModChannelWire.Message,
        to sessionID: String,
        timeout: Duration
    ) async -> ClaudeModChannelWire.Reply? {
        await exchange(message, with: sessionID, timeout: timeout).reply
    }

    /// `send`, saying whether a request without a reply ever reached the mod.
    public func exchange(
        _ message: ClaudeModChannelWire.Message,
        with sessionID: String,
        timeout: Duration
    ) async -> Exchange {
        var message = message
        message.id = makeID()
        let id = message.id
        let kind = message.kind.rawValue
        guard let line = ClaudeModChannelWire.encodeLine(message) else {
            Log.claudeContext.error("Mod channel: \(message.kind.rawValue, privacy: .public) is over the line cap")
            return .notDelivered
        }
        guard let channel = state.withLock({ $0.channels[sessionID]?.channel }) else { return .notDelivered }

        return await withCheckedContinuation { continuation in
            state.withLock { $0.pending[id] = Pending(sessionID: sessionID, continuation: continuation) }
            let timer = Task { [sleep] in
                await sleep(timeout)
                guard !Task.isCancelled else { return }
                if self.resume(id: id, with: .unanswered) {
                    Log.claudeContext.error("Mod channel: no reply to \(kind, privacy: .public) in time")
                }
            }
            let isWaiting = state.withLock { state -> Bool in
                guard state.pending[id] != nil else { return false }
                state.pending[id]?.timer = timer
                return true
            }
            if !isWaiting { timer.cancel() }
            if !channel.write(line) {
                Log.claudeContext.error("Mod channel: write failed; detaching")
                _ = resume(id: id, with: .notDelivered)
                channel.close()
            }
        }
    }

    /// Writes `message` to the mod of `sessionID` and waits for nothing:
    /// for messages the mod does not answer, such as `state`.
    ///
    /// - Returns: whether the line was written.
    @discardableResult
    public func post(_ message: ClaudeModChannelWire.Message, to sessionID: String) -> Bool {
        var message = message
        message.id = makeID()
        guard let line = ClaudeModChannelWire.encodeLine(message),
              let channel = state.withLock({ $0.channels[sessionID]?.channel })
        else { return false }
        return channel.write(line)
    }

    // MARK: Broker side

    /// Takes `channel` for `sessionID`.
    ///
    /// - Returns: the token `detach` needs, or nil when the session already
    ///   has a channel or the hub is full.
    package func attach(sessionID: String, channel: Channel) -> UInt64? {
        enum Refusal: Error { case taken, full }
        let outcome: Result<UInt64, Refusal> = state.withLock { state in
            guard state.channels[sessionID] == nil else { return .failure(.taken) }
            guard state.channels.count < maxChannels else { return .failure(.full) }
            let token = state.nextToken
            state.nextToken += 1
            state.channels[sessionID] = Attached(token: token, channel: channel)
            return .success(token)
        }
        let token: UInt64
        switch outcome {
        case .success(let attached):
            token = attached
        case .failure(.taken):
            Log.claudeContext.info("Mod channel: refused a second attach for a session that has one")
            return nil
        case .failure(.full):
            Log.claudeContext.error("Mod channel: refused an attach, \(self.maxChannels, privacy: .public) already open")
            return nil
        }
        Log.claudeContext.info("Mod channel attached")
        #if DEBUG
        debugAttachHook.withLock { $0 }?(true)
        #endif
        attachObserver.withLock { $0 }?(sessionID)
        return token
    }

    /// Forgets the channel `token` names, if it is still the session's, and
    /// answers nil to every request still waiting on it.
    ///
    /// - Returns: whether the mod said `bye` first, so the session ended.
    @discardableResult
    package func detach(sessionID: String, token: UInt64) -> Bool {
        let detached: (orphaned: [Pending], ended: Bool)? = state.withLock { state in
            guard let attached = state.channels[sessionID], attached.token == token else { return nil }
            state.channels[sessionID] = nil
            let ids = state.pending.filter { $0.value.sessionID == sessionID }.map(\.key)
            return (ids.compactMap { state.pending.removeValue(forKey: $0) }, attached.isEnding)
        }
        guard let detached else { return false }
        let (orphaned, ended) = detached
        Log.claudeContext.info("Mod channel detached ended=\(ended, privacy: .public)")
        #if DEBUG
        debugAttachHook.withLock { $0 }?(false)
        #endif
        for pending in orphaned {
            pending.timer?.cancel()
            pending.continuation.resume(returning: .unanswered)
        }
        return ended
    }

    /// The mod's `bye` (#1646): marks the session's channel as ending, tells
    /// the mod with a `bye` message, and closes the channel, whose detach
    /// then ends the session. A session with no channel is left alone: a
    /// bye only ends what an attach proved.
    ///
    /// - Returns: whether a channel was attached.
    @discardableResult
    package func bye(sessionID: String) -> Bool {
        let channel: Channel? = state.withLock { state in
            guard state.channels[sessionID] != nil else { return nil }
            state.channels[sessionID]?.isEnding = true
            return state.channels[sessionID]?.channel
        }
        guard let channel else {
            Log.claudeContext.info("Mod channel: a bye for a session with no channel; nothing ended")
            return false
        }
        Log.claudeContext.info("Mod channel: the mod said bye; closing")
        var message = ClaudeModChannelWire.Message(kind: .bye)
        message.id = makeID()
        if let line = ClaudeModChannelWire.encodeLine(message) {
            _ = channel.write(line)
        }
        channel.close()
        return true
    }

    /// Hands a reply to the request it answers. A reply that names another
    /// session, or no request still waiting, is dropped.
    package func deliver(_ reply: ClaudeModChannelWire.Reply) {
        let pending = state.withLock { state -> Pending? in
            guard state.pending[reply.id]?.sessionID == reply.sessionID else { return nil }
            return state.pending.removeValue(forKey: reply.id)
        }
        guard let pending else {
            Log.claudeContext.error("Mod channel: dropped a reply no request is waiting for")
            return
        }
        if !reply.ok, reply.reason == ClaudeModChannelWire.Reply.sessionChangedReason {
            Log.backends.error(
                "Mod channel: the mod refused a request because its process moved to another session (/clear or resume)"
            )
        }
        pending.timer?.cancel()
        pending.continuation.resume(returning: .replied(reply))
    }

    /// Closes every channel; the broker calls it on stop.
    package func closeAll() {
        let channels = state.withLock { $0.channels.values.map(\.channel) }
        channels.forEach { $0.close() }
    }

    /// Resumes `id` once. False when something else already did.
    private func resume(id: String, with reply: Exchange) -> Bool {
        guard let pending = state.withLock({ $0.pending.removeValue(forKey: id) }) else { return false }
        pending.timer?.cancel()
        pending.continuation.resume(returning: reply)
        return true
    }
}
