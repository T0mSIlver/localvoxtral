import ClaudeContextWire
import Foundation

/// A marker allocated by the broker to identify one Claude Code session.
///
/// The broker mints these; nothing on the wire can choose or influence one.
/// The broker replies with the marker on the socket and the publisher writes it
/// into the terminal title; reading it back out of the focused window is
/// `ClaudeMarkerReading`, which currently abstains.
public struct ClaudeSessionMarker: Sendable, Equatable, Hashable {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

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
public struct ClaudeSessionSnapshot: Sendable, Equatable {
    public var sessionID: String
    /// Assigned by the broker from peer credentials. Never from the record.
    public var origin: ClaudeTransportOrigin
    /// Which coding agent this session belongs to, fixed at first sight like
    /// `origin`. Decides per-agent channel rules — most importantly, the
    /// broker never returns a title marker to a non-Claude session, because
    /// only Claude Code has a writable title channel (opencode rewrites its
    /// own OSC titles mid-turn, like herdr does inside its panes).
    public var agent: ClaudeHookAgent
    public var marker: ClaudeSessionMarker
    /// Local path or opaque remote label — the type enforces which.
    public var workspace: ClaudeWorkspaceReference?
    /// The most recent prompt the user submitted. By the time dictation reads
    /// this, it is by construction the *prior* prompt.
    public var latestPriorUserPrompt: String?
    public var latestPriorUserPromptAt: Date?
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
    public var firstSeen: Date
    public var lastActivity: Date

    /// Only ever non-nil for a locally authenticated session. This is the
    /// accessor a repo collector uses, and the reason a remote record cannot
    /// reach the filesystem: there is no path here to hand it.
    public var localWorkspacePath: LocalWorkspacePath? {
        guard origin.isLocalAuthenticated else { return nil }
        return workspace?.localPath
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

    init(
        sessionID: String,
        origin: ClaudeTransportOrigin,
        agent: ClaudeHookAgent = .claude,
        marker: ClaudeSessionMarker,
        firstSeen: Date
    ) {
        self.sessionID = sessionID
        self.origin = origin
        self.agent = agent
        self.marker = marker
        self.workspace = nil
        self.latestPriorUserPrompt = nil
        self.latestPriorUserPromptAt = nil
        self.recentFiles = []
        self.recentSnippets = []
        self.activity = .idle
        self.process = nil
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

    /// Fold one record into a snapshot.
    ///
    /// `origin` is passed separately and is authoritative — the record has no
    /// say in it. `rawCwd` only becomes a usable path via
    /// `ClaudeWorkspaceReference.make`, which refuses for remote origins.
    ///
    /// - Parameter snippets: sanitized excerpts, supplied by the transport that
    ///   parsed them. The local NDJSON wire has no field for these, so in
    ///   practice only the remote HTTP listener ever passes a non-empty array.
    public static func reduce(
        _ snapshot: inout ClaudeSessionSnapshot,
        record: ClaudeHookRecord,
        origin: ClaudeTransportOrigin,
        snippets: [ClaudeContentSnippet] = [],
        now: Date
    ) {
        snapshot.lastActivity = now

        if let workspace = ClaudeWorkspaceReference.make(rawCwd: record.rawCwd, origin: origin) {
            snapshot.workspace = workspace
        }
        // Never absorbed from a focus record: its process block describes the
        // PANE (the declarer's tty and pid), not the session. Folding it in
        // would hand the session a per-session TTY claim its publisher
        // deliberately never makes — the opencode server half publishes no tty
        // precisely because it cannot prove it owns a pane — and would let a
        // focus record overwrite the pid that liveness probes.
        if let process = record.process, record.event != .focusChanged {
            snapshot.process = process
        }

        switch record.event {
        case .sessionStart:
            snapshot.activity = .idle
        case .userPromptSubmit:
            if let prompt = record.prompt, !prompt.isEmpty {
                snapshot.latestPriorUserPrompt = prompt
                snapshot.latestPriorUserPromptAt = now
            }
            snapshot.activity = .working
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
        case .focusChanged:
            // Focus is registry-level state (a TTY→session binding, held in
            // `ClaudeSessionRegistry`'s focus table) — a pane DISPLAYING a
            // session says nothing about whether its model is working, so the
            // per-session state here changes only by the lastActivity bump
            // applied above.
            break
        case .sessionEnd:
            snapshot.activity = .ended
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
    static func attach(_ snapshot: inout ClaudeSessionSnapshot, snippet: ClaudeContentSnippet) {
        guard !snippet.text.isEmpty else { return }
        snapshot.recentSnippets.removeAll { $0 == snippet }
        snapshot.recentSnippets.insert(snippet, at: 0)
        if snapshot.recentSnippets.count > maxRecentSnippets {
            snapshot.recentSnippets.removeLast(snapshot.recentSnippets.count - maxRecentSnippets)
        }
    }
}
