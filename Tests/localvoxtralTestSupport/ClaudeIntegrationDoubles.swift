import Foundation
import Synchronization
import localvoxtralCore

// The Claude Code integrations' doubles, shared by their unit tests and by
// ViewSnapshotTests, which renders the integration panes over them. None
// touches the home directory, the keychain or a process.

/// Records what the pane asked for, and fails on demand. No `claude` process is
/// ever spawned — which is the point: the build host HAS Claude Code installed,
/// so "reports when the CLI is missing" is untestable against the real thing.
package final class StubClaudePluginService: ClaudePluginInstalling {
    private let calls = Mutex<[String]>([])
    // Typed, not `any Error`: an existential is not Sendable, and this stub has
    // to cross into the model's @Sendable action closure.
    private let failure = Mutex<ClaudePluginInstallService.ServiceError?>(nil)

    package init(failWith error: ClaudePluginInstallService.ServiceError? = nil) {
        failure.withLock { $0 = error }
    }

    package var recordedCalls: [String] { calls.withLock { $0 } }

    private func record(_ name: String) throws {
        calls.withLock { $0.append(name) }
        if let error = failure.withLock({ $0 }) { throw error }
    }

    package func installPlugin() throws { try record("install") }
    package func updatePlugin() throws { try record("update") }
    package func updateInstalledPlugin() throws { try record("updateInstalled") }
    package func uninstallPlugin() throws { try record("uninstall") }
}

/// A listener that binds nothing.
///
/// Unit tests must not open 8473: it would conflict with the developer's own
/// running app and with any other test in the same process. This stub is what
/// makes "the port follows enrollment" assertable at all.
@MainActor
package final class StubClaudeRemoteListener: ClaudeRemoteListenerControlling {
    private let hosts: ClaudeRemoteHostRegistry
    package var isListening = false
    package var boundPort: UInt16 = 8473
    package var reconcileCount = 0
    /// Thrown on the next reconcile that would bind.
    package var bindError: (any Error)?
    /// What the real listener would have counted. Set by a test to stand in for
    /// a night of rejected connections.
    package var rejectionSnapshot = ClaudeRemoteRejectionTally.Snapshot()

    /// Shared with the forward stubs so a test can assert the ORDER of the two
    /// shutdowns, not just that both happened.
    package var journal: ShutdownJournal?

    package init(hosts: ClaudeRemoteHostRegistry) {
        self.hosts = hosts
    }

    package func reconcile() throws {
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

package final class MemoryClaudeRemoteHostStore: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<[String: Data]>([:])
    package init() {}
    package func read(from url: URL) throws -> Data? { contents.withLock { $0[url.path] } }
    package func write(_ data: Data, to url: URL) throws { contents.withLock { $0[url.path] = data } }
}

package final class StubLocalHerdrConfigFileSystem: ClaudeLocalHerdrConfigFileSystem, @unchecked Sendable {
    package var state: ClaudeLocalHerdrConfigState
    package var writes: [(data: Data, permissions: UInt16, expectedConfigPresent: Bool)] = []

    package init(state: ClaudeLocalHerdrConfigState) {
        self.state = state
    }

    package func readState() throws -> ClaudeLocalHerdrConfigState {
        state
    }

    package func createConfigDirectory(permissions: UInt16) throws {
        state.directoryExists = true
    }

    package func atomicWriteConfig(_ data: Data, permissions: UInt16, expectedConfigPresent: Bool) throws {
        writes.append((data, permissions, expectedConfigPresent))
        state.configData = data
        state.configPermissions = permissions
    }
}

@MainActor
/// Ordered record of the two shutdowns, so "forwards first, listener second"
/// is asserted as a SEQUENCE. Both happening is not the property — the whole
/// failure is a hook arriving in the window between them.
package final class ShutdownJournal: @unchecked Sendable {
    private let entries = Mutex<[String]>([])
    package init() {}
    package func note(_ entry: String) { entries.withLock { $0.append(entry) } }
    package var recorded: [String] { entries.withLock { $0 } }
}
