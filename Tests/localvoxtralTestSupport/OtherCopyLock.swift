import Foundation
import localvoxtralCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Plays the other running copy of the app (#990): takes the
/// `StoredFileLock` beside `url` only when nobody holds it, and keeps it until
/// the returned value is released. Nil when the lock is held or its file
/// cannot be opened.
package final class OtherCopyLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    package static func tryHolding(beside url: URL) -> OtherCopyLock? {
        let path = StoredFileLock.lockURL(beside: url).path
        let descriptor = path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { return nil }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            close(descriptor)
            return nil
        }
        return OtherCopyLock(descriptor: descriptor)
    }
}
