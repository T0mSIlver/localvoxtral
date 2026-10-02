import Foundation
import Synchronization
import localvoxtralCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The live `DurableFileSystem` syscalls, recorded in order, so a test checks
/// that a write syncs before it renames without cutting the power (#1042).
package final class RecordingDurableFileSystem: Sendable {
    package enum Call: Equatable, Sendable {
        case sync(String)
        case rename(String, String)
    }

    private let calls = Mutex<[Call]>([])
    private let failTemporarySync: Bool

    /// `failTemporarySync` fails the sync of the temporary file with EIO.
    package init(failTemporarySync: Bool = false) {
        self.failTemporarySync = failTemporarySync
    }

    package var recorded: [Call] { calls.withLock { $0 } }

    package var fileSystem: DurableFileSystem {
        DurableFileSystem(
            sync: { [self] descriptor, path in
                calls.withLock { $0.append(.sync(path)) }
                if failTemporarySync, path.hasSuffix(".tmp") {
                    errno = EIO
                    return -1
                }
                return DurableFileSystem.live.sync(descriptor, path)
            },
            rename: { [self] source, destination in
                calls.withLock { $0.append(.rename(source, destination)) }
                return DurableFileSystem.live.rename(source, destination)
            })
    }
}
