import ClaudeContextWire
import Foundation

/// Lifecycle of a session as the hooks describe it.
public enum ClaudeSessionActivity: String, Sendable, Equatable {
    /// Between UserPromptSubmit and Stop — the model is working.
    case working
    /// Started, or finished a turn; waiting on the user.
    case idle
    /// SessionEnd seen. Evicted immediately; this case exists for the record
    /// returned by the evicting call.
    case ended
}

/// A file the session touched recently.
public struct ClaudeRecentFile: Sendable, Equatable {
    public var path: String
    public var kind: ClaudeFileTouchKind
    public var lastTouched: Date

    public init(path: String, kind: ClaudeFileTouchKind, lastTouched: Date) {
        self.path = path
        self.kind = kind
        self.lastTouched = lastTouched
    }
}

/// The off-screen state we keep for one Claude Code session.
///
/// This is the whole point of the transport: when the user dictates into a
/// terminal, we want to know what they and the model were just doing, without
/// reading their screen.
///
/// What is stored is bounded and specific:
/// * the latest prior user prompt (what they last asked),
/// * workspace/session metadata,
/// * recent read/edited file paths,
/// * timestamps and lifecycle state.
///
/// What is never stored: transcript contents (we do not even receive the
/// path), file contents, command output, or model responses.
/// A session's mod channel, for its liveness (#1646).
package struct ClaudeModChannelLiveness: Sendable, Equatable {
    /// The hub's token for the attached channel; nil once it detached.
    package var token: UInt64?
    /// The Claude Code process the `--attach` ran under.
    package var claudePID: Int32
    /// When the channel was last known open: its attach, then its detach.
    package var lastSeen: Date
}

public struct ClaudeSessionSnapshot: Sendable, Equatable {
    public var sessionID: String
    /// Assigned by the broker from peer credentials. Never from the record.
    public var origin: ClaudeTransportOrigin
    /// Which coding agent this session belongs to, fixed at first sight like
    /// `origin`. Decides session-id namespacing (`ClaudeAgentSessionScope`)
    /// and any per-agent rule a join arm needs.
    public var agent: ClaudeHookAgent
    /// Local path or opaque remote label — the type enforces which.
    public var workspace: ClaudeWorkspaceReference?
    /// The most recent prompt the user submitted. By the time dictation reads
    /// this, it is by construction the *prior* prompt.
    public var latestPriorUserPrompt: String?
    public var latestPriorUserPromptAt: Date?
    /// Every submit the session reported, with or without its text: the
    /// evidence that a prompt holding the app's last commit is still unsent
    /// (#802).
    public var promptsSubmitted: Int
    public var recentFiles: [ClaudeRecentFile]
    /// Bounded, sanitized excerpts of what the session's tools just handled.
    ///
    /// Only ever populated for a REMOTE session, because only the remote
    /// transport carries them: a local session's files are on this machine, and
    /// `ClaudeRepoCollecting` can read them properly rather than settle for
    /// whatever a hook happened to quote. This is not a second local collector —
    /// it is the only thing we will ever know about a remote tree.
    public var recentSnippets: [ClaudeContentSnippet]
    public var activity: ClaudeSessionActivity
    public var process: ClaudeHookProcessInfo?
    /// Allowlisted environment labels a REMOTE session's hooks reported.
    ///
    /// Deliberately NOT folded into `process`: that block is what the local
    /// join arms read, and every one of them (`resolve(tty:)`,
    /// `resolve(herdrPaneID:)`, `liveLocalHerdrSocketPaths()`) pairs an
    /// `origin.isLocalAuthenticated` filter with a `process` field. Keeping the
    /// remote labels in their own field means a remote host cannot reach those
    /// arms even if a future edit forgot the origin filter — there is nothing
    /// of its in the field they read.
    ///
    /// Only ever populated for a `.remote` origin (`ClaudeSessionReducer`), and
    /// `remoteSessionEnvironment` re-states that at the read side.
    public var remoteEnvironment: ClaudeRemoteSessionEnvironment?
    /// The repository a remote session's cwd names by Claude Code's worktree
    /// layout (`ClaudeWorkspaceReference.claudeWorktreeRepository`). A label,
    /// like `workspace`; remote only.
    public var remoteWorktreeRepository: String?
    /// The harness's own title for the session, as its last record carrying
    /// one said (#1020). A name, never evidence: nothing but
    /// `SessionDefaultNames` reads it, the registry file does not keep it,
    /// and no log line carries it.
    package var harnessTitle: String?
    /// The shim version a remote session's last accepted hook sent: the
    /// Claude Code plugin's `X-Lvx-Plugin-Version`, or the Vibe hooks'
    /// version. A running session keeps the shim it loaded, so this can
    /// trail its host's (`AgentCLIDoctorChecks.staleSessions`). Nil for a
    /// local session; not persisted.
    package var remoteShimVersion: ClaudeRemotePluginVersionReport?
    /// The id of the last Vibe prompt this session submitted (#1285). Every
    /// Vibe hook re-sends the newest prompt, so a submit carrying this id
    /// again is that prompt read again, not a new one. Not persisted.
    package var lastSubmittedPromptID: String?
    /// The session's mod channel as the broker last saw it (#1646). While it
    /// is attached the session does not expire; once it detaches, the TTL
    /// counts from then. In memory only: a channel ends with the app.
    package var modChannel: ClaudeModChannelLiveness?
    public var firstSeen: Date
    public var lastActivity: Date

    /// Only ever non-nil for a locally authenticated session. This is the
    /// accessor a repo collector uses, and the reason a remote record cannot
    /// reach the filesystem: there is no path here to hand it.
    public var localWorkspacePath: LocalWorkspacePath? {
        guard origin.isLocalAuthenticated else { return nil }
        return workspace?.localPath
    }

    /// The workspace learned terms are filed under: `workspace`, except that
    /// a remote session's label is its repository's name when one is known
    /// (`remoteProject`, `preferringRemoteProject`). Only for that key: the
    /// session keeps showing its own cwd label everywhere else.
    package var learnedTermWorkspace: ClaudeWorkspaceReference? {
        guard !origin.isLocalAuthenticated else { return workspace }
        return workspace?.preferringRemoteProject(remoteProject)
    }

    /// A remote session's repository name: the one its host sent, else the
    /// one its cwd's Claude Code worktree layout gives. Nil for a local
    /// session.
    package var remoteProject: String? {
        guard !origin.isLocalAuthenticated else { return nil }
        return remoteEnvironment?.project ?? remoteWorktreeRepository
    }

    /// The branch a remote session's host reported (`X-Lvx-Env-Branch`), a
    /// label. Nil for a local session, whose branch the app reads itself.
    package var remoteBranch: String? {
        remoteSessionEnvironment?.branch
    }

    /// Recent files that name paths on THIS machine.
    ///
    /// Empty for a remote session, whose paths name files in another host's
    /// filesystem where they would either not exist or — worse — exist and be
    /// something else entirely. `localWorkspacePath` makes the cwd's version of
    /// this a compile-time guarantee; per-file paths are plain strings on the
    /// wire, so this accessor is the gate for them. Consumers that touch the
    /// filesystem must read files from here, never from `recentFiles`.
    public var localRecentFiles: [ClaudeRecentFile] {
        guard origin.isLocalAuthenticated else { return [] }
        return recentFiles
    }

    /// The remote env labels, and nil for any local session — the mirror image
    /// of `localWorkspacePath`.
    ///
    /// A local session's pane identity arrives inside `process`, vouched for by
    /// peer-UID authentication on the AF_UNIX socket. Anything reading this
    /// accessor is by definition reasoning about another machine, and the gate
    /// makes that impossible to forget.
    public var remoteSessionEnvironment: ClaudeRemoteSessionEnvironment? {
        guard case .remote = origin else { return nil }
        return remoteEnvironment
    }

    /// The Claude Code "Remote Control" bridge session id this session last
    /// reported, from whichever side reported it.
    ///
    /// One of the two join keys that legitimately span local and remote (the
    /// other is `desktopSessionID`), and the reason is a property of the value,
    /// not a relaxation of the rule: the
    /// id is allocated by Anthropic's bridge, is globally unique, and appears in
    /// the browser URL the user is looking at. A remote host publishing an id
    /// can therefore not collide with a local session's — unlike a TTY path, a
    /// pane id, or a pid, all of which are per-machine names that another
    /// machine can mirror by accident or on purpose. What it can do is claim an
    /// id that is genuinely its own, which is exactly the case this arm is for:
    /// the browser tab is the UI of whichever machine runs that session.
    ///
    /// The origin still decides WHICH field is read — `process` for a local
    /// session (peer-UID authenticated), `remoteEnvironment` for a remote one —
    /// so neither side can reach into the other's storage.
    public var bridgeSessionID: String? {
        switch origin {
        case .localAuthenticated:
            return process?.bridgeSessionID
        case .remote:
            return remoteSessionEnvironment?.bridgeSessionID
        }
    }

    /// The Claude Desktop Code-tab session handle (`local_<uuid>`) this session
    /// last reported, from whichever side reported it.
    ///
    /// Spans local and remote for the same reason `bridgeSessionID` does: the
    /// desktop app allocates the id, it is a UUID, and it names the web view the
    /// desktop window shows that session in. Claude Desktop runs Code-tab
    /// sessions on this Mac AND on ssh hosts, and the window is the UI of
    /// whichever machine runs the session. The origin still decides which field
    /// is read.
    public var desktopSessionID: String? {
        switch origin {
        case .localAuthenticated:
            return process?.desktopSessionID
        case .remote:
            return remoteSessionEnvironment?.desktopSessionID
        }
    }

    package init(
        sessionID: String,
        origin: ClaudeTransportOrigin,
        agent: ClaudeHookAgent = .claude,
        firstSeen: Date
    ) {
        self.sessionID = sessionID
        self.origin = origin
        self.agent = agent
        self.workspace = nil
        self.latestPriorUserPrompt = nil
        self.latestPriorUserPromptAt = nil
        self.promptsSubmitted = 0
        self.recentFiles = []
        self.recentSnippets = []
        self.activity = .idle
        self.process = nil
        self.remoteEnvironment = nil
        self.remoteWorktreeRepository = nil
        self.harnessTitle = nil
        self.lastSubmittedPromptID = nil
        self.firstSeen = firstSeen
        self.lastActivity = firstSeen
    }
}

/// Pure event reduction. Split out from the registry so the "what does this
/// event mean" rules are testable without sockets, clocks, or locks.
public enum ClaudeSessionReducer {
    /// Cap on retained file history per session. Recent means recent.
    public static let maxRecentFiles = 24

    /// Cap on retained snippets per session. Smaller than the file cap because
    /// each one is up to 512 bytes of foreign text and the polish context budget
    /// is the real consumer.
    public static let maxRecentSnippets = 8

    /// Whether `record` re-sends the Vibe prompt `snapshot` last submitted
    /// (#1285). Vibe hooks carry no prompt, so each one reads the newest from
    /// the session log, and a turn's first tool still reads the turn before's.
    /// The message id tells such a read from a prompt the user sent again;
    /// without one, every submit counts, as before.
    public static func isRepeatedSubmit(_ record: ClaudeHookRecord, of snapshot: ClaudeSessionSnapshot) -> Bool {
        record.event == .userPromptSubmit && record.agent == .vibe
            && record.promptID != nil && record.promptID == snapshot.lastSubmittedPromptID
    }

    /// Fold one record into a snapshot.
    ///
    /// `origin` is passed separately and is authoritative — the record has no
    /// say in it. `rawCwd` only becomes a usable path via
    /// `ClaudeWorkspaceReference.make`, which refuses for remote origins.
    ///
    /// - Parameter snippets: sanitized excerpts, supplied by the transport that
    ///   parsed them. The local NDJSON wire has no field for these, so in
    ///   practice only the remote HTTP listener ever passes a non-empty array.
    /// - Parameter environment: allowlisted env labels the REMOTE listener read
    ///   off the request headers. Applied only for a `.remote` origin — a local
    ///   caller passing one is ignored rather than trusted, so the remote-only
    ///   property of `ClaudeSessionSnapshot.remoteEnvironment` holds at the one
    ///   place that writes it.
    public static func reduce(
        _ snapshot: inout ClaudeSessionSnapshot,
        record: ClaudeHookRecord,
        origin: ClaudeTransportOrigin,
        snippets: [ClaudeContentSnippet] = [],
        environment: ClaudeRemoteSessionEnvironment? = nil,
        now: Date
    ) {
        snapshot.lastActivity = now

        if let workspace = ClaudeWorkspaceReference.make(rawCwd: record.rawCwd, origin: origin) {
            snapshot.workspace = workspace
            if case .remote = origin, let rawCwd = record.rawCwd {
                snapshot.remoteWorktreeRepository = ClaudeWorkspaceReference.claudeWorktreeRepository(rawCwd: rawCwd)
            }
        }
        // Never absorbed from a focus record (declaration or retraction): its
        // process block describes the PANE (the declarer's tty and pid), not
        // the session. Folding it in would hand the session a per-session TTY
        // claim its publisher deliberately never makes — the opencode server
        // half publishes no tty precisely because it cannot prove it owns a
        // pane — and would let a focus record overwrite the pid that liveness
        // probes.
        if let process = record.process,
           record.event != .focusChanged, record.event != .focusCleared {
            snapshot.process = process
        }
        // Remote only, and replace-whole rather than merge-per-field: the shim
        // publishes everything it can see on every event, so the newest report
        // is the honest one — a merge would keep resurrecting a pane the user
        // has since left. Skipped for focus records for the same reason the
        // process block is: they describe a pane, not the session.
        if case .remote = origin, let environment, !environment.isEmpty,
           record.event != .focusChanged, record.event != .focusCleared {
            snapshot.remoteEnvironment = environment
        }
        // Kept until a record carries another: Claude Code sends its title on
        // `SessionStart` only. The wire clamp already dropped it from focus
        // records.
        if let title = record.sessionTitle {
            snapshot.harnessTitle = title
        }

        switch record.event {
        case .sessionStart:
            snapshot.activity = .idle
        case .userPromptSubmit:
            snapshot.activity = .working
            guard !isRepeatedSubmit(record, of: snapshot) else { break }
            snapshot.lastSubmittedPromptID = record.agent == .vibe ? record.promptID : nil
            snapshot.promptsSubmitted += 1
            if let prompt = record.prompt, !prompt.isEmpty {
                snapshot.latestPriorUserPrompt = prompt
                snapshot.latestPriorUserPromptAt = now
            }
        case .cwdChanged:
            // Workspace already applied above; a cwd change does not alter the
            // turn state.
            break
        case .postToolUse, .fileChanged:
            for file in record.files {
                touch(&snapshot, file: file, now: now)
            }
            for snippet in snippets {
                attach(&snapshot, snippet: snippet)
            }
            snapshot.activity = .working
        case .stop:
            snapshot.activity = .idle
        case .notification:
            // A wait inside a turn: the turn is not over, and a permission
            // answered in the pane resumes it without another hook.
            break
        case .focusChanged, .focusCleared:
            // Focus is registry-level state (a TTY→session binding, held in
            // `ClaudeSessionRegistry`'s focus table) — a pane DISPLAYING or
            // leaving a session says nothing about whether its model is
            // working, so the per-session state here changes only by the
            // lastActivity bump applied above.
            break
        case .sessionEnd:
            snapshot.activity = .ended
        case .statusQuery:
            // Unreachable: a status probe is refused at the top of
            // `ClaudeSessionRegistry.ingest` (and answered by the broker
            // before that), so it can never be reduced into a snapshot. The
            // case exists so adding a wire event stays a compile-time
            // decision here rather than an implicit `break`.
            break
        }
    }

    /// Most-recent-first, de-duplicated by path, capped.
    ///
    /// A re-touch promotes the existing entry rather than appending a duplicate,
    /// and an edit outranks an earlier read of the same file: "I just changed
    /// X" is the more useful fact for grounding dictation.
    static func touch(_ snapshot: inout ClaudeSessionSnapshot, file: ClaudeFileTouch, now: Date) {
        var kind = file.kind
        if let existing = snapshot.recentFiles.first(where: { $0.path == file.path }) {
            if existing.kind == .edited { kind = .edited }
            snapshot.recentFiles.removeAll { $0.path == file.path }
        }
        snapshot.recentFiles.insert(
            ClaudeRecentFile(path: file.path, kind: kind, lastTouched: now),
            at: 0
        )
        if snapshot.recentFiles.count > maxRecentFiles {
            snapshot.recentFiles.removeLast(snapshot.recentFiles.count - maxRecentFiles)
        }
    }

    /// Most-recent-first, de-duplicated, capped.
    ///
    /// Dedup is on the whole snippet, not the label: the same `Edit new_string`
    /// label with different text is two different facts, while a hook that fires
    /// twice for one edit is one fact reported twice.
    package static func attach(_ snapshot: inout ClaudeSessionSnapshot, snippet: ClaudeContentSnippet) {
        guard !snippet.text.isEmpty else { return }
        snapshot.recentSnippets.removeAll { $0 == snippet }
        snapshot.recentSnippets.insert(snippet, at: 0)
        if snapshot.recentSnippets.count > maxRecentSnippets {
            snapshot.recentSnippets.removeLast(snapshot.recentSnippets.count - maxRecentSnippets)
        }
    }
}
