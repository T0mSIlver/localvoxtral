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
    public var marker: ClaudeSessionMarker
    /// Local path or opaque remote label — the type enforces which.
    public var workspace: ClaudeWorkspaceReference?
    /// The most recent prompt the user submitted. By the time dictation reads
    /// this, it is by construction the *prior* prompt.
    public var latestPriorUserPrompt: String?
    public var latestPriorUserPromptAt: Date?
    public var recentFiles: [ClaudeRecentFile]
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

    init(
        sessionID: String,
        origin: ClaudeTransportOrigin,
        marker: ClaudeSessionMarker,
        firstSeen: Date
    ) {
        self.sessionID = sessionID
        self.origin = origin
        self.marker = marker
        self.workspace = nil
        self.latestPriorUserPrompt = nil
        self.latestPriorUserPromptAt = nil
        self.recentFiles = []
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

    /// Fold one record into a snapshot.
    ///
    /// `origin` is passed separately and is authoritative — the record has no
    /// say in it. `rawCwd` only becomes a usable path via
    /// `ClaudeWorkspaceReference.make`, which refuses for remote origins.
    public static func reduce(
        _ snapshot: inout ClaudeSessionSnapshot,
        record: ClaudeHookRecord,
        origin: ClaudeTransportOrigin,
        now: Date
    ) {
        snapshot.lastActivity = now

        if let workspace = ClaudeWorkspaceReference.make(rawCwd: record.rawCwd, origin: origin) {
            snapshot.workspace = workspace
        }
        if let process = record.process {
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
            snapshot.activity = .working
        case .stop:
            snapshot.activity = .idle
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
}
