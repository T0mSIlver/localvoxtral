import Foundation
import Synchronization
import localvoxtralCore

/// An `~/.ssh/config` in memory that records every directory creation and
/// write the enrollment service makes.
package final class MemorySSHConfigFileSystem: ClaudeRemoteSSHConfigFileSystem {
    package struct Storage: Sendable {
        package var state: ClaudeRemoteSSHConfigState
        package var createdDirectoryPermissions: [UInt16] = []
        package var writes: [(data: Data, permissions: UInt16)] = []
    }

    private let storage: Mutex<Storage>

    package init(state: ClaudeRemoteSSHConfigState) {
        storage = Mutex(Storage(state: state))
    }

    package var snapshot: Storage { storage.withLock { $0 } }

    package func readState() throws -> ClaudeRemoteSSHConfigState {
        storage.withLock { $0.state }
    }

    package func createSSHDirectory(permissions: UInt16) throws {
        storage.withLock {
            $0.createdDirectoryPermissions.append(permissions)
            $0.state.directoryExists = true
        }
    }

    package func atomicWriteConfig(_ data: Data, permissions: UInt16) throws {
        storage.withLock {
            $0.writes.append((data, permissions))
            $0.state.configData = data
            $0.state.configPermissions = permissions
        }
    }
}
