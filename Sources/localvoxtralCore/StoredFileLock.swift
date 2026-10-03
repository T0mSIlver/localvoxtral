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

    /// Waits for the lock and keeps it until the returned value is
    /// released; nil when the lock file cannot be opened. For a step that
    /// must not run unlocked, such as Start Over deleting a file once it is
    /// linked aside.
    package static func holding(beside url: URL) -> StoredFileLock? {
        acquire(beside: url, blocking: true)
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

/// The identity of the file at a path: which inode, how big, when its data
/// and its metadata last changed. The stores replace their files with
/// `rename(2)`, so another copy's write changes the inode even when size and
/// times collide; an append changes the size (#1046, #1126).
public struct StoredFileStamp: Sendable, Equatable {
    package let device: UInt64
    package let inode: UInt64
    package let size: Int64
    package let modified: [Int64]
    package let changed: [Int64]

    package init(device: UInt64, inode: UInt64, size: Int64, modified: [Int64], changed: [Int64]) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modified = modified
        self.changed = changed
    }

    /// One `lstat` of `url`. Nil when nothing is there or it cannot be read.
    package static func of(_ url: URL) -> StoredFileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
        #else
        let modified = info.st_mtim
        let changed = info.st_ctim
        #endif
        return StoredFileStamp(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modified: [Int64(modified.tv_sec), Int64(modified.tv_nsec)],
            changed: [Int64(changed.tv_sec), Int64(changed.tv_nsec)]
        )
    }
}

/// A store's file as this copy last read or wrote it (#990): its bytes, and
/// its stamp then, which tells a view whether to read it again (#1126).
package struct StoredFileSeen: Equatable {
    package var bytes: Data?
    package var stamp: StoredFileStamp?

    package init(bytes: Data? = nil, stamp: StoredFileStamp? = nil) {
        self.bytes = bytes
        self.stamp = stamp
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
    /// Applied, but the write failed. The value stays in memory, the change
    /// joins `unsaved`, and the next update writes it.
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
    /// under their shared lock and returns what it read, which the store
    /// hands back to `update` and `reloadIfChanged` as `seen`.
    package static func loadShared<Value>(
        _ url: URL,
        decode: (Data) -> StoredFileLoad<Value>
    ) -> (load: StoredFileLoad<Value>, seen: StoredFileSeen) {
        StoredFileLock.withLock(beside: url) {
            let stamp = StoredFileStamp.of(url)
            switch read(url) {
            case .absent: return (.absent, StoredFileSeen(stamp: stamp))
            case .unreadable: return (.refused(.unreadable), StoredFileSeen())
            case .bytes(let data): return (decode(data), StoredFileSeen(bytes: data, stamp: stamp))
            }
        }
    }

    /// Reads the file again when another running copy wrote it since this
    /// copy last read or wrote it (#1126), for a view about to show it. When
    /// its stamp is unchanged this costs one `lstat` and returns nil; nil
    /// also when the bytes are the ones `seen` holds. `.absent` means another
    /// copy removed it, and the store keeps what it holds: its next write
    /// writes the file again, as `update` does.
    package static func reloadIfChanged<Value>(
        _ url: URL,
        seen: inout StoredFileSeen,
        decode: (Data) -> StoredFileLoad<Value>
    ) -> StoredFileLoad<Value>? {
        guard StoredFileStamp.of(url) != seen.stamp else { return nil }
        return StoredFileLock.withLock(beside: url) {
            let stamp = StoredFileStamp.of(url)
            switch read(url) {
            case .absent:
                seen.stamp = stamp
                return seen.bytes == nil ? nil : .absent
            case .unreadable:
                return .refused(.unreadable)
            case .bytes(let data):
                seen.stamp = stamp
                guard data != seen.bytes else { return nil }
                let load = decode(data)
                if load.value != nil { seen.bytes = data }
                return load
            }
        }
    }

    /// One change to a store's file, as a transaction with every other
    /// running copy (#990). Under the shared lock it reads the file. When the
    /// bytes are not the ones this copy last read or wrote (`seen`),
    /// another copy wrote it, and `change` applies to what is on disk instead
    /// of to `memory`, so the other copy's change survives this one. Stores
    /// hand over the change itself, never a copy of their whole state, for
    /// this reason.
    ///
    /// A file another copy removed is written again from `memory`: this copy
    /// cannot tell a Start Over from a lost file, and writing keeps the data.
    ///
    /// `unsaved` holds the changes in `memory` that no write has landed yet.
    /// A failed write appends `change` to it, and a landed one empties it.
    /// When another copy wrote the file, they apply again to what is on disk
    /// before `change`, so a failed change is not dropped with `memory`
    /// (#1260). A change can therefore run more than once: it must do
    /// nothing but change the value.
    package static func update<Value>(
        _ url: URL,
        memory: Value,
        seen: inout StoredFileSeen,
        unsaved: inout [(inout Value) -> Void],
        decode: (Data) -> StoredFileLoad<Value>,
        encode: (Value) throws -> Data,
        write: (Data, URL) throws -> Void,
        change: @escaping (inout Value) -> Void
    ) -> StoredFileUpdate<Value> {
        StoredFileLock.withLock(beside: url) {
            updateHoldingTheLock(
                url, memory: memory, seen: &seen, unsaved: &unsaved, decode: decode, encode: encode,
                write: write, change: change)
        }
    }

    /// `update`, for a caller that already holds `url`'s lock: a store that
    /// keeps one file's lock across a change to another (#1006).
    package static func updateHoldingTheLock<Value>(
        _ url: URL,
        memory: Value,
        seen: inout StoredFileSeen,
        unsaved: inout [(inout Value) -> Void],
        decode: (Data) -> StoredFileLoad<Value>,
        encode: (Value) throws -> Data,
        write: (Data, URL) throws -> Void,
        change: @escaping (inout Value) -> Void
    ) -> StoredFileUpdate<Value> {
        var value = memory
        let stamp = StoredFileStamp.of(url)
        switch read(url) {
        case .unreadable:
            return .refused(.unreadable)
        case .absent:
            if seen.bytes != nil {
                Log.persistence.notice(
                    "\(url.lastPathComponent, privacy: .public): gone since this copy last wrote it, written again"
                )
            }
        case .bytes(let data) where data != seen.bytes:
            switch decode(data) {
            case .loaded(let onDisk):
                Log.persistence.notice(
                    "\(url.lastPathComponent, privacy: .public): another running copy wrote it, this change applies on top"
                )
                value = onDisk
                for pending in unsaved { pending(&value) }
                // Memory now holds these bytes plus the changes: should the
                // write fail, the next update applies to memory, not to
                // these bytes again, and keeps the changes.
                seen = StoredFileSeen(bytes: data, stamp: stamp)
            case .refused(let problem):
                return .refused(problem)
            case .absent:
                return .refused(.unreadable)
            }
        case .bytes:
            seen.stamp = stamp
        }
        change(&value)
        do {
            let data = try encode(value)
            try write(data, url)
            seen = StoredFileSeen(bytes: data, stamp: StoredFileStamp.of(url))
            unsaved = []
            return .written(value)
        } catch {
            unsaved.append(change)
            return .failed(value, error)
        }
    }
}
