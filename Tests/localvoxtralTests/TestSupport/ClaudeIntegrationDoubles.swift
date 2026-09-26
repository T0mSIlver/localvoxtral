import Foundation
import Synchronization
@testable import localvoxtral

// The Claude Code integrations' doubles, shared by their unit tests and by
// ViewSnapshotTests, which renders the integration panes over them. None
// touches the home directory, the keychain or a process.

/// Records what the pane asked for, and fails on demand. No `claude` process is
/// ever spawned — which is the point: the build host HAS Claude Code installed,
/// so "reports when the CLI is missing" is untestable against the real thing.
final class StubClaudePluginService: ClaudePluginInstalling {
    private let calls = Mutex<[String]>([])
    // Typed, not `any Error`: an existential is not Sendable, and this stub has
    // to cross into the model's @Sendable action closure.
    private let failure = Mutex<ClaudePluginInstallService.ServiceError?>(nil)

    init(failWith error: ClaudePluginInstallService.ServiceError? = nil) {
        failure.withLock { $0 = error }
    }

    var recordedCalls: [String] { calls.withLock { $0 } }

    private func record(_ name: String) throws {
        calls.withLock { $0.append(name) }
        if let error = failure.withLock({ $0 }) { throw error }
    }

    func installPlugin() throws { try record("install") }
    func updatePlugin() throws { try record("update") }
    func updateInstalledPlugin() throws { try record("updateInstalled") }
    func uninstallPlugin() throws { try record("uninstall") }
}

/// A listener that binds nothing.
///
/// Unit tests must not open 8473: it would conflict with the developer's own
/// running app and with any other test in the same process. This stub is what
/// makes "the port follows enrollment" assertable at all.
@MainActor
final class StubClaudeRemoteListener: ClaudeRemoteListenerControlling {
    private let hosts: ClaudeRemoteHostRegistry
    var isListening = false
    var boundPort: UInt16 = 8473
    var reconcileCount = 0
    /// Thrown on the next reconcile that would bind.
    var bindError: (any Error)?
    /// What the real listener would have counted. Set by a test to stand in for
    /// a night of rejected connections.
    var rejectionSnapshot = ClaudeRemoteRejectionTally.Snapshot()

    /// Shared with the forward stubs so a test can assert the ORDER of the two
    /// shutdowns, not just that both happened.
    var journal: ShutdownJournal?

    init(hosts: ClaudeRemoteHostRegistry) {
        self.hosts = hosts
    }

    func reconcile() throws {
        reconcileCount += 1
        if isListening, !hosts.hasActiveHosts { journal?.note("listener.stop") }
        if hosts.hasActiveHosts {
            guard !isListening else { return }
            if let bindError { throw bindError }
            isListening = true
        } else {
            isListening = false
        }
    }
}

final class MemoryClaudeRemoteHostStore: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<[String: Data]>([:])
    func read(from url: URL) throws -> Data? { contents.withLock { $0[url.path] } }
    func write(_ data: Data, to url: URL) throws { contents.withLock { $0[url.path] = data } }
}

final class StubLocalHerdrConfigFileSystem: ClaudeLocalHerdrConfigFileSystem, @unchecked Sendable {
    var state: ClaudeLocalHerdrConfigState
    var writes: [(data: Data, permissions: UInt16, expectedConfigPresent: Bool)] = []

    init(state: ClaudeLocalHerdrConfigState) {
        self.state = state
    }

    func readState() throws -> ClaudeLocalHerdrConfigState {
        state
    }

    func createConfigDirectory(permissions: UInt16) throws {
        state.directoryExists = true
    }

    func atomicWriteConfig(_ data: Data, permissions: UInt16, expectedConfigPresent: Bool) throws {
        writes.append((data, permissions, expectedConfigPresent))
        state.configData = data
        state.configPermissions = permissions
    }
}

/// Fixture-driven test double for the opencode file system.
final class StubOpencodeFileSystem: OpencodePluginFileSystem, @unchecked Sendable {
    var state: OpencodePluginState
    var writtenPlugin: (data: Data, permissions: UInt16)?
    var writtenTUI: (data: Data, permissions: UInt16)?
    var createdPluginsDir = false
    var createdConfigDir = false
    var deletedPlugin = false
    var deletedTUI = false

    init(state: OpencodePluginState) { self.state = state }

    func readState() throws -> OpencodePluginState { state }
    func createPluginsDirectory(permissions: UInt16) throws { createdPluginsDir = true }
    func createConfigDirectory(permissions: UInt16) throws { createdConfigDir = true }
    func atomicWritePlugin(_ data: Data, permissions: UInt16) throws {
        writtenPlugin = (data, permissions)
    }
    func atomicWriteTUI(_ data: Data, permissions: UInt16) throws {
        writtenTUI = (data, permissions)
    }
    func deletePlugin() throws { deletedPlugin = true }
    func deleteTUI() throws { deletedTUI = true }
}

/// In-memory `~/.vibe`: the two files the service touches, and a log of what
/// it did to them.
final class StubVibeHooksFileSystem: VibeHooksFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: VibeHooksState
    private var _operations: [String] = []

    init(state: VibeHooksState) { _state = state }

    /// Applied to the state on the Nth `readState` call (1-based), to play an
    /// editor saving between the service's read and its write.
    var mutateOnRead: (call: Int, change: @Sendable (inout VibeHooksState) -> Void)?
    private var reads = 0

    var state: VibeHooksState { lock.withLock { _state } }
    var operations: [String] { lock.withLock { _operations } }
    var hooksText: String? { state.hooksData.map { String(decoding: $0, as: UTF8.self) } }

    func readState() throws -> VibeHooksState {
        lock.withLock {
            reads += 1
            if let mutateOnRead, mutateOnRead.call == reads { mutateOnRead.change(&_state) }
            return _state
        }
    }

    func createShimDirectory(permissions: UInt16) throws {
        lock.withLock {
            _operations.append("mkdir \(String(permissions, radix: 8))")
            _state.shimDirExists = true
        }
    }

    func atomicWriteShim(_ data: Data, permissions: UInt16) throws {
        lock.withLock {
            _operations.append("write shim \(String(permissions, radix: 8))")
            _state.shimFileExists = true
            _state.shimData = data
            _state.shimPermissions = permissions
        }
    }

    func atomicWriteHooks(_ data: Data, permissions: UInt16) throws {
        lock.withLock {
            _operations.append("write hooks \(String(permissions, radix: 8))")
            _state.hooksFileExists = true
            _state.hooksData = data
            _state.hooksPermissions = permissions
        }
    }

    func deleteShim() throws {
        lock.withLock {
            _operations.append("delete shim")
            _state.shimFileExists = false
            _state.shimData = nil
        }
    }

    func deleteHooks() throws {
        lock.withLock {
            _operations.append("delete hooks")
            _state.hooksFileExists = false
            _state.hooksData = nil
        }
    }
}

/// Fixture-driven test double for the statusline file system.
final class StubStatuslineFileSystem: ClaudeStatuslineFileSystem, @unchecked Sendable {
    var state: ClaudeStatuslineState
    var written: (data: Data, permissions: UInt16)?
    var createdDirectory = false
    var deleted = false

    init(state: ClaudeStatuslineState) { self.state = state }

    func readState() throws -> ClaudeStatuslineState { state }
    func createDirectory(permissions: UInt16) throws { createdDirectory = true }
    func atomicWrite(_ data: Data, permissions: UInt16) throws {
        written = (data, permissions)
    }
    func deleteFile() throws { deleted = true }
}
