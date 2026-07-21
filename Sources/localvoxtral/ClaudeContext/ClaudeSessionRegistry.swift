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
    /// A local session without a Claude pid cannot be probed for liveness. Five
    /// minutes keeps brief publisher-metadata failures useful while bounding a
    /// dead session's joinable exposure far below the normal four-hour TTL.
    public static let defaultPIDLessLocalSessionTTL: TimeInterval = 5 * 60
    /// When origins compete for the global cap, no one origin may retain more
    /// than this many sessions. Eight covers a generous set of terminal tabs
    /// while leaving most of the global registry available to other origins.
    public static let defaultMaxSessionsPerOrigin = 8

    /// Hard cap on retained sessions. Beyond this, the least-recently-active is
    /// evicted — a user with hundreds of stale sessions must not grow the app.
    public var maxSessions: Int
    /// Sub-quota applied per transport origin when more than one origin is
    /// present. A lone origin may use the global cap; once another arrives,
    /// churn is evicted from the bursting origin first.
    public var maxSessionsPerOrigin: Int
    /// A session with no hook activity for this long is stale. Claude Code can
    /// die without firing SessionEnd (SIGKILL, a closed terminal), so TTL plus
    /// PID liveness — not SessionEnd alone — is what keeps the registry honest.
    public var sessionTTL: TimeInterval
    public var pidlessLocalSessionTTL: TimeInterval

    public init(
        maxSessions: Int = 32,
        maxSessionsPerOrigin: Int = Self.defaultMaxSessionsPerOrigin,
        sessionTTL: TimeInterval = 4 * 60 * 60,
        pidlessLocalSessionTTL: TimeInterval = Self.defaultPIDLessLocalSessionTTL
    ) {
        self.maxSessions = maxSessions
        self.maxSessionsPerOrigin = maxSessionsPerOrigin
        self.sessionTTL = sessionTTL
        self.pidlessLocalSessionTTL = pidlessLocalSessionTTL
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
            enforceCapLocked(&state, keeping: record.sessionID)
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

    /// Look up by the focused pane's controlling TTY — the focus join.
    ///
    /// Only LOCAL sessions are candidates: a remote session's TTY names a
    /// device on another machine, where it can collide with an unrelated local
    /// pane — matching it here would let an SSH host claim a local pane by
    /// publishing that pane's TTY. Abstains `.ambiguous` when two live local
    /// sessions claim one TTY (a suspended Claude beneath a new one in the same
    /// pane); the caller's marker fallback may still disambiguate.
    public func resolve(tty: String) -> ClaudeMarkerResolution {
        let timestamp = now()
        return state.withLock { state in
            let matches = state.sessions.values.filter { snapshot in
                snapshot.origin.isLocalAuthenticated
                    && snapshot.process?.tty == tty
                    && isFresh(snapshot, now: timestamp)
            }
            switch matches.count {
            case 0:
                let hadStale = state.sessions.values.contains {
                    $0.origin.isLocalAuthenticated && $0.process?.tty == tty
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

    /// Forget every SSH-remote session whose transport channel is not in `channels`.
    ///
    /// This is how a revoked or removed host stops having cached context here.
    /// Revocation is immediate at the door — `ClaudeRemoteHostRegistry` refuses
    /// the token on the next request — but that only stops NEW records; whatever
    /// the host already published would otherwise sit in this registry until TTL
    /// expired it, joinable by its marker the whole time. A user who revokes a
    /// host means "that machine's context is no longer mine to use", not "no
    /// more of it, but keep the last four hours".
    ///
    /// The channel is the transport's own answer (`ClaudeRemoteSessionScope.channel`,
    /// set by the listener from the token that authenticated the connection), so
    /// this identifies a host's sessions without consulting anything on the wire.
    ///
    /// `.localAuthenticated` sessions and remote sessions from any other
    /// transport are never candidates, whatever `channels` says. Their trust
    /// and lifecycle have nothing to do with SSH host enrollment.
    ///
    /// Eviction of a session and of its marker index entry happens under one
    /// hold of the state mutex — a reader must never observe a marker pointing
    /// at a session that is already gone, nor a session reachable by a marker
    /// that was supposed to die with it.
    ///
    /// - Returns: how many sessions were evicted.
    @discardableResult
    public func evictRemoteSessions(notIn channels: Set<String>) -> Int {
        let sshPrefix = ClaudeRemoteSessionScope.channel(hostID: "")
        return state.withLock { state in
            let doomed = state.sessions.values.filter { snapshot in
                guard case .remote(let channel) = snapshot.origin else { return false }
                return channel.hasPrefix(sshPrefix) && !channels.contains(channel)
            }.map(\.sessionID)
            for sessionID in doomed {
                removeLocked(&state, sessionID: sessionID)
            }
            return doomed.count
        }
    }

    public func removeAll() {
        state.withLock { state in
            state.sessions.removeAll()
            state.markerIndex.removeAll()
        }
    }

    // MARK: - Locked helpers

    private func isFresh(_ snapshot: ClaudeSessionSnapshot, now: Date) -> Bool {
        let ttl: TimeInterval
        if snapshot.origin.isLocalAuthenticated, snapshot.process?.claudePID == nil {
            ttl = min(limits.sessionTTL, limits.pidlessLocalSessionTTL)
        } else {
            ttl = limits.sessionTTL
        }
        guard now.timeIntervalSince(snapshot.lastActivity) <= ttl else { return false }
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

    /// `upserted` is the sessionID this upsert just wrote: on a lastActivity
    /// tie (frozen test clocks, sub-tick batches) the sessionID tiebreak could
    /// otherwise select the record that triggered the enforcement — evicting
    /// the newest data is never the right answer, so it is pinned and the
    /// next-oldest tied sibling goes instead.
    private func enforceCapLocked(_ state: inout State, keeping upserted: String? = nil) {
        let grouped = Dictionary(grouping: state.sessions.values, by: \.origin)
        if grouped.count > 1 {
            // Always reserve at least one global slot for a competing origin,
            // even when a caller configures a sub-quota above a small test cap.
            let quota = min(
                max(0, limits.maxSessionsPerOrigin),
                max(0, limits.maxSessions - 1)
            )
            for sessions in grouped.values where sessions.count > quota {
                // The pin never relaxes the quota: with the pinned session
                // excluded there are still at least `count - quota` evictable
                // siblings whenever quota >= 1.
                let evictable = sessions.sorted(by: Self.evictionPrecedes)
                    .filter { $0.sessionID != upserted }
                    .prefix(sessions.count - quota)
                for snapshot in evictable {
                    removeLocked(&state, sessionID: snapshot.sessionID)
                }
            }
        }

        guard state.sessions.count > limits.maxSessions else { return }
        let ordered = state.sessions.values.sorted(by: Self.evictionPrecedes)
        for snapshot in ordered.prefix(state.sessions.count - limits.maxSessions) {
            removeLocked(&state, sessionID: snapshot.sessionID)
        }
    }

    /// Stable tie-breaking keeps eviction reproducible when a burst lands in
    /// one clock tick (common in tests and possible for batched hook records).
    private static func evictionPrecedes(
        _ lhs: ClaudeSessionSnapshot,
        _ rhs: ClaudeSessionSnapshot
    ) -> Bool {
        if lhs.lastActivity != rhs.lastActivity {
            return lhs.lastActivity < rhs.lastActivity
        }
        return lhs.sessionID < rhs.sessionID
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
        //
        // Hex-only, because the fallback must satisfy the SAME grammar the
        // random allocator emits (`lvx-` + lowercase hex —
        // `ClaudeMarkerSequence.isValidMarker`). The old `lvx-fallback-<n>`
        // could not: `k` is not in the allowlist, so the marker was minted and
        // indexed but `ClaudeMarkerSequence` refused to write it to a title,
        // leaving that session permanently unjoinable — the marker join is
        // positive-only, so it would silently never get context again.
        //
        // Terminating: each candidate is checked against the index, and the
        // counter's space is vastly larger than the number of live sessions.
        var counter = 0
        while true {
            let candidate = "lvx-" + String(format: "%08x", counter)
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
