/// How far one socket's handshake has got. Frames sent before the send gate
/// opens queue; `session.created` opens it, or, on an OpenAI Realtime server
/// that never sends one, the compatibility timer does.
///
///     awaitingSessionCreated ─▶ gateOpen(replaying: true) ─▶ gateOpen(replaying: false)
///
/// While `replaying`, the queue drains onto the wire and new frames queue
/// behind it (#1058). `sessionCreated` is false only after the compatibility
/// timer opened the gate; a late `session.created` still sets it. A new
/// socket starts over at `awaitingSessionCreated`.
enum RealtimeHandshake: Equatable {
    case awaitingSessionCreated
    case gateOpen(replaying: Bool, sessionCreated: Bool)

    var hasReceivedSessionCreated: Bool {
        if case .gateOpen(replaying: _, sessionCreated: true) = self { return true }
        return false
    }

    var isSendGateOpen: Bool { self != .awaitingSessionCreated }

    var isReplayingQueue: Bool {
        if case .gateOpen(replaying: true, sessionCreated: _) = self { return true }
        return false
    }

    /// The gate after the replay emptied the queue; unchanged when no replay
    /// is under way, so a replay loop that ends late cannot close a gate.
    var afterReplay: RealtimeHandshake {
        guard case .gateOpen(replaying: true, let sessionCreated) = self else { return self }
        return .gateOpen(replaying: false, sessionCreated: sessionCreated)
    }

    /// Moves to `next`; a move `canMove` refuses still happens, and is
    /// reported to `onRefused`.
    mutating func move(to next: RealtimeHandshake, onRefused: (String) -> Void) {
        if !canMove(to: next) { onRefused("handshake \(self) -> \(next)") }
        self = next
    }

    /// Whether the handshake may move from `self` to `next`. A move this
    /// refuses is logged as a fault: two code paths disagree about where the
    /// socket is.
    func canMove(to next: RealtimeHandshake) -> Bool {
        switch (self, next) {
        case (.awaitingSessionCreated, .gateOpen(replaying: true, sessionCreated: _)):
            return true
        case (.gateOpen(replaying: true, let from), .gateOpen(replaying: false, let to)):
            return from == to
        case (.gateOpen(replaying: let from, sessionCreated: false), .gateOpen(replaying: let to, sessionCreated: true)):
            return from == to
        default:
            return self == next
        }
    }
}

/// Where one socket's final commit is. The stop sends it, the server's
/// `done` answers it.
///
///     notSent ─▶ awaitingDone ─▶ answered
///
/// The OpenAI Realtime client may send another final once one is answered
/// (`answered ─▶ awaitingDone`); Mistral's sends only one per socket.
enum RealtimeFinalCommit: Equatable {
    case notSent
    /// The final commit is out; `.transcriptionFinalized` waits for its `done`.
    case awaitingDone
    /// The `done` came in (on Mistral, an `error` frame also ends the wait).
    case answered

    /// Moves to `next`; a move `canMove` refuses still happens, and is
    /// reported to `onRefused`.
    mutating func move(to next: RealtimeFinalCommit, onRefused: (String) -> Void) {
        if !canMove(to: next) { onRefused("final commit \(self) -> \(next)") }
        self = next
    }

    /// Whether the final commit may move from `self` to `next`. A refused
    /// move is logged as a fault.
    func canMove(to next: RealtimeFinalCommit) -> Bool {
        switch (self, next) {
        case (.notSent, .awaitingDone), (.awaitingDone, .answered), (.answered, .awaitingDone):
            return true
        default:
            return self == next
        }
    }
}
