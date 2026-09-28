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
