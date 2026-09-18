import ClaudeContextWire
import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#endif

public protocol ClaudeSessionStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func clear() throws
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

    public func save(_ data: Data) throws {
        try io.write(data, to: fileURL)
    }

    public func clear() throws {
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
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("localvoxtral", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent("claude-sessions.json")
    }
}

final class ClaudeSessionStoreWriter: @unchecked Sendable {
    enum Operation: Sendable {
        case save(Data)
        case clear
    }

    private struct State {
        var pending: Operation?
        var scheduled = false
    }

    private let store: any ClaudeSessionStore
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "app.localvoxtral.claude-session-store")

    init(store: any ClaudeSessionStore) {
        self.store = store
    }

    func submit(_ operation: Operation) {
        let shouldSchedule = state.withLock { state in
            state.pending = operation
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.async { [self] in drain() }
    }

    func flush() {
        queue.sync {}
    }

    private func drain() {
        while true {
            guard let operation = state.withLock({ state -> Operation? in
                guard let pending = state.pending else {
                    state.scheduled = false
                    return nil
                }
                state.pending = nil
                return pending
            }) else { return }

            do {
                switch operation {
                case .save(let data): try store.save(data)
                case .clear: try store.clear()
                }
            } catch {
                Log.claudeContext.error("Claude session store write failed")
            }
        }
    }
}

struct StoredClaudeSessions: Codable {
    static let currentVersion = 1

    var version: Int
    var bootIdentity: String?
    var sessions: [Session]

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case bootIdentity = "boot_identity"
        case sessions
    }

    struct Session: Codable {
        var sessionID: String
        var origin: Origin
        var agent: ClaudeHookAgent
        var workspace: String?
        var activity: String
        var process: ClaudeHookProcessInfo?
        var remoteEnvironment: RemoteEnvironment?
        var firstSeen: Date
        var lastActivity: Date

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case origin, agent, workspace, activity, process
            case remoteEnvironment = "remote_environment"
            case firstSeen = "first_seen"
            case lastActivity = "last_activity"
        }
    }

    struct Origin: Codable {
        var kind: String
        var peerUID: UInt32?
        var channel: String?

        enum CodingKeys: String, CodingKey {
            case kind
            case peerUID = "peer_uid"
            case channel
        }
    }

    struct RemoteEnvironment: Codable {
        var herdrPaneID: String?
        var herdrSocketPath: String?
        var herdrSession: String?
        var cmuxSurfaceID: String?
        var cmuxSocketPath: String?
        var bridgeSessionID: String?
        var desktopSessionID: String?
        var tmux: String?
        var tmuxPane: String?
        var screenSession: String?
        var zellijSession: String?
        var sshTTY: String?
        var localTTY: String?
        var sshConnection: String?
        var hookParentPID: String?

        init(_ value: ClaudeRemoteSessionEnvironment) {
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

        var value: ClaudeRemoteSessionEnvironment {
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
