import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Filesystem and peer-credential preconditions for the broker's socket.
///
/// The broker's whole trust model is "a connection on this socket comes from a
/// process running as me". That claim is only as good as these checks:
///
/// * the directory is ours, not a symlink, and not group/world-writable —
///   otherwise another user could swap in their own socket and feed us records
///   we would mark `.localAuthenticated`;
/// * the socket file is 0600 — otherwise any local process could connect;
/// * the peer's UID is verified BEFORE the first read — so an unauthorized
///   connection never gets to hand us bytes at all.
public enum ClaudeSocketGuard {
    public enum PreconditionFailure: Error, Equatable {
        case notADirectory(String)
        case isSymlink(String)
        case wrongOwner(path: String, owner: UInt32, expected: UInt32)
        case permissive(path: String, mode: UInt16)
        /// `code` is an NSError code when Foundation reported the failure, and
        /// a raw errno when a syscall did — never a stale errno read back after
        /// a Foundation call.
        case cannotCreate(path: String, code: Int)
    }

    /// Metadata as `lstat(2)` reports it — no symlink following, which is the
    /// entire point.
    public struct PathMetadata: Sendable, Equatable {
        public var isDirectory: Bool
        public var isSymlink: Bool
        public var isSocket: Bool
        public var ownerUID: UInt32
        /// Permission bits only (mode & 0o7777).
        public var mode: UInt16

        public init(
            isDirectory: Bool,
            isSymlink: Bool,
            isSocket: Bool = false,
            ownerUID: UInt32,
            mode: UInt16
        ) {
            self.isDirectory = isDirectory
            self.isSymlink = isSymlink
            self.isSocket = isSocket
            self.ownerUID = ownerUID
            self.mode = mode
        }
    }

    /// Pure decision function over already-collected metadata, so every branch
    /// is unit-testable without needing to actually create a hostile directory.
    public static func validateDirectory(
        _ metadata: PathMetadata,
        path: String,
        expectedUID: UInt32
    ) -> PreconditionFailure? {
        if metadata.isSymlink { return .isSymlink(path) }
        if !metadata.isDirectory { return .notADirectory(path) }
        if metadata.ownerUID != expectedUID {
            return .wrongOwner(path: path, owner: metadata.ownerUID, expected: expectedUID)
        }
        // Anything readable/writable/executable by group or other is a hole:
        // the socket inside inherits the directory's reachability.
        if metadata.mode & 0o077 != 0 {
            return .permissive(path: path, mode: metadata.mode)
        }
        return nil
    }

    #if canImport(Darwin)
    public static func metadata(ofPath path: String) -> PathMetadata? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return PathMetadata(
            isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
            isSymlink: (info.st_mode & S_IFMT) == S_IFLNK,
            isSocket: (info.st_mode & S_IFMT) == S_IFSOCK,
            ownerUID: UInt32(info.st_uid),
            mode: UInt16(info.st_mode & 0o7777)
        )
    }

    /// Create the run directory 0700 if absent, then validate it. Never
    /// "repairs" a directory that fails validation — if it is not ours or not
    /// private, that is a situation to report, not to paper over.
    public static func prepareDirectory(at path: String) throws {
        let expectedUID = UInt32(geteuid())
        if let existing = metadata(ofPath: path) {
            if let failure = validateDirectory(existing, path: path, expectedUID: expectedUID) {
                throw failure
            }
            return
        }
        // mkdir with an explicit mode; the parent chain uses the same 0700.
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            // NSError's code, not `errno`. Foundation makes any number of
            // syscalls internally and only the LAST one's errno survives, so
            // reading it here reports whatever happened after the real failure
            // — routinely 0 ("Undefined error") on a path that plainly failed.
            throw PreconditionFailure.cannotCreate(path: path, code: (error as NSError).code)
        }
        guard let created = metadata(ofPath: path) else {
            // lstat failed immediately above, so errno IS ours here.
            throw PreconditionFailure.cannotCreate(path: path, code: Int(errno))
        }
        if let failure = validateDirectory(created, path: path, expectedUID: expectedUID) {
            throw failure
        }
    }

    /// Verify the connected peer runs as us.
    ///
    /// `getpeereid` reads credentials the KERNEL attached at connect time — the
    /// peer cannot forge them, unlike anything it might send us in a message.
    /// Called before the first `read`, so an unauthorized peer never gets to
    /// speak.
    public static func peerUID(ofDescriptor fd: Int32) -> UInt32? {
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return UInt32(uid)
    }

    /// The pid of the process on the other end of a connected AF_UNIX socket,
    /// as the kernel recorded it at connect time (`LOCAL_PEERPID`,
    /// `<sys/un.h>`). Same trust class as `peerUID`: transport evidence a
    /// sender cannot forge.
    ///
    /// This exists for the opencode records' pid cross-check: that plugin runs
    /// INSIDE the agent process and connects from it directly, so its claimed
    /// pid must equal the kernel's answer. The Claude hook path can make no
    /// such promise — its publisher is a transient child of the session, so
    /// its peer pid is never the Claude pid. That asymmetry is why this check
    /// is applied per agent, not universally.
    public static func peerPID(ofDescriptor fd: Int32) -> pid_t? {
        // Spelled numerically: the Darwin overlay does not export these two
        // <sys/un.h> constants. SOL_LOCAL is 0; LOCAL_PEERPID is 0x002.
        let solLocal: Int32 = 0
        let localPeerPID: Int32 = 0x002
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, solLocal, localPeerPID, &pid, &length) == 0, pid > 0 else {
            return nil
        }
        return pid
    }
    #endif
}
