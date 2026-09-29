import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An advisory lock every running copy of the app shares (#990): `flock(2)`
/// on `.<name>.lock` beside the file it guards. A try-pr build or a launch
/// smoke may run beside the installed app, and both write the same files
/// under Application Support.
///
/// The lock is its own file because the stores replace theirs with
/// `rename(2)`, and a lock on the old inode would guard nothing. The kernel
/// drops it when the holder exits, so a crash never leaves one behind. Two
/// holders in one process also exclude each other (each opens its own
/// descriptor), so it is never taken while already held on the same thread.
package final class StoredFileLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        // Closing the descriptor releases the lock.
        close(descriptor)
    }

    package static func lockURL(beside url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).lock")
    }

    /// Runs `body` holding the lock, waiting for another copy that holds it.
    /// The holders are short read-merge-write sections, never an I/O wait on
    /// anything else. A lock file that cannot be opened is logged and `body`
    /// runs unlocked: the store's re-read still narrows the race, and
    /// refusing every write would lose more.
    package static func withLock<T>(beside url: URL, _ body: () throws -> T) rethrows -> T {
        guard let lock = acquire(beside: url, blocking: true) else {
            Log.persistence.error(
                "\(url.lastPathComponent, privacy: .public): could not take the lock shared with other running copies, writing without it"
            )
            return try body()
        }
        defer { withExtendedLifetime(lock) {} }
        return try body()
    }

    /// Takes the lock only when no one holds it, and keeps it until the
    /// returned value is released. For a job exactly one running copy does,
    /// such as scanning the voice memo folder.
    package static func tryHolding(beside url: URL) -> StoredFileLock? {
        acquire(beside: url, blocking: false)
    }

    private static func acquire(beside url: URL, blocking: Bool) -> StoredFileLock? {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let path = lockURL(beside: url).path
        let descriptor = path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { return nil }
        while true {
            if flock(descriptor, LOCK_EX | (blocking ? 0 : LOCK_NB)) == 0 {
                return StoredFileLock(descriptor: descriptor)
            }
            if errno == EINTR { continue }
            close(descriptor)
            return nil
        }
    }
}

/// What reading a store's file found, before decoding.
package enum StoredFileBytes: Equatable {
    case absent
    case bytes(Data)
    case unreadable
}

/// The outcome of `StoredFile.update`.
package enum StoredFileUpdate<Value> {
    /// On disk now.
    case written(Value)
    /// The file changed under this copy into one it cannot read or one a
    /// newer build wrote. The change was not applied and nothing was written.
    case refused(StoredFileProblem)
    /// Applied, but the write failed. The value stays in memory, and the next
    /// update writes it.
    case failed(Value, any Error)
}

extension StoredFile {
    package static func read(_ url: URL) -> StoredFileBytes {
        do {
            return .bytes(try Data(contentsOf: url))
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) { return .absent }
            Log.persistence.error(
                "\(url.lastPathComponent, privacy: .public): could not be read: \(error.localizedDescription, privacy: .public)"
            )
            return .unreadable
        }
    }

    /// Loads a file that other running copies may write (#990): reads it
    /// under their shared lock and returns the bytes, which the store hands
    /// back to `update` as `lastSeen`.
    package static func loadShared<Value>(
        _ url: URL,
        decode: (Data) -> StoredFileLoad<Value>
    ) -> (load: StoredFileLoad<Value>, lastSeen: Data?) {
        StoredFileLock.withLock(beside: url) {
            switch read(url) {
            case .absent: return (.absent, nil)
            case .unreadable: return (.refused(.unreadable), nil)
            case .bytes(let data): return (decode(data), data)
            }
        }
    }

    /// One change to a store's file, as a transaction with every other
    /// running copy (#990). Under the shared lock it reads the file. When the
    /// bytes are not the ones this copy last read or wrote (`lastSeen`),
    /// another copy wrote it, and `change` applies to what is on disk instead
    /// of to `memory`, so the other copy's change survives this one. Stores
    /// hand over the change itself, never a copy of their whole state, for
    /// this reason.
    ///
    /// A file another copy removed is written again from `memory`: this copy
    /// cannot tell a Start Over from a lost file, and writing keeps the data.
    package static func update<Value>(
        _ url: URL,
        memory: Value,
        lastSeen: inout Data?,
        decode: (Data) -> StoredFileLoad<Value>,
        encode: (Value) throws -> Data,
        write: (Data, URL) throws -> Void,
        change: (inout Value) -> Void
    ) -> StoredFileUpdate<Value> {
        StoredFileLock.withLock(beside: url) {
            var value = memory
            switch read(url) {
            case .unreadable:
                return .refused(.unreadable)
            case .absent:
                if lastSeen != nil {
                    Log.persistence.notice(
                        "\(url.lastPathComponent, privacy: .public): gone since this copy last wrote it, written again"
                    )
                }
            case .bytes(let data) where data != lastSeen:
                switch decode(data) {
                case .loaded(let onDisk):
                    Log.persistence.notice(
                        "\(url.lastPathComponent, privacy: .public): another running copy wrote it, this change applies on top"
                    )
                    value = onDisk
                case .refused(let problem):
                    return .refused(problem)
                case .absent:
                    return .refused(.unreadable)
                }
            case .bytes:
                break
            }
            change(&value)
            do {
                let data = try encode(value)
                try write(data, url)
                lastSeen = data
                return .written(value)
            } catch {
                return .failed(value, error)
            }
        }
    }
}
