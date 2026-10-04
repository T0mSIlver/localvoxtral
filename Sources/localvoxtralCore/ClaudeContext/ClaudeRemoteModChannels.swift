import ClaudeContextWire
import Foundation
import Synchronization

/// The remote mod channel's wire (#1412): what the remote plugin's copy of
/// the mod (`integrations/claude-code/plugins/localvoxtral-remote/hooks/remote.ts`)
/// posts to the listener, and the proofs both ends add.
///
/// The host token opens the listener, as it does for hooks. A process that
/// squats the forward port on the host receives that token, so every request
/// and every answer also carries an HMAC under the host's channel key: a key
/// derived from the token hash this Mac stores, which setup writes into the
/// plugin's config and which never crosses the tunnel.
public enum ClaudeRemoteModWire {
    public static let pollPath = "/v1/mod/poll"
    public static let replyPath = "/v1/mod/reply"
    public static let proofHeaderName = "X-Lvx-Mod-Proof"
    /// A poll is a few ids; a reply carries at most one wire line.
    public static let maxPollBytes = 1024
    public static let maxReplyBytes = ClaudeModChannelWire.maxLineBytes

    package struct PollRequest: Decodable, Equatable, Sendable {
        package var modPoll: Int
        package var sessionID: String
        /// One load of the module: a second process of the session is refused.
        package var instance: String
        package var nonce: String
        /// The last line of this attach the mod got; it and those before go.
        package var acked: Int

        package init(sessionID: String, instance: String, nonce: String, acked: Int) {
            self.modPoll = ClaudeModChannelWire.version
            self.sessionID = sessionID
            self.instance = instance
            self.nonce = nonce
            self.acked = acked
        }

        enum CodingKeys: String, CodingKey {
            case modPoll = "mod_poll"
            case sessionID = "session_id"
            case instance, nonce, acked
        }
    }

    /// A poll of this version with well-formed ids, or nil. The session id
    /// gets post.sh's charset and length, since it lands in a scoped key.
    package static func decodePoll(_ data: Data) -> PollRequest? {
        guard let poll = try? JSONDecoder().decode(PollRequest.self, from: data),
              poll.modPoll == ClaudeModChannelWire.version,
              (1...64).contains(poll.sessionID.utf8.count),
              poll.sessionID.utf8.allSatisfy({ isASCIIAlphanumeric($0) || $0 == UInt8(ascii: "-") }),
              isHex(poll.instance, count: 32), isHex(poll.nonce, count: 32),
              poll.acked >= 0
        else { return nil }
        return poll
    }

    /// The host's channel key, from the token hash its registry entry holds.
    /// A new token (rotation) is a new key.
    package static func channelKey(tokenHash: String) -> String {
        hex(HMACSHA256.authenticationCode(for: Data("lvx-mod-channel-v1".utf8), key: Data(tokenHash.utf8)))
    }

    package static func requestProof(key: String, body: Data) -> String {
        hex(HMACSHA256.authenticationCode(for: Data("lvx-mod-request-v1\n".utf8) + body, key: Data(key.utf8)))
    }

    package static func answerProof(key: String, nonce: String, body: Data) -> String {
        hex(HMACSHA256.authenticationCode(
            for: Data("lvx-mod-answer-v1\n\(nonce)\n".utf8) + body, key: Data(key.utf8)
        ))
    }

    /// One poll's answer: `{"attach":…,"first":…,"lines":[…]}`, each line a
    /// wire message as the publisher prints it, without its newline.
    package static func answerBody(attach: UInt64, first: Int, lines: [Data]) -> Data {
        let strings = lines.map { line -> String in
            var text = String(decoding: line, as: UTF8.self)
            if text.hasSuffix("\n") { text.removeLast() }
            return text
        }
        let encoded = (try? JSONSerialization.data(withJSONObject: strings)) ?? Data("[]".utf8)
        return Data("{\"attach\":\(attach),\"first\":\(first),\"lines\":".utf8) + encoded + Data("}".utf8)
    }

    /// Compares two proofs in time independent of where they differ.
    package static func sameProof(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

/// The mod channels of remote sessions (#1412), held as leases on the
/// listener: each attaches a `ClaudeModChannelHub` channel under the
/// session's scoped id, so the app's senders reach a remote mod exactly as
/// they reach a local one.
///
/// A channel opens only for a session a hook of the same host already named,
/// the remote twin of the broker's rule. Lines the hub writes queue here
/// until a poll takes them; a poll acks the lines before it, and lines not
/// acked go again with the next one, so an answer lost with a dropped forward
/// loses nothing. No poll for `grace` after the last one ends detaches the
/// channel, and the hub answers its waiting requests as unanswered.
public final class ClaudeRemoteModChannels: Sendable {
    /// What a poll gets.
    package enum PollOutcome: Equatable, Sendable {
        /// The attach's lines not yet acked, numbered from `first`; empty when
        /// nothing came in the hold.
        case lines(attach: UInt64, first: Int, [Data])
        /// Not now: another process of the session holds the channel, no
        /// hook has named the session, or the hub is full.
        case busy
    }

    private struct Lease {
        var id: UInt64
        var instance: String
        /// The hub's token; nil until the attach returns.
        var token: UInt64?
        var lines: [(seq: Int, data: Data)] = []
        var nextSeq = 1
        var queuedBytes = 0
        var waiter: (id: UInt64, continuation: CheckedContinuation<Void, Never>)?
        /// Bumped by every poll that starts or ends: the expiry acts only on
        /// the poll it was armed by.
        var generation: UInt64 = 0
        var isClosed = false
        var isDetached = false
    }

    private struct State {
        var leases: [String: Lease] = [:]
        var nextID: UInt64 = 1
    }

    private let state = Mutex(State())
    private let hub: ClaudeModChannelHub
    private let registry: ClaudeSessionRegistry
    private let hold: Duration
    private let grace: Duration
    private let maxQueuedLines: Int
    private let maxQueuedBytes: Int
    private let sleep: @Sendable (Duration) async -> Void

    /// - Parameters:
    ///   - hold: how long a poll waits for a line before it answers empty;
    ///     under the mod's own 30 s abandon.
    ///   - grace: how long after a poll ends the next must start.
    ///   - sleep: the hold's and the expiry's clock; tests pass one they
    ///     advance.
    public init(
        hub: ClaudeModChannelHub,
        registry: ClaudeSessionRegistry,
        hold: Duration = .seconds(25),
        grace: Duration = .seconds(10),
        maxQueuedLines: Int = 64,
        maxQueuedBytes: Int = 256 * 1024,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.hub = hub
        self.registry = registry
        self.hold = hold
        self.grace = grace
        self.maxQueuedLines = maxQueuedLines
        self.maxQueuedBytes = maxQueuedBytes
        self.sleep = sleep
    }

    /// One poll of `hostID`'s mod for the session its request names,
    /// authenticated and proven by the caller.
    package func poll(hostID: String, request: ClaudeRemoteModWire.PollRequest) async -> PollOutcome {
        let sessionID = ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: request.sessionID)
        guard let leaseID = await lease(sessionID: sessionID, hostID: hostID, instance: request.instance) else {
            return .busy
        }

        let waiterID = state.withLock { state -> UInt64? in
            guard var lease = state.leases[sessionID], lease.id == leaseID else { return nil }
            lease.lines.removeAll { $0.seq <= request.acked }
            lease.queuedBytes = lease.lines.reduce(0) { $0 + $1.data.count }
            lease.generation += 1
            // A poll this one replaces (a fetch the mod abandoned) answers
            // empty; its lines stay for this one.
            let superseded = lease.waiter
            lease.waiter = nil
            state.leases[sessionID] = lease
            superseded?.continuation.resume()
            guard lease.lines.isEmpty, !lease.isClosed else { return nil }
            state.nextID += 1
            return state.nextID
        }
        if let waiterID {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked = state.withLock { state -> Bool in
                    guard var lease = state.leases[sessionID], lease.id == leaseID,
                          lease.lines.isEmpty, !lease.isClosed, lease.waiter == nil
                    else { return false }
                    lease.waiter = (waiterID, continuation)
                    state.leases[sessionID] = lease
                    return true
                }
                guard parked else {
                    continuation.resume()
                    return
                }
                Task { [sleep, hold] in
                    await sleep(hold)
                    self.wake(sessionID: sessionID, waiterID: waiterID)
                }
            }
        }

        return state.withLock { state -> PollOutcome in
            guard var lease = state.leases[sessionID], lease.id == leaseID, let token = lease.token else {
                return .lines(attach: 0, first: request.acked + 1, [])
            }
            lease.generation += 1
            let generation = lease.generation
            let isClosed = lease.isClosed
            let lines = lease.lines
            if isClosed && lines.isEmpty {
                state.leases[sessionID] = nil
            } else {
                state.leases[sessionID] = lease
                Task { [sleep, grace] in
                    await sleep(grace)
                    self.expire(sessionID: sessionID, leaseID: leaseID, generation: generation)
                }
            }
            return .lines(attach: token, first: lines.first?.seq ?? lease.nextSeq, lines.map(\.data))
        }
    }

    /// The mod's reply, under the session id scoped to the host whose token
    /// sent it: one host cannot answer another's request.
    package func deliver(hostID: String, reply: ClaudeModChannelWire.Reply) {
        var reply = reply
        reply.sessionID = ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: reply.sessionID)
        hub.deliver(reply)
    }

    /// The mod's `bye` (#1646), scoped the same way.
    package func bye(hostID: String, sessionID: String) {
        hub.bye(sessionID: ClaudeRemoteSessionScope.scopedSessionID(hostID: hostID, sessionID: sessionID))
    }

    /// Whether `sessionID` (scoped) has a lease, attached or closing.
    package func hasLease(_ sessionID: String) -> Bool {
        state.withLock { $0.leases[sessionID] != nil }
    }

    // MARK: Leases

    /// The lease this poll may use, attaching one when none is held.
    private func lease(sessionID: String, hostID: String, instance: String) async -> UInt64? {
        enum Found { case held(UInt64), refused, attach(UInt64) }
        let found = state.withLock { state -> Found in
            if let lease = state.leases[sessionID] {
                guard lease.instance == instance else { return .refused }
                return lease.token == nil ? .refused : .held(lease.id)
            }
            let id = state.nextID
            state.nextID += 1
            state.leases[sessionID] = Lease(id: id, instance: instance)
            return .attach(id)
        }
        switch found {
        case .held(let id): return id
        case .refused: return nil
        case .attach(let id): return attach(sessionID: sessionID, hostID: hostID, leaseID: id)
        }
    }

    private func attach(sessionID: String, hostID: String, leaseID: UInt64) -> UInt64? {
        let origin = ClaudeTransportOrigin.remote(channel: ClaudeRemoteSessionScope.channel(hostID: hostID))
        guard let snapshot = registry.snapshot(sessionID: sessionID),
              snapshot.agent == .claude, snapshot.origin == origin
        else {
            state.withLock { _ = $0.leases.removeValue(forKey: sessionID) }
            Log.claudeContext.info("Remote mod channel: refused an attach for a session no hook of its host has named")
            return nil
        }
        let channel = ClaudeModChannelHub.Channel(
            write: { [weak self] line in self?.write(line, sessionID: sessionID, leaseID: leaseID) ?? false },
            close: { [weak self] in self?.close(sessionID: sessionID, leaseID: leaseID) }
        )
        // Outside the lock: the hub's attach observer may write at once.
        guard let token = hub.attach(sessionID: sessionID, channel: channel) else {
            state.withLock { _ = $0.leases.removeValue(forKey: sessionID) }
            return nil
        }
        // No pid: a remote pid names a process on another machine.
        registry.modChannelAttached(sessionID: sessionID, claudePID: 0, token: token)
        state.withLock { $0.leases[sessionID]?.token = token }
        Log.claudeContext.info("Remote mod channel attached for host \(hostID, privacy: .public)")
        return leaseID
    }

    private func write(_ line: Data, sessionID: String, leaseID: UInt64) -> Bool {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>?? in
            guard var lease = state.leases[sessionID], lease.id == leaseID, !lease.isClosed,
                  lease.lines.count < maxQueuedLines, lease.queuedBytes + line.count <= maxQueuedBytes
            else { return .none }
            lease.lines.append((lease.nextSeq, line))
            lease.nextSeq += 1
            lease.queuedBytes += line.count
            let waiter = lease.waiter?.continuation
            lease.waiter = nil
            state.leases[sessionID] = lease
            return .some(waiter)
        }
        guard let waiter else {
            Log.claudeContext.error("Remote mod channel: a line found no room; the mod stopped polling")
            return false
        }
        waiter?.resume()
        return true
    }

    /// The hub closed the channel (a `bye`, a failed write, the app's stop):
    /// detach now; a poll still gets the lines left, the `bye` among them.
    private func close(sessionID: String, leaseID: UInt64) {
        let (waiter, token) = state.withLock { state -> (CheckedContinuation<Void, Never>?, UInt64?) in
            guard var lease = state.leases[sessionID], lease.id == leaseID, !lease.isClosed else { return (nil, nil) }
            lease.isClosed = true
            lease.isDetached = true
            let waiter = lease.waiter?.continuation
            lease.waiter = nil
            state.leases[sessionID] = lease
            return (waiter, lease.token)
        }
        waiter?.resume()
        if let token { detach(sessionID: sessionID, token: token) }
    }

    private func wake(sessionID: String, waiterID: UInt64) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.leases[sessionID]?.waiter, waiter.id == waiterID else { return nil }
            state.leases[sessionID]?.waiter = nil
            return waiter.continuation
        }
        waiter?.resume()
    }

    private func expire(sessionID: String, leaseID: UInt64, generation: UInt64) {
        let token = state.withLock { state -> UInt64?? in
            guard let lease = state.leases[sessionID], lease.id == leaseID,
                  lease.generation == generation, lease.waiter == nil
            else { return .none }
            state.leases[sessionID] = nil
            return lease.isDetached ? .some(nil) : .some(lease.token)
        }
        guard let token else { return }
        Log.claudeContext.info("Remote mod channel: no poll in time; detaching")
        if let token { detach(sessionID: sessionID, token: token) }
    }

    private func detach(sessionID: String, token: UInt64) {
        let ended = hub.detach(sessionID: sessionID, token: token)
        registry.modChannelDetached(sessionID: sessionID, token: token, sessionEnded: ended)
    }
}
