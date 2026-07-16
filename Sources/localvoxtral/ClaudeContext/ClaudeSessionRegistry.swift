import ClaudeContextWire
import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#endif

/// Result of a marker lookup.
///
/// Every non-`resolved` case is an ABSTENTION, and callers must treat it as
/// "we do not know" — never as "pick the most likely one". A wrong session's
/// context silently poisons dictation grounding; no context merely fails to
/// help it.
public enum ClaudeMarkerResolution: Sendable, Equatable {
    case resolved(ClaudeSessionSnapshot)
    /// No session carries this marker.
    case unknown
    /// A session carries it, but it is past TTL or its process is gone.
    case stale
    /// More than one live session matches the query.
    case ambiguous
}

public struct ClaudeRegistryLimits: Sendable, Equatable {
    /// Hard cap on retained sessions. Beyond this, the least-recently-active is
    /// evicted — a user with hundreds of stale sessions must not grow the app.
    public var maxSessions: Int
    /// A session with no hook activity for this long is stale. Claude Code can
    /// die without firing SessionEnd (SIGKILL, a closed terminal), so TTL plus
    /// PID liveness — not SessionEnd alone — is what keeps the registry honest.
    public var sessionTTL: TimeInterval

    public init(maxSessions: Int = 32, sessionTTL: TimeInterval = 4 * 60 * 60) {
        self.maxSessions = maxSessions
        self.sessionTTL = sessionTTL
    }

    public static let `default` = ClaudeRegistryLimits()
}

/// Sessions the broker knows about, keyed by session id, with markers.
///
/// `Mutex` + `Sendable` per repo convention (no custom actors): the broker's
/// accept thread writes, the main actor reads, and neither should await.
public final class ClaudeSessionRegistry: Sendable {
    private struct State {
        var sessions: [String: ClaudeSessionSnapshot] = [:]
        var markerIndex: [String: String] = [:] // marker value -> session id
    }

    private let state = Mutex(State())
    private let limits: ClaudeRegistryLimits
    private let now: @Sendable () -> Date
    private let isProcessAlive: @Sendable (Int32) -> Bool
    private let allocateMarkerValue: @Sendable () -> String

    /// - Parameters:
    ///   - now: injected clock. Nothing here reads the wall clock directly, so
    ///     TTL/staleness is testable without sleeping (AGENTS: no wall-clock in
    ///     tests).
    ///   - isProcessAlive: liveness probe for a session's hook pid.
    ///   - allocateMarkerValue: marker minting, injectable so tests can force
    ///     collisions.
    public init(
        limits: ClaudeRegistryLimits = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = ClaudeSessionRegistry.defaultLivenessProbe,
        allocateMarkerValue: @escaping @Sendable () -> String = ClaudeSessionRegistry.defaultMarkerValue
    ) {
        self.limits = limits
        self.now = now
        self.isProcessAlive = isProcessAlive
        self.allocateMarkerValue = allocateMarkerValue
    }

    /// Fold an authenticated record into the registry.
    ///
    /// - Parameters:
    ///   - origin: decided by the TRANSPORT — the local broker from peer
    ///     credentials, the remote listener from which token authenticated the
    ///     connection. This is the only way trust enters; `record` has no origin
    ///     field to consult.
    ///   - snippets: sanitized excerpts the transport extracted. Always empty
    ///     from the local NDJSON wire, which has no field for them.
    /// - Returns: the resulting snapshot, or nil if the record was dropped.
    @discardableResult
    public func ingest(
        _ record: ClaudeHookRecord,
        origin: ClaudeTransportOrigin,
        snippets: [ClaudeContentSnippet] = []
    ) -> ClaudeSessionSnapshot? {
        let timestamp = now()
        return state.withLock { state -> ClaudeSessionSnapshot? in
            pruneLocked(&state, now: timestamp)

            var snapshot: ClaudeSessionSnapshot
            if let existing = state.sessions[record.sessionID] {
                snapshot = existing
                // A session's origin is fixed at first sight, and a mismatch is
                // dropped in EITHER direction — not just remote-claiming-local.
                //
                // Remote→local was always the dangerous one (it would let a
                // forwarded peer mutate a session whose paths authorize
                // filesystem reads). Local→remote and remote(A)→remote(B) are
                // dropped too because there is no legitimate way to reach them:
                // remote ids are namespaced under the host whose token
                // authenticated them (`ClaudeRemoteSessionScope`), so a second
                // transport naming the same id is, by construction, someone
                // spelling an id that is not theirs.
                if snapshot.origin != origin { return nil }
            } else {
                if record.event == .sessionEnd { return nil } // nothing to start
                let marker = ClaudeSessionMarker(value: allocateUniqueMarkerLocked(&state))
                snapshot = ClaudeSessionSnapshot(
                    sessionID: record.sessionID,
                    origin: origin,
                    marker: marker,
                    firstSeen: timestamp
                )
                state.markerIndex[marker.value] = record.sessionID
            }

            ClaudeSessionReducer.reduce(
                &snapshot,
                record: record,
                origin: snapshot.origin,
                snippets: snippets,
                now: timestamp
            )

            if record.event == .sessionEnd {
                // Explicit end: evict immediately, but hand the final snapshot
                // back so a caller can react to the teardown.
                removeLocked(&state, sessionID: record.sessionID)
                return snapshot
            }

            state.sessions[record.sessionID] = snapshot
            enforceCapLocked(&state)
            return snapshot
        }
    }

    /// Look up by marker. Abstains on unknown and on stale.
    public func resolve(marker: ClaudeSessionMarker) -> ClaudeMarkerResolution {
        let timestamp = now()
        return state.withLock { state in
            guard let sessionID = state.markerIndex[marker.value],
                  let snapshot = state.sessions[sessionID]
            else {
                return .unknown
            }
            guard isFresh(snapshot, now: timestamp) else { return .stale }
            return .resolved(snapshot)
        }
    }

    /// Look up the marker for a local workspace path.
    ///
    /// Abstains as `.ambiguous` when two live sessions share a workspace —
    /// which is exactly what happens with two terminal tabs in one repo, so it
    /// is the common case, not an edge case. Resolving it needs the focus join
    /// that is deliberately not built yet.
    public func resolve(workspace: LocalWorkspacePath) -> ClaudeMarkerResolution {
        let timestamp = now()
        return state.withLock { state in
            let matches = state.sessions.values.filter { snapshot in
                isFresh(snapshot, now: timestamp)
                    && snapshot.localWorkspacePath?.path == workspace.path
            }
            switch matches.count {
            case 0:
                let hadStale = state.sessions.values.contains {
                    $0.localWorkspacePath?.path == workspace.path
                }
                return hadStale ? .stale : .unknown
            case 1:
                return .resolved(matches[0])
            default:
                return .ambiguous
            }
        }
    }

    public func snapshot(sessionID: String) -> ClaudeSessionSnapshot? {
        let timestamp = now()
        return state.withLock { state in
            guard let snapshot = state.sessions[sessionID], isFresh(snapshot, now: timestamp) else {
                return nil
            }
            return snapshot
        }
    }

    /// All live sessions, most recently active first.
    public func liveSessions() -> [ClaudeSessionSnapshot] {
        let timestamp = now()
        return state.withLock { state in
            state.sessions.values
                .filter { isFresh($0, now: timestamp) }
                .sorted { $0.lastActivity > $1.lastActivity }
        }
    }

    public func evict(sessionID: String) {
        state.withLock { removeLocked(&$0, sessionID: sessionID) }
    }

    public func removeAll() {
        state.withLock { state in
            state.sessions.removeAll()
            state.markerIndex.removeAll()
        }
    }

    // MARK: - Locked helpers

    private func isFresh(_ snapshot: ClaudeSessionSnapshot, now: Date) -> Bool {
        guard now.timeIntervalSince(snapshot.lastActivity) <= limits.sessionTTL else { return false }
        // `claudePID`, never `hookPID`. The publisher exits the instant it has
        // written its line, so probing its own pid would report every local
        // session dead microseconds after it was created — the registry would
        // answer `.stale` to everything, forever.
        //
        // Only a locally authenticated pid means anything to us: a remote
        // session's pid names a process on another machine, where it could
        // collide with an unrelated local one. Those rely on TTL alone.
        if snapshot.origin.isLocalAuthenticated, let pid = snapshot.process?.claudePID {
            return isProcessAlive(pid)
        }
        return true
    }

    private func pruneLocked(_ state: inout State, now: Date) {
        for (sessionID, snapshot) in state.sessions where !isFresh(snapshot, now: now) {
            removeLocked(&state, sessionID: sessionID)
        }
    }

    private func removeLocked(_ state: inout State, sessionID: String) {
        guard let snapshot = state.sessions.removeValue(forKey: sessionID) else { return }
        state.markerIndex.removeValue(forKey: snapshot.marker.value)
    }

    private func enforceCapLocked(_ state: inout State) {
        guard state.sessions.count > limits.maxSessions else { return }
        let ordered = state.sessions.values.sorted { $0.lastActivity < $1.lastActivity }
        for snapshot in ordered.prefix(state.sessions.count - limits.maxSessions) {
            removeLocked(&state, sessionID: snapshot.sessionID)
        }
    }

    /// Never hand out a marker that is already indexed. The allocator is random
    /// by default, so a collision is vanishingly unlikely — but "unlikely"
    /// aliasing of two sessions is the exact failure that would silently feed
    /// the wrong context into someone's dictation, so we check.
    private func allocateUniqueMarkerLocked(_ state: inout State) -> String {
        for _ in 0..<16 {
            let candidate = allocateMarkerValue()
            if state.markerIndex[candidate] == nil { return candidate }
        }
        // Exhausted: fall back to a value that cannot collide with the index.
        var counter = 0
        while true {
            let candidate = "lvx-fallback-\(counter)"
            if state.markerIndex[candidate] == nil { return candidate }
            counter += 1
        }
    }

    // MARK: - Defaults

    /// `kill(pid, 0)` — the standard liveness probe. EPERM means the process
    /// exists but is not ours, which still counts as alive.
    public static let defaultLivenessProbe: @Sendable (Int32) -> Bool = { pid in
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public static let defaultMarkerValue: @Sendable () -> String = {
        let hex = (0..<4).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
        return "lvx-\(hex)"
    }
}
