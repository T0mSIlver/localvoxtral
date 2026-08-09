import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#endif

/// The identity of one spawned forward `ssh`, precise enough to kill by.
///
/// A pid alone is not an identity — the kernel reuses them, and a reaper that
/// killed by pid could shoot whatever innocent process inherited the number
/// after a reboot. Pid PLUS kernel start time is unique for the machine's
/// uptime, and the executable path is belt-and-braces on top: all three must
/// match what was recorded at spawn, or the record is stale and the process is
/// not ours to touch.
public struct ClaudeRemoteForwardPidRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
    public var executablePath: String
    /// The pgid to signal for a child deliberately spawned as its own process
    /// group leader. Nil for Foundation-spawned forwards and legacy records.
    /// This is teardown metadata, not part of process identity.
    public var processGroupID: Int32?

    public init(
        pid: Int32,
        startSeconds: UInt64,
        startMicroseconds: UInt64,
        executablePath: String,
        processGroupID: Int32? = nil
    ) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.executablePath = executablePath
        self.processGroupID = processGroupID
    }

    /// Group ownership does not come from `proc_pidinfo`, so compare only the
    /// kernel identity fields when re-validating a ledger record.
    func matchesProcessIdentity(_ current: ClaudeRemoteForwardPidRecord?) -> Bool {
        guard let current else { return false }
        return pid == current.pid
            && startSeconds == current.startSeconds
            && startMicroseconds == current.startMicroseconds
            && executablePath == current.executablePath
    }
}

/// Reads a live process's identity from the kernel.
public enum ClaudeRemoteForwardProcessIdentity {
    /// Nil when the pid is gone (or was never valid) — which for the reaper is
    /// an answer, not an error: a dead process needs no reaping.
    public static func snapshot(pid: pid_t) -> ClaudeRemoteForwardPidRecord? {
        #if canImport(Darwin)
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // Resolved executable (`proc_pidpath`), not argv[0] and not `p_comm` —
        // the same rule SSHDestinationTTYProbe follows, for the same reason:
        // argv is written by whoever launched the process.
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return ClaudeRemoteForwardPidRecord(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            executablePath: String(decoding: pathBytes, as: UTF8.self)
        )
        #else
        return nil
        #endif
    }
}

/// Which forward `ssh` children this app has spawned, persisted across a death
/// the app does not get to see coming.
///
/// Why this exists: `applicationWillTerminate` kills the app-held hook `-R`
/// and herdr `-L` forwards on a CLEAN quit, but a crash, force-quit, or teardown
/// that outruns the quit drain leaves ssh reparented to launchd. The `-R` can
/// keep the remote port bound; the `-L` can keep its local socket and any
/// ProxyJump descendants alive. The ledger makes either orphan findable so
/// `ClaudeRemoteForwardOrphanReaper` can verify and kill it before new
/// forwards start.
///
/// One record per lifecycle key: the hook `-R` uses the host id and the herdr
/// `-L` uses a purpose-scoped key for that host. Each purpose has at most one
/// live forward, and a respawn simply overwrites. Records are removed by the reaper (dead or
/// killed), never on process exit: a stale record for a dead pid costs one
/// identity check at the next launch and nothing else. Records deliberately
/// carry no remote port: an orphan holds whatever port it was spawned with,
/// so a per-install port change between launches must not exempt the old
/// orphan from reaping.
///
/// Storage piggybacks on `ClaudeRemoteHostStoreIO` (atomic 0600 writes, same
/// hardening) in a file beside the host registry. Unlike the registry, a
/// corrupt or unreadable ledger is treated as EMPTY: it is a cleanup aid, and
/// the safe reading of "cannot tell what we spawned" is "kill nothing".
public final class ClaudeRemoteForwardPidLedger: Sendable {
    private struct Contents: Codable {
        var version: Int
        var records: [String: ClaudeRemoteForwardPidRecord]
    }

    private static let version = 1

    private let fileURL: URL
    private let io: any ClaudeRemoteHostStoreIO
    /// One lock around read-modify-write, so two supervisors remembering at
    /// once cannot interleave and drop each other's record.
    private let lock = Mutex<Void>(())

    public init(
        fileURL: URL = ClaudeRemoteForwardPidLedger.defaultFileURL(),
        io: any ClaudeRemoteHostStoreIO = ClaudeRemoteHostFileStoreIO()
    ) {
        self.fileURL = fileURL
        self.io = io
    }

    /// Beside `claude-remote-hosts.json`, deliberately — same directory, same
    /// survival across a preferences reset.
    public static func defaultFileURL() -> URL {
        ClaudeRemoteHostRegistry.defaultFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("claude-remote-forward-pids.json")
    }

    public func records() -> [String: ClaudeRemoteForwardPidRecord] {
        lock.withLock { _ in load() }
    }

    public func remember(hostID: String, record: ClaudeRemoteForwardPidRecord) {
        lock.withLock { _ in
            var records = load()
            records[hostID] = record
            store(records)
        }
    }

    /// Pid-scoped on purpose: a forget racing a fresh spawn for the same host
    /// must not erase the NEW process's record.
    public func forget(hostID: String, pid: Int32) {
        lock.withLock { _ in
            var records = load()
            guard records[hostID]?.pid == pid else { return }
            records[hostID] = nil
            store(records)
        }
    }

    private func load() -> [String: ClaudeRemoteForwardPidRecord] {
        let data: Data?
        do {
            data = try io.read(from: fileURL)
        } catch {
            // Loud, then empty: an unreadable ledger means any orphan from a
            // previous run stays for the user to close by hand, which the
            // "Port held" state already tells them how to do.
            Log.claudeContext.error(
                "Claude remote forward pid ledger unreadable: \(String(describing: error), privacy: .public)"
            )
            return [:]
        }
        guard let data else { return [:] }
        guard let contents = try? JSONDecoder().decode(Contents.self, from: data),
              contents.version == Self.version
        else {
            Log.claudeContext.error(
                "Claude remote forward pid ledger corrupt; skipping orphan cleanup this launch"
            )
            return [:]
        }
        return contents.records
    }

    private func store(_ records: [String: ClaudeRemoteForwardPidRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(Contents(version: Self.version, records: records))
            try io.write(data, to: fileURL)
        } catch {
            Log.claudeContext.error(
                "Claude remote forward pid ledger write failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
