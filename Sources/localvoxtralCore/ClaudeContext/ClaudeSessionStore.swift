import ClaudeContextWire
import Foundation
import Synchronization

#if canImport(Darwin)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#endif

public protocol ClaudeSessionStore: Sendable {
    func load() throws -> Data?
    /// Replaces the file with what `transform` makes of the bytes on disk,
    /// as the only writer among the running copies of the app; nil removes
    /// the file (#1455).
    func update(_ transform: (Data?) throws -> Data?) throws
    func clear() throws
    /// Moves a file this build refused out of the way, keeping its bytes
    /// (#1041). Called before the first save or clear after a refused load.
    func moveAside() throws
}

public struct ClaudeSessionFileStore: ClaudeSessionStore {
    private let fileURL: URL
    private let io: any ClaudeRemoteHostStoreIO

    public init(
        fileURL: URL = ClaudeSessionFileStore.defaultFileURL(),
        io: any ClaudeRemoteHostStoreIO = ClaudeRemoteHostFileStoreIO()
    ) {
        self.fileURL = fileURL
        self.io = io
    }

    public func load() throws -> Data? {
        try io.read(from: fileURL)
    }

    public func update(_ transform: (Data?) throws -> Data?) throws {
        try io.withExclusiveAccess(to: fileURL) {
            if let data = try transform(try io.read(from: fileURL)) {
                try io.write(data, to: fileURL)
            } else {
                try removeFile()
            }
        }
    }

    /// Under the lock the writes take, or not at all: a write another copy
    /// lands between the link and the removal would be deleted (#1441).
    public func moveAside() throws {
        try io.withLockedAccess(to: fileURL) { lockHeld in
            guard lockHeld else { throw StoredFile.MoveAsideFailed() }
            _ = try io.moveAside(fileURL)
        }
    }

    public func clear() throws {
        try io.withExclusiveAccess(to: fileURL) { try removeFile() }
    }

    private func removeFile() throws {
        #if canImport(Darwin)
        let result = fileURL.path.withCString { unlink($0) }
        guard result == 0 || errno == ENOENT else {
            throw ClaudeRemoteHostRegistry.StoreError.writeFailed(path: fileURL.path)
        }
        #else
        try? FileManager.default.removeItem(at: fileURL)
        #endif
    }

    public static func defaultFileURL() -> URL {
        return LocalvoxtralDataDirectory.url()
            .appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent("claude-sessions.json")
    }
}

/// Writes this copy's sessions on top of the ones another running copy of
/// the app wrote (#1455). Only the copy holding the hook sockets learns of
/// new sessions, so a second copy (a `try-pr.sh` build) that rewrote the file
/// from its own list would drop every session the other copy started since.
package final class ClaudeSessionStoreWriter: @unchecked Sendable {
    package enum Operation: Sendable {
        /// This copy's sessions. Rows another copy wrote stay in the file.
        case save(StoredClaudeSessions)
        /// Removes the file, whoever wrote its rows.
        case clear
    }

    private struct State {
        /// A clear is kept apart from the save after it: replaced by that
        /// save, it would leave the rows another copy wrote.
        var pendingClear = false
        var pendingSave: StoredClaudeSessions?
        var scheduled = false
        /// Set when the restore refused the file: nothing is saved or
        /// cleared until it has been moved aside.
        var fileRefused = false
        /// The rows this copy restored or last wrote. A row in the file with
        /// another id was written by another copy and is kept; one with these
        /// ids that this copy no longer holds was removed here, and goes.
        var ownSessionIDs: Set<String> = []
    }

    private let store: any ClaudeSessionStore
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "app.localvoxtral.claude-session-store")

    package init(store: any ClaudeSessionStore) {
        self.store = store
    }

    package func submit(_ operation: Operation) {
        let shouldSchedule = state.withLock { state in
            switch operation {
            case .save(let file): state.pendingSave = file
            case .clear:
                state.pendingClear = true
                state.pendingSave = nil
            }
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.async { [self] in drain() }
    }

    /// The restore could not use the file on disk: move it aside before any
    /// write replaces or removes it.
    package func keepRefusedFile() {
        state.withLock { $0.fileRefused = true }
    }

    /// The rows the restore read, kept or dropped: they are this copy's to
    /// write back or remove.
    package func adoptRestoredRows(_ sessionIDs: some Sequence<String>) {
        state.withLock { $0.ownSessionIDs.formUnion(sessionIDs) }
    }

    package func flush() {
        queue.sync {}
    }

    private func drain() {
        while true {
            guard let (clear, save, fileRefused, ownSessionIDs) = state.withLock({
                state -> (Bool, StoredClaudeSessions?, Bool, Set<String>)? in
                guard state.pendingClear || state.pendingSave != nil else {
                    state.scheduled = false
                    return nil
                }
                defer {
                    state.pendingClear = false
                    state.pendingSave = nil
                }
                return (state.pendingClear, state.pendingSave, state.fileRefused, state.ownSessionIDs)
            }) else { return }

            if fileRefused {
                do {
                    try store.moveAside()
                    state.withLock { $0.fileRefused = false }
                } catch {
                    Log.claudeContext.error(
                        "Claude session store could not move its refused file aside; not writing: \(String(describing: error), privacy: .public)"
                    )
                    continue
                }
            }
            do {
                var ownSessionIDs = ownSessionIDs
                if clear {
                    try store.clear()
                    ownSessionIDs = []
                    state.withLock { $0.ownSessionIDs = [] }
                }
                if let save {
                    try store.update { onDisk in
                        try Self.merging(save, onto: onDisk, ownSessionIDs: ownSessionIDs)
                    }
                    state.withLock { $0.ownSessionIDs = Set(save.sessions.map(\.sessionID)) }
                }
            } catch {
                Log.claudeContext.error(
                    "Claude session store write failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private struct FileChangedUnreadable: Error {}

    /// `file`'s rows plus the rows on disk another copy wrote. Nil when no
    /// row is left. A file that no longer reads (a newer build's, written
    /// since the restore) is never replaced: this throws instead (#989).
    private static func merging(
        _ file: StoredClaudeSessions,
        onto onDisk: Data?,
        ownSessionIDs: Set<String>
    ) throws -> Data? {
        var merged = file
        if let onDisk {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            guard let disk = try? decoder.decode(StoredClaudeSessions.self, from: onDisk),
                  disk.version == StoredClaudeSessions.currentVersion
            else { throw FileChangedUnreadable() }
            let written = Set(file.sessions.map(\.sessionID))
            // A local row is only good for the boot that wrote it, which the
            // file records once for all its rows.
            let sameBoot = disk.bootIdentity != nil && disk.bootIdentity == file.bootIdentity
            let theirs = disk.sessions.filter { row in
                !ownSessionIDs.contains(row.sessionID) && !written.contains(row.sessionID)
                    && (row.origin.kind != "local" || sameBoot)
            }
            if !theirs.isEmpty {
                Log.claudeContext.notice(
                    "Claude session store kept \(theirs.count, privacy: .public) session(s) another running copy wrote"
                )
            }
            merged.sessions = (file.sessions + theirs).sorted { $0.sessionID < $1.sessionID }
        }
        guard !merged.sessions.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(merged)
    }
}

package struct StoredClaudeSessions: Codable, Sendable {
    package static let currentVersion = 1

    package var version: Int
    package var bootIdentity: String?
    package var sessions: [Session]

    package enum CodingKeys: String, CodingKey {
        case version = "v"
        case bootIdentity = "boot_identity"
        case sessions
    }

    package struct Session: Codable, Sendable {
        package var sessionID: String
        package var origin: Origin
        package var agent: ClaudeHookAgent
        package var workspace: String?
        package var activity: String
        package var process: ClaudeHookProcessInfo?
        package var remoteEnvironment: RemoteEnvironment?
        package var worktreeRepository: String?
        package var firstSeen: Date
        package var lastActivity: Date

        package enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case origin, agent, workspace, activity, process
            case remoteEnvironment = "remote_environment"
            case worktreeRepository = "worktree_repository"
            case firstSeen = "first_seen"
            case lastActivity = "last_activity"
        }

        package init(
            sessionID: String,
            origin: Origin,
            agent: ClaudeHookAgent,
            workspace: String? = nil,
            activity: String,
            process: ClaudeHookProcessInfo? = nil,
            remoteEnvironment: RemoteEnvironment? = nil,
            worktreeRepository: String? = nil,
            firstSeen: Date,
            lastActivity: Date
        ) {
            self.sessionID = sessionID
            self.origin = origin
            self.agent = agent
            self.workspace = workspace
            self.activity = activity
            self.process = process
            self.remoteEnvironment = remoteEnvironment
            self.worktreeRepository = worktreeRepository
            self.firstSeen = firstSeen
            self.lastActivity = lastActivity
        }
    }

    package struct Origin: Codable, Sendable {
        package var kind: String
        package var peerUID: UInt32?
        package var channel: String?

        package enum CodingKeys: String, CodingKey {
            case kind
            case peerUID = "peer_uid"
            case channel
        }

        package init(kind: String, peerUID: UInt32? = nil, channel: String? = nil) {
            self.kind = kind
            self.peerUID = peerUID
            self.channel = channel
        }
    }

    package struct RemoteEnvironment: Codable, Sendable {
        package var herdrPaneID: String?
        package var herdrSocketPath: String?
        package var herdrSession: String?
        package var cmuxSurfaceID: String?
        package var cmuxSocketPath: String?
        package var bridgeSessionID: String?
        package var desktopSessionID: String?
        package var tmux: String?
        package var tmuxPane: String?
        package var screenSession: String?
        package var zellijSession: String?
        package var sshTTY: String?
        package var localTTY: String?
        package var sshConnection: String?
        package var hookParentPID: String?

        package init(_ value: ClaudeRemoteSessionEnvironment) {
            herdrPaneID = value.herdrPaneID
            herdrSocketPath = value.herdrSocketPath
            herdrSession = value.herdrSession
            cmuxSurfaceID = value.cmuxSurfaceID
            cmuxSocketPath = value.cmuxSocketPath
            bridgeSessionID = value.bridgeSessionID
            desktopSessionID = value.desktopSessionID
            tmux = value.tmux
            tmuxPane = value.tmuxPane
            screenSession = value.screenSession
            zellijSession = value.zellijSession
            sshTTY = value.sshTTY
            localTTY = value.localTTY
            sshConnection = value.sshConnection
            hookParentPID = value.hookParentPID
        }

        package var value: ClaudeRemoteSessionEnvironment {
            ClaudeRemoteSessionEnvironment(
                herdrPaneID: herdrPaneID,
                herdrSocketPath: herdrSocketPath,
                herdrSession: herdrSession,
                cmuxSurfaceID: cmuxSurfaceID,
                cmuxSocketPath: cmuxSocketPath,
                bridgeSessionID: bridgeSessionID,
                desktopSessionID: desktopSessionID,
                tmux: tmux,
                tmuxPane: tmuxPane,
                screenSession: screenSession,
                zellijSession: zellijSession,
                sshTTY: sshTTY,
                localTTY: localTTY,
                sshConnection: sshConnection,
                hookParentPID: hookParentPID
            )
        }
    }
}
