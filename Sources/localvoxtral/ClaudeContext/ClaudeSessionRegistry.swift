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
    /// How long a focus declaration stays credible. The opencode TUI half
    /// re-declares on every displayed-session change AND retracts explicitly
    /// (`FocusCleared`) when the pane leaves its session view, so this bound
    /// only defends against lost writes and a silently dead TUI: at a
    /// 20-second heartbeat, 45 seconds tolerates one lost beat plus jitter
    /// while keeping a pane that stopped declaring from steering the TTY join
    /// for long. Stale focus is treated as ABSENT information, never as
    /// "probably still the same one".
    public static let defaultFocusDeclarationTTL: TimeInterval = 45
    /// Focus declarations are keyed by TTY device, one live entry per pane.
    /// Matches the session cap: there is no reason to remember more panes than
    /// we would remember sessions.
    public static let defaultMaxFocusDeclarations = 32

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
    public var focusDeclarationTTL: TimeInterval
    public var maxFocusDeclarations: Int

    public init(
        maxSessions: Int = 32,
        maxSessionsPerOrigin: Int = Self.defaultMaxSessionsPerOrigin,
        sessionTTL: TimeInterval = 4 * 60 * 60,
        pidlessLocalSessionTTL: TimeInterval = Self.defaultPIDLessLocalSessionTTL,
        focusDeclarationTTL: TimeInterval = Self.defaultFocusDeclarationTTL,
        maxFocusDeclarations: Int = Self.defaultMaxFocusDeclarations
    ) {
        self.maxSessions = maxSessions
        self.maxSessionsPerOrigin = maxSessionsPerOrigin
        self.sessionTTL = sessionTTL
        self.pidlessLocalSessionTTL = pidlessLocalSessionTTL
        self.focusDeclarationTTL = focusDeclarationTTL
        self.maxFocusDeclarations = maxFocusDeclarations
    }

    public static let `default` = ClaudeRegistryLimits()
}

/// Sessions the broker knows about, keyed by session id, with markers.
///
/// `Mutex` + `Sendable` per repo convention (no custom actors): the broker's
/// accept thread writes, the main actor reads, and neither should await.
public final class ClaudeSessionRegistry: Sendable {
    /// One pane's declared focus: "the TTY this is keyed by currently displays
    /// this session", as published by an agent that can actually see its own
    /// pane (the opencode TUI half). Held per TTY, not per session — focus is
    /// a property of the pane.
    private struct FocusDeclaration {
        var sessionID: String
        /// The declaring process's pid. Cross-checked against the focused
        /// session's registered pid at resolution: a declaration that outlived
        /// its process must not steer a recycled TTY.
        var declaredPID: Int32
        var declaredAt: Date
    }

    private struct State {
        var sessions: [String: ClaudeSessionSnapshot] = [:]
        var markerIndex: [String: String] = [:] // marker value -> session id
        var focusByTTY: [String: FocusDeclaration] = [:]
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
    ///   - environment: allowlisted env labels the REMOTE listener read off the
    ///     request headers, likewise absent from the local wire. Untrusted
    ///     labels about another machine: the reducer stores them only for a
    ///     `.remote` origin and NEVER in `process`, which is what the
    ///     local-only arms below read.
    /// - Returns: the resulting snapshot, or nil if the record was dropped.
    @discardableResult
    public func ingest(
        _ record: ClaudeHookRecord,
        origin: ClaudeTransportOrigin,
        snippets: [ClaudeContentSnippet] = [],
        environment: ClaudeRemoteSessionEnvironment? = nil
    ) -> ClaudeSessionSnapshot? {
        let timestamp = now()
        // A LOCAL Claude record whose raw id spells another namespace's prefix
        // is spelling a key that can never be its own: Claude Code ids are
        // bare UUIDs, opencode ids get the prefix added HERE, and remote ids
        // are minted by the remote listener (which passes them in pre-scoped,
        // over a remote origin — that path is exempt below). Dropping these
        // outright closes the aliasing hole where a crafted `claude` record
        // literally named "opencode:X" would collide with opencode's raw "X".
        if origin.isLocalAuthenticated, record.agent == .claude,
           record.sessionID.hasPrefix(ClaudeAgentSessionScope.opencodePrefix)
               || record.sessionID.hasPrefix(ClaudeRemoteSessionScope.prefix) {
            return nil
        }
        // Receiver-side namespacing, recomputed on EVERY ingest from the agent
        // tag — mirroring how the remote listener scopes ids under the host
        // that authenticated them. The registry keys, the focus table, and
        // every snapshot all speak scoped ids from here on.
        var record = record
        record.sessionID = ClaudeAgentSessionScope.scopedSessionID(
            agent: record.agent, sessionID: record.sessionID
        )
        return state.withLock { state -> ClaudeSessionSnapshot? in
            pruneLocked(&state, now: timestamp)

            // Focus records are pane state, not session state, and they are an
            // opencode-only mechanism (Claude Code has no way to know what a
            // pane displays — a `.claude` focus record is an inconsistency to
            // refuse, not to honor). Everything is validated BEFORE any focus
            // state is touched: an invalid declaration must not be able to
            // suppress an existing per-session TTY claim for the focus TTL —
            // that ordering bug is exactly what review C2b caught.
            switch record.event {
            case .focusChanged:
                guard isValidFocusDeclarationLocked(state, record: record, origin: origin) else {
                    return nil
                }
                recordFocusLocked(&state, record: record, now: timestamp)
                // Falls through: the target exists (validated), so the reduce
                // below bumps its activity.
            case .focusCleared:
                guard record.agent == .opencode, origin.isLocalAuthenticated,
                      let tty = record.process?.tty, !tty.isEmpty
                else { return nil }
                // Unconditional removal by TTY, no pid cross-check: a clear
                // can only ever WIDEN abstention, and requiring the declaring
                // pid to match would let a restarted TUI's retraction bounce
                // off its predecessor's lingering entry.
                state.focusByTTY.removeValue(forKey: tty)
                guard state.sessions[record.sessionID] != nil else { return nil }
            default:
                break
            }

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
                // The agent is likewise fixed at first sight. Agent scoping
                // makes an honest collision impossible (the scoped keys
                // differ), so a mismatch here is a record spelling another
                // agent's scoped id — drop it rather than let one agent's
                // records mutate another's session.
                if snapshot.agent != record.agent { return nil }
            } else {
                if record.event == .sessionEnd { return nil } // nothing to start
                let marker = ClaudeSessionMarker(value: allocateUniqueMarkerLocked(&state))
                snapshot = ClaudeSessionSnapshot(
                    sessionID: record.sessionID,
                    origin: origin,
                    agent: record.agent,
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
                environment: environment,
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
    /// publishing that pane's TTY.
    ///
    /// Two kinds of evidence can bind a TTY to a session, and they must agree:
    ///
    /// * **Per-session claims** (Claude Code): each hook record carries the
    ///   session's controlling TTY, so a device usually maps to one session.
    ///   Two live claims on one TTY (a suspended Claude beneath a new one in
    ///   the same pane) abstain `.ambiguous`; the caller's marker fallback may
    ///   still disambiguate.
    /// * **Focus declarations** (opencode): one opencode process hosts many
    ///   sessions on one TTY and its TUI shows one at a time, so its sessions
    ///   carry no TTY at all — the TUI half instead declares which session the
    ///   pane DISPLAYS (`FocusChanged`, freshness-bounded). A fresh declaration
    ///   resolves the TTY to that session iff the session is live and its
    ///   registered pid matches the declarer's; a declaration whose session is
    ///   gone or unverifiable abstains rather than falling back to guesswork,
    ///   and a stale declaration is ABSENT information, not a hint.
    ///
    /// When both kinds of evidence exist for one TTY and disagree — a live
    /// per-session claim next to a fresh focus declaration naming a different
    /// session — that is two agents each positively claiming the same pane,
    /// and the only safe answer is `.ambiguous`.
    public func resolve(tty: String) -> ClaudeMarkerResolution {
        let timestamp = now()
        return state.withLock { state in
            let matches = state.sessions.values.filter { snapshot in
                snapshot.origin.isLocalAuthenticated
                    && snapshot.process?.tty == tty
                    && isFresh(snapshot, now: timestamp)
            }

            if let focus = state.focusByTTY[tty],
               timestamp.timeIntervalSince(focus.declaredAt) <= limits.focusDeclarationTTL {
                guard let focused = state.sessions[focus.sessionID],
                      focused.origin.isLocalAuthenticated,
                      isFresh(focused, now: timestamp),
                      focused.process?.claudePID == focus.declaredPID
                else {
                    // A fresh declaration for a session that is dead, unknown,
                    // or from a different process than the declarer. The pane
                    // positively told us what it displays and we cannot verify
                    // it — trusting any OTHER candidate now would contradict
                    // the freshest evidence we have, so abstain outright.
                    return .stale
                }
                if matches.isEmpty || matches.contains(where: { $0.sessionID == focus.sessionID }) {
                    return .resolved(focused)
                }
                return .ambiguous
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

    /// Look up by herdr pane id — the herdr focus join. LOCAL sessions only: a
    /// remote host's pane ids live in another machine's herdr and could collide
    /// with (or deliberately mirror) a local pane's id; matching them here would
    /// let an SSH host claim a local pane by echoing its pane id.
    ///
    /// Every opencode session in one TUI shares the pane id AND the pid, so
    /// with two sessions this used to hit `.ambiguous` before focus could
    /// participate — the herdr arm silently stopped joining opencode panes
    /// (review C3). Fresh focus declarations now arbitrate multi-candidate
    /// panes the same way they arbitrate a TTY: a verified declaration
    /// (fresh, pid-matched) naming EXACTLY ONE of the pane's candidates
    /// resolves to it; anything else stays `.ambiguous`.
    public func resolve(herdrPaneID: String) -> ClaudeMarkerResolution {
        let timestamp = now()
        return state.withLock { state in
            let matches = state.sessions.values.filter { snapshot in
                snapshot.origin.isLocalAuthenticated
                    && snapshot.process?.herdrPaneID == herdrPaneID
                    && isFresh(snapshot, now: timestamp)
            }
            switch matches.count {
            case 0:
                let hadStale = state.sessions.values.contains {
                    $0.origin.isLocalAuthenticated && $0.process?.herdrPaneID == herdrPaneID
                }
                return hadStale ? .stale : .unknown
            case 1:
                return .resolved(matches[0])
            default:
                // Focus declarations are keyed by the pane's inner TTY, which
                // the outer herdr surface cannot know — so scan all fresh,
                // pid-verified declarations for ones naming a candidate of
                // THIS pane. Exactly one distinct session may win; zero or
                // several (two TUIs somehow claiming siblings) abstain.
                let focused = Set(state.focusByTTY.values.compactMap { focus -> String? in
                    guard timestamp.timeIntervalSince(focus.declaredAt) <= limits.focusDeclarationTTL,
                          let candidate = matches.first(where: { $0.sessionID == focus.sessionID }),
                          candidate.process?.claudePID == focus.declaredPID
                    else { return nil }
                    return focus.sessionID
                })
                guard focused.count == 1, let winner = focused.first,
                      let snapshot = matches.first(where: { $0.sessionID == winner })
                else { return .ambiguous }
                return .resolved(snapshot)
            }
        }
    }

    /// Look up by Claude Code "Remote Control" bridge session id — the browser
    /// tab join.
    ///
    /// This is the ONE arm that spans LOCAL and REMOTE sessions, and that is a
    /// property of the key rather than a relaxed rule. Every other local arm
    /// keys on a per-machine name (a TTY device, a herdr pane id, a pid) that
    /// another machine can hold identically, so matching a remote session on one
    /// would let an SSH host claim a local pane by echoing it. A bridge session
    /// id is allocated by Anthropic's bridge, is globally unique, and is what
    /// the browser's address bar shows — a remote host reporting one is
    /// reporting its own, and the tab the user is looking at IS that session's
    /// UI whichever machine runs it. `ClaudeSessionSnapshot.bridgeSessionID`
    /// still routes the read by origin (local reads `process`, remote reads
    /// `remoteEnvironment`), so neither side reaches the other's storage.
    ///
    /// Exact equality, and zero or several matches abstain: two sessions
    /// reporting one bridge id means we cannot tell which the tab belongs to.
    public func resolve(bridgeSessionID: String) -> ClaudeMarkerResolution {
        let timestamp = now()
        return state.withLock { state in
            let matches = state.sessions.values.filter { snapshot in
                snapshot.bridgeSessionID == bridgeSessionID && isFresh(snapshot, now: timestamp)
            }
            switch matches.count {
            case 0:
                let hadStale = state.sessions.values.contains {
                    $0.bridgeSessionID == bridgeSessionID
                }
                return hadStale ? .stale : .unknown
            case 1:
                return .resolved(matches[0])
            default:
                return .ambiguous
            }
        }
    }

    /// Look up by cmux surface id — the LOCAL half of the cmux focus join.
    ///
    /// Exactly the shape of `resolve(herdrPaneID:)`, and local-only for exactly
    /// the same reason: `process` is written only from a peer-UID-authenticated
    /// AF_UNIX record, so a surface id here was observed by a process running as
    /// this user on this machine. A remote session's cmux surface id lives in
    /// `remoteEnvironment` and is reachable only through
    /// `resolveRemote(cmuxSurfaceID:)` — two methods rather than one, so neither
    /// origin filter can be lost in a future edit without deleting a whole
    /// function.
    ///
    /// Multi-candidate panes get the same focus-declaration arbitration as
    /// herdr: one opencode TUI hosts many sessions on one surface, and without
    /// it the arm would silently stop joining those panes (review C3).
    public func resolve(cmuxSurfaceID: String) -> ClaudeMarkerResolution {
        let timestamp = now()
        return state.withLock { state in
            let matches = state.sessions.values.filter { snapshot in
                snapshot.origin.isLocalAuthenticated
                    && snapshot.process?.cmuxSurfaceID == cmuxSurfaceID
                    && isFresh(snapshot, now: timestamp)
            }
            switch matches.count {
            case 0:
                let hadStale = state.sessions.values.contains {
                    $0.origin.isLocalAuthenticated && $0.process?.cmuxSurfaceID == cmuxSurfaceID
                }
                return hadStale ? .stale : .unknown
            case 1:
                return .resolved(matches[0])
            default:
                let focused = Set(state.focusByTTY.values.compactMap { focus -> String? in
                    guard timestamp.timeIntervalSince(focus.declaredAt) <= limits.focusDeclarationTTL,
                          let candidate = matches.first(where: { $0.sessionID == focus.sessionID }),
                          candidate.process?.claudePID == focus.declaredPID
                    else { return nil }
                    return focus.sessionID
                })
                guard focused.count == 1, let winner = focused.first,
                      let snapshot = matches.first(where: { $0.sessionID == winner })
                else { return .ambiguous }
                return .resolved(snapshot)
            }
        }
    }

    /// Look up by cmux surface id among REMOTE sessions — the `cmux ssh` half.
    ///
    /// This is the one join where a remote session may be selected by something
    /// other than a broker-allocated marker, and it is sound for a specific
    /// reason: the surface id was MINTED by the cmux app on this Mac and pushed
    /// into the remote shell's environment by cmux's own ssh relay. The remote
    /// hook then reports it back over the authenticated listener. So the value
    /// is ours, travelling out and back, and the equality test is between two
    /// labels — nothing here reads a remote filesystem, and
    /// `ClaudeSessionSnapshot.localWorkspacePath` still refuses to hand a remote
    /// cwd to anything that could.
    ///
    /// A remembered label is NOT by itself evidence that the session still holds
    /// the surface: a compromised ENROLLED host can replay an id from an earlier
    /// `cmux ssh` session after that surface returned to a local shell. The
    /// resolver therefore additionally requires cmux to report the focused
    /// surface's workspace as a live remote workspace before accepting anything
    /// this method returns (`remoteClaimIsCurrentlyHosted`). What remains is
    /// bounded by host enrollment, which the user controls and can revoke.
    ///
    /// Mirrors the local method's shape, minus focus arbitration: focus
    /// declarations are a LOCAL opencode mechanism keyed by a local TTY, and a
    /// remote candidate must never be resolvable by one.
    public func resolveRemote(cmuxSurfaceID: String) -> ClaudeMarkerResolution {
        let timestamp = now()
        return state.withLock { state in
            let matches = state.sessions.values.filter { snapshot in
                snapshot.remoteSessionEnvironment?.cmuxSurfaceID == cmuxSurfaceID
                    && isFresh(snapshot, now: timestamp)
            }
            switch matches.count {
            case 0:
                let hadStale = state.sessions.values.contains {
                    $0.remoteSessionEnvironment?.cmuxSurfaceID == cmuxSurfaceID
                }
                return hadStale ? .stale : .unknown
            case 1:
                return .resolved(matches[0])
            default:
                return .ambiguous
            }
        }
    }

    /// Distinct herdr socket paths across live LOCAL sessions. The resolver
    /// refuses to guess between multiple herdr sessions, so it needs the count,
    /// not just one path.
    public func liveLocalHerdrSocketPaths() -> Set<String> {
        let timestamp = now()
        return state.withLock { state in
            Set(state.sessions.values.compactMap { snapshot in
                guard snapshot.origin.isLocalAuthenticated,
                      isFresh(snapshot, now: timestamp)
                else { return nil }
                return snapshot.process?.herdrSocketPath
            })
        }
    }

    /// Live sessions from ONE enrolled remote host that reported both halves of
    /// a herdr pane identity, most recently active first.
    ///
    /// The mirror image of `liveLocalHerdrSocketPaths()`, and deliberately its
    /// opposite in every filter: `.remote` origin only, scoped to one host's
    /// channel, reading `remoteSessionEnvironment` rather than `process`. Those
    /// two fields never mix (PR #216), so this cannot see a local session's
    /// pane and the local arms cannot see one of these.
    ///
    /// Nothing here is trusted. Both values are opaque labels naming things on
    /// the host that reported them: this returns candidates, and the join arm
    /// still has to prove — over the forwarded socket, against that host's own
    /// herdr — that the focused pane is this session's.
    ///
    /// SEVERAL candidates is the expected shape, not an ambiguity: two Claude
    /// sessions in two herdr panes is the ordinary multiplexer workflow. The
    /// caller narrows by the herdr's own FOCUSED pane id and requires exactly
    /// one match there; what it refuses is two candidates claiming the same
    /// pane id, and two distinct herdr sockets on the host.
    public func liveRemoteHerdrSessions(hostID: String) -> [ClaudeSessionSnapshot] {
        let channel = ClaudeRemoteSessionScope.channel(hostID: hostID)
        let timestamp = now()
        return state.withLock { state in
            state.sessions.values
                .filter { snapshot in
                    guard case .remote(let sessionChannel) = snapshot.origin,
                          sessionChannel == channel,
                          isFresh(snapshot, now: timestamp)
                    else { return false }
                    let environment = snapshot.remoteSessionEnvironment
                    return environment?.herdrPaneID != nil && environment?.herdrSocketPath != nil
                }
                .sorted { $0.lastActivity > $1.lastActivity }
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
            state.focusByTTY.removeAll()
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
        // Expired focus declarations are dead weight: resolution already treats
        // them as absent, this just keeps the table from accumulating panes.
        for (tty, focus) in state.focusByTTY
        where now.timeIntervalSince(focus.declaredAt) > limits.focusDeclarationTTL {
            state.focusByTTY.removeValue(forKey: tty)
        }
    }

    /// Every condition a focus declaration must meet BEFORE any focus state is
    /// mutated (review C2b: writing first let an invalid declaration suppress
    /// a live per-session TTY claim for the focus TTL even though ingest
    /// rejected the record):
    ///
    /// * opencode-only — focus is that agent's mechanism, and a `.claude`
    ///   focus record is an inconsistency to refuse (review hardening);
    /// * LOCAL transport only — a remote host's TTY names a device on another
    ///   machine, exactly the reason `resolve(tty:)` refuses remote candidates;
    /// * carries the declaring pane's device — a claim with no TTY binds
    ///   nothing;
    /// * names a session the registry KNOWS, of the same agent, itself locally
    ///   authenticated, registered to the declaring process. A declaration
    ///   that could never resolve must not exist — and a session the pane
    ///   displays but whose records were lost self-heals at the next
    ///   heartbeat, once its own records arrive.
    private func isValidFocusDeclarationLocked(
        _ state: State,
        record: ClaudeHookRecord,
        origin: ClaudeTransportOrigin
    ) -> Bool {
        guard record.agent == .opencode,
              origin.isLocalAuthenticated,
              let process = record.process,
              let tty = process.tty, !tty.isEmpty,
              let target = state.sessions[record.sessionID],
              target.agent == record.agent,
              target.origin.isLocalAuthenticated,
              target.process?.claudePID == process.claudePID
        else { return false }
        return true
    }

    private func recordFocusLocked(
        _ state: inout State,
        record: ClaudeHookRecord,
        now: Date
    ) {
        guard let process = record.process, let tty = process.tty else { return }
        state.focusByTTY[tty] = FocusDeclaration(
            sessionID: record.sessionID,
            declaredPID: process.claudePID,
            declaredAt: now
        )
        // Bounded like everything else a peer can grow: beyond the cap the
        // oldest declaration goes — it is the one closest to expiring anyway.
        while state.focusByTTY.count > limits.maxFocusDeclarations {
            guard let oldest = state.focusByTTY.min(by: {
                ($0.value.declaredAt, $0.key) < ($1.value.declaredAt, $1.key)
            }) else { break }
            state.focusByTTY.removeValue(forKey: oldest.key)
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
