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

package final class ClaudeSessionStoreWriter: @unchecked Sendable {
    package enum Operation: Sendable {
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

    package init(store: any ClaudeSessionStore) {
        self.store = store
    }

    package func submit(_ operation: Operation) {
        let shouldSchedule = state.withLock { state in
            state.pending = operation
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.async { [self] in drain() }
    }

    package func flush() {
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

package struct StoredClaudeSessions: Codable {
    package static let currentVersion = 1

    package var version: Int
    package var bootIdentity: String?
    package var sessions: [Session]

    package enum CodingKeys: String, CodingKey {
        case version = "v"
        case bootIdentity = "boot_identity"
        case sessions
    }

    package struct Session: Codable {
        package var sessionID: String
        package var origin: Origin
        package var agent: ClaudeHookAgent
        package var workspace: String?
        package var activity: String
        package var process: ClaudeHookProcessInfo?
        package var remoteEnvironment: RemoteEnvironment?
        package var firstSeen: Date
        package var lastActivity: Date

        package enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case origin, agent, workspace, activity, process
            case remoteEnvironment = "remote_environment"
            case firstSeen = "first_seen"
            case lastActivity = "last_activity"
        }
    }

    package struct Origin: Codable {
        package var kind: String
        package var peerUID: UInt32?
        package var channel: String?

        package enum CodingKeys: String, CodingKey {
            case kind
            case peerUID = "peer_uid"
            case channel
        }
    }

    package struct RemoteEnvironment: Codable {
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
