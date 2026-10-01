import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The syscalls a durable write orders, split out so a test can record the
/// order without cutting the power (#1042).
package struct DurableFileSystem: Sendable {
    /// Flushes `descriptor`, opened on `path`, to the disk. 0 or -1 with errno.
    package var sync: @Sendable (_ descriptor: Int32, _ path: String) -> Int32
    /// `rename(2)`. 0 or -1 with errno.
    package var rename: @Sendable (_ source: String, _ destination: String) -> Int32

    package init(
        sync: @escaping @Sendable (_ descriptor: Int32, _ path: String) -> Int32,
        rename: @escaping @Sendable (_ source: String, _ destination: String) -> Int32
    ) {
        self.sync = sync
        self.rename = rename
    }

    package static let live = DurableFileSystem(
        sync: { descriptor, _ in
            #if canImport(Darwin)
            // Darwin's fsync leaves the data in the drive's cache, which may
            // write it after the rename. A barrier keeps the order, which is
            // all a replace needs: a power cut then leaves the old file or
            // the new one, never an empty one. Full syncs cost tens of ms.
            if fcntl(descriptor, F_BARRIERFSYNC) == 0 { return 0 }
            #endif
            return fsync(descriptor)
        },
        rename: { source, destination in
            #if canImport(Darwin)
            Darwin.rename(source, destination)
            #else
            Glibc.rename(source, destination)
            #endif
        }
    )
}

/// Replaces a store file so that a crash or a power cut leaves either the old
/// bytes or the new ones: a unique 0600 temporary file in the same directory
/// (`O_EXCL | O_NOFOLLOW`), synced, renamed over the target, then the
/// directory synced so the rename itself survives. Every app-owned JSON store
/// writes through here.
package enum DurableFile {
    package struct Failure: Error, CustomStringConvertible, Equatable {
        package var operation: String
        package var path: String
        package var code: Int32
        package var description: String { "\(operation) failed with errno \(code)" }
    }

    /// The temporary file's name: `.<target name>.<pid>.<random>.tmp`. The
    /// diagnostic records' launch sweep matches this shape.
    package static func temporaryName(for url: URL) -> String {
        ".\(url.lastPathComponent).\(getpid()).\(UInt64.random(in: 0..<UInt64.max)).tmp"
    }

    /// The directory must exist; callers create or validate it with their
    /// own rules first.
    package static func write(
        _ data: Data, to url: URL, fileSystem: DurableFileSystem = .live
    ) throws {
        let directory = url.deletingLastPathComponent().path
        let temporary = url.deletingLastPathComponent().appendingPathComponent(temporaryName(for: url)).path

        let descriptor = retryingOnEINTR {
            Int(open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600))
        }
        guard descriptor >= 0 else { throw Failure(operation: "open", path: temporary, code: errno) }
        let fd = Int32(descriptor)
        // Every exit but the rename removes the temporary file.
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(temporary) }
        }

        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = retryingOnEINTR { LibC.write(fd, base.advanced(by: offset), raw.count - offset) }
                guard written > 0 else { throw Failure(operation: "write", path: temporary, code: errno) }
                offset += written
            }
        }
        // Before the rename: without it the new name can reach the disk before
        // the bytes, and a power cut leaves an empty file where the store was.
        guard fileSystem.sync(fd, temporary) == 0 else {
            throw Failure(operation: "sync", path: temporary, code: errno)
        }
        guard fileSystem.rename(temporary, url.path) == 0 else {
            throw Failure(operation: "rename", path: url.path, code: errno)
        }
        renamed = true
        syncDirectory(directory, fileSystem: fileSystem)
    }

    /// After the rename: the directory entry is what records it. A failure
    /// here is logged, not thrown: the new bytes are already in place, and a
    /// caller told the write failed would redo or report a change that
    /// landed. The next write syncs the directory again.
    private static func syncDirectory(_ directory: String, fileSystem: DurableFileSystem) {
        let descriptor = retryingOnEINTR { Int(open(directory, O_RDONLY | O_DIRECTORY)) }
        guard descriptor >= 0 else {
            Log.persistence.error("durable write: could not open the directory to sync it: errno \(errno, privacy: .public)")
            return
        }
        defer { close(Int32(descriptor)) }
        if fileSystem.sync(Int32(descriptor), directory) != 0 {
            Log.persistence.error("durable write: directory sync failed: errno \(errno, privacy: .public)")
        }
    }

    private static func retryingOnEINTR(_ body: () -> Int) -> Int {
        while true {
            let result = body()
            if result == -1 && errno == EINTR { continue }
            return result
        }
    }
}
