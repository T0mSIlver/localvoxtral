import Foundation
import localvoxtralCore

/// In-memory `~/.vibe`: the two files the service touches, and a log of what
/// it did to them.
package final class StubVibeHooksFileSystem: VibeHooksFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: VibeHooksState
    private var _operations: [String] = []

    package init(state: VibeHooksState) { _state = state }

    /// Applied to the state on the Nth `readState` call (1-based), to play an
    /// editor saving between the service's read and its write.
    package var mutateOnRead: (call: Int, change: @Sendable (inout VibeHooksState) -> Void)?
    private var reads = 0

    package var state: VibeHooksState { lock.withLock { _state } }
    package var operations: [String] { lock.withLock { _operations } }
    package var hooksText: String? { state.hooksData.map { String(decoding: $0, as: UTF8.self) } }

    package func readState() throws -> VibeHooksState {
        lock.withLock {
            reads += 1
            if let mutateOnRead, mutateOnRead.call == reads { mutateOnRead.change(&_state) }
            return _state
        }
    }

    package func createShimDirectory(permissions: UInt16) throws {
        lock.withLock {
            _operations.append("mkdir \(String(permissions, radix: 8))")
            _state.shimDirExists = true
        }
    }

    package func atomicWriteShim(_ data: Data, permissions: UInt16) throws {
        lock.withLock {
            _operations.append("write shim \(String(permissions, radix: 8))")
            _state.shimFileExists = true
            _state.shimData = data
            _state.shimPermissions = permissions
        }
    }

    package func atomicWriteHooks(_ data: Data, permissions: UInt16) throws {
        lock.withLock {
            _operations.append("write hooks \(String(permissions, radix: 8))")
            _state.hooksFileExists = true
            _state.hooksData = data
            _state.hooksPermissions = permissions
        }
    }

    package func deleteShim() throws {
        lock.withLock {
            _operations.append("delete shim")
            _state.shimFileExists = false
            _state.shimData = nil
        }
    }

    package func deleteHooks() throws {
        lock.withLock {
            _operations.append("delete hooks")
            _state.hooksFileExists = false
            _state.hooksData = nil
        }
    }
}
