import Foundation
import os

/// Snapshots of the history store, taken before anything could lose rows:
/// a schema migration, a retention trim or a sweep that deletes, and once a
/// day. Each is a consistent copy made through SQLite's backup API, WAL
/// included, so it opens on its own (#985).
///
/// Rotation keeps the newest snapshot of each of the last seven days, the
/// ten newest event snapshots, every one of the last day that holds a
/// dictation, and always the newest snapshot that holds a
/// dictation: a store that lost its rows must never rotate away the copy
/// that still has them. Files it cannot parse are left alone. Delete All and
/// Don't keep delete every snapshot when the user ticks "Also delete the
/// backups" (#1574). A retention trim deletes the expired dictations from
/// every snapshot too, so a backup never keeps one past the setting (#1916).
struct DictationHistoryBackups: Sendable {
    enum Reason: String, Sendable {
        case daily
        case migration
        case delete
    }

    struct Snapshot: Equatable, Sendable {
        let url: URL
        let takenAt: Date
        let reason: Reason
        let dictations: Int
    }

    static let dailyKept = 7
    static let eventsKept = 10
    /// How recent a snapshot spares the next delete one: retention trims
    /// after every dictation, and a copy per dictation would be waste.
    static let deleteSnapshotInterval: TimeInterval = 3_600

    let directoryURL: URL
    let now: @Sendable () -> Date

    init(directoryURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directoryURL = directoryURL
        self.now = now
    }

    /// `<history folder>/backups/history`.
    static func directory(inHistoryFolder folder: URL) -> URL {
        folder.appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
    }

    /// Copies `store` and rotates. Nil when the copy failed; that is logged
    /// and never stops what asked for it.
    @discardableResult
    func snapshot(of store: URL, reason: Reason) -> Snapshot? {
        guard FileManager.default.fileExists(atPath: store.path) else { return nil }
        let takenAt = now()
        let staging = directoryURL.appendingPathComponent(".snapshot-\(UUID().uuidString).store")
        defer { Self.removeFiles(at: staging) }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try SQLiteFile(readWrite: store).backup(to: staging)
            let dictations = try SQLiteFile(readWrite: staging)
                .rowCount(of: DictationHistoryStoreFile.entityTable)
            let snapshot = Snapshot(
                url: directoryURL.appendingPathComponent(
                    Self.fileName(takenAt: takenAt, reason: reason, dictations: dictations)),
                takenAt: takenAt, reason: reason, dictations: dictations)
            try FileManager.default.moveItem(at: staging, to: snapshot.url)
            Log.persistence.info(
                "History: \(reason.rawValue, privacy: .public) snapshot of \(dictations, privacy: .public) dictation(s) at \(snapshot.url.path, privacy: .public)"
            )
            rotate()
            return snapshot
        } catch {
            Log.persistence.error(
                "History: \(reason.rawValue, privacy: .public) snapshot failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Takes a daily snapshot when no daily one was taken in the last day.
    /// Only daily ones count: rotation keeps seven of those apart from the
    /// event snapshots, which a busy retention can rotate away in days.
    func snapshotIfDue(of store: URL) {
        let dayAgo = now().addingTimeInterval(-86_400)
        guard !snapshots().contains(where: { $0.reason == .daily && $0.takenAt > dayAgo }) else { return }
        snapshot(of: store, reason: .daily)
    }

    /// Takes a snapshot before a delete unless one is recent enough.
    func snapshotBeforeDelete(of store: URL) {
        let recent = now().addingTimeInterval(-Self.deleteSnapshotInterval)
        guard !snapshots().contains(where: { $0.takenAt > recent }) else { return }
        snapshot(of: store, reason: .delete)
    }

    /// Every snapshot this type wrote, newest first.
    func snapshots() -> [Snapshot] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return names.compactMap { name in
            Self.parse(name).map {
                Snapshot(
                    url: directoryURL.appendingPathComponent(name), takenAt: $0.takenAt,
                    reason: $0.reason, dictations: $0.dictations)
            }
        }
        .sorted { $0.takenAt > $1.takenAt }
    }

    func rotate() {
        let all = snapshots()
        var kept = Set<URL>()
        if let lastGood = all.first(where: { $0.dictations > 0 }) { kept.insert(lastGood.url) }
        // Within the day's grace a snapshot may be the one copy of what a
        // trim deleted: the older ones lost it (`expireDictations`).
        let graceStart = now().addingTimeInterval(-Self.expiryGrace)
        for snapshot in all where snapshot.dictations > 0 && snapshot.takenAt >= graceStart {
            kept.insert(snapshot.url)
        }
        var days = Set<String>()
        for snapshot in all where snapshot.reason == .daily {
            let day = String(Self.stamp(snapshot.takenAt).prefix(8))
            if days.count < Self.dailyKept, days.insert(day).inserted { kept.insert(snapshot.url) }
        }
        for snapshot in all.filter({ $0.reason != .daily }).prefix(Self.eventsKept) {
            kept.insert(snapshot.url)
        }
        for snapshot in all where !kept.contains(snapshot.url) {
            do {
                try FileManager.default.removeItem(at: snapshot.url)
            } catch {
                Log.persistence.error(
                    "History: could not rotate \(snapshot.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// The column of `DictationSessionRecord.startedAt`; Core Data stores a
    /// date as seconds since 2001.
    static let startedAtColumn = "ZSTARTEDAT"

    /// How long a snapshot keeps the dictations a retention trim deleted:
    /// a day to undo a trim that went wrong (a clock off, a shorter
    /// retention chosen by mistake), then they go from the copies too.
    static let expiryGrace: TimeInterval = 86_400

    /// Deletes the dictations that started before `cutoff` from every
    /// snapshot older than `expiryGrace`, as the retention trim did from the
    /// store: retention is a privacy setting, and a copy must not outlive it
    /// by more than a day (#1916). A snapshot left holding none is deleted.
    /// One that cannot be edited is kept, and the failure logged: its
    /// date does not bound its rows' when the clock was off.
    func expireDictations(startedBefore cutoff: Date) {
        var expired = 0
        var removed = 0
        let graceStart = now().addingTimeInterval(-Self.expiryGrace)
        for snapshot in snapshots() where snapshot.dictations > 0 && snapshot.takenAt < graceStart {
            do {
                let (deleted, left) = try Self.deleteRows(in: snapshot.url, startedBefore: cutoff)
                guard deleted > 0 else { continue }
                expired += deleted
                if left == 0 {
                    Self.removeFiles(at: snapshot.url)
                    removed += 1
                } else {
                    let renamed = directoryURL.appendingPathComponent(
                        Self.fileName(takenAt: snapshot.takenAt, reason: snapshot.reason, dictations: left))
                    try FileManager.default.moveItem(at: snapshot.url, to: renamed)
                }
            } catch {
                Log.persistence.error(
                    "History: could not expire dictations in \(snapshot.url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        if expired > 0 || removed > 0 {
            Log.persistence.info(
                "History: expired \(expired, privacy: .public) dictation(s) from the snapshots; deleted \(removed, privacy: .public) snapshot(s)"
            )
        }
    }

    /// Deletes the rows that started before `cutoff` from one snapshot and
    /// closes it, the deletion folded into the file itself. A snapshot is a
    /// copy of a WAL store, so the delete lands in its `-wal` file first, and
    /// SQLite writes nothing back once the file is renamed under an open
    /// connection: the rename must come after this returns, and the
    /// snapshot leaves WAL mode so no `-wal` is left under the old name.
    private static func deleteRows(in url: URL, startedBefore cutoff: Date) throws -> (deleted: Int, left: Int) {
        let file = try SQLiteFile(readWrite: url)
        let deleted = try file.deleteRows(
            of: DictationHistoryStoreFile.entityTable, where: startedAtColumn,
            isBelow: cutoff.timeIntervalSinceReferenceDate)
        let left = try file.rowCount(of: DictationHistoryStoreFile.entityTable)
        try file.leaveWAL()
        file.close()
        // Out of WAL mode and closed, nothing uses these; macOS's SQLite
        // keeps the `-shm` after leaving WAL.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        return (deleted, left)
    }

    /// Deletes every snapshot: the user deleted all of History or chose
    /// Don't keep, and asked for the backups to go too (#1574).
    /// Files it cannot parse are left alone, as rotation leaves them.
    func removeAll() {
        let snapshots = snapshots()
        for snapshot in snapshots { Self.removeFiles(at: snapshot.url) }
        if !snapshots.isEmpty {
            Log.persistence.info("History: deleted \(snapshots.count, privacy: .public) snapshot(s)")
        }
    }

    /// Whether a snapshot still holds a dictation. A daily copy of an
    /// empty store holds nothing a user could want back.
    var holdDictations: Bool { snapshots().contains { $0.dictations > 0 } }

    // MARK: - Names

    /// `history-20260928T114325Z-migration-n652.store`.
    static func fileName(takenAt: Date, reason: Reason, dictations: Int) -> String {
        "history-\(stamp(takenAt))-\(reason.rawValue)-n\(dictations).store"
    }

    static func parse(_ name: String) -> (takenAt: Date, reason: Reason, dictations: Int)? {
        guard name.hasPrefix("history-"), name.hasSuffix(".store") else { return nil }
        let parts = name.dropFirst("history-".count).dropLast(".store".count).split(separator: "-")
        guard parts.count == 3, let takenAt = date(String(parts[0])),
              let reason = Reason(rawValue: String(parts[1])),
              parts[2].hasPrefix("n"), let dictations = Int(parts[2].dropFirst())
        else { return nil }
        return (takenAt, reason, dictations)
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }

    private static func stamp(_ date: Date) -> String { formatter().string(from: date) }
    private static func date(_ stamp: String) -> Date? { formatter().date(from: stamp) }

    private static func removeFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

/// Where the automatic sweeps put the recordings and diagnostic records they
/// would have deleted: a folder per day, emptied after 30 days. A snapshot of
/// the store cannot bring back a WAV; this can. What the user deletes
/// (Delete, Delete All, turning a setting off) is deleted for real, and
/// Delete All, Don't keep and turning a setting off also empty this of
/// what they deleted when the user ticks "Also delete the backups" (#1574).
struct DictationHistoryQuarantine: Sendable {
    static let keptDays = 30

    let directoryURL: URL
    let now: @Sendable () -> Date

    init(directoryURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directoryURL = directoryURL
        self.now = now
    }

    /// `<history folder>/quarantine`.
    static func directory(inHistoryFolder folder: URL) -> URL {
        folder.appendingPathComponent("quarantine", isDirectory: true)
    }

    /// Today's folder for `kind` (`dictation-audio`, `diagnostic-records`).
    func folder(for kind: String) -> URL {
        directoryURL.appendingPathComponent(Self.day(now()), isDirectory: true)
            .appendingPathComponent(kind, isDirectory: true)
    }

    /// Whether any day folder holds a file of `kind`.
    func holdsFiles(of kind: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return names.contains { name in
            guard name.count == 8, Int(name) != nil else { return false }
            let folder = directoryURL.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(kind, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return !files.isEmpty
        }
    }

    /// Deletes what every day folder holds of `kind`.
    func removeAll(of kind: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        for name in names where name.count == 8 && Int(name) != nil {
            let folder = directoryURL.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(kind, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            do {
                try FileManager.default.removeItem(at: folder)
                Log.persistence.info("History: emptied quarantined \(kind, privacy: .public) of \(name, privacy: .public)")
            } catch {
                Log.persistence.error(
                    "History: could not empty quarantined \(kind, privacy: .public) of \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Deletes the day folders older than `keptDays`. Names that are not a
    /// day are left alone.
    func purge() {
        let cutoff = Self.day(now().addingTimeInterval(-Double(Self.keptDays) * 86_400))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        for name in names where name.count == 8 && Int(name) != nil && name < cutoff {
            do {
                try FileManager.default.removeItem(at: directoryURL.appendingPathComponent(name))
                Log.persistence.info("History: emptied quarantine folder \(name, privacy: .public)")
            } catch {
                Log.persistence.error(
                    "History: could not empty quarantine folder \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

/// Which of the backups hold something.
struct DictationHistoryBackupsSummary: Equatable, Sendable {
    /// A History snapshot holds a dictation.
    var dictations = false
    /// The quarantine holds a recording.
    var audio = false
    /// The quarantine holds a diagnostic record.
    var diagnosticRecords = false

    var holdsAnything: Bool { dictations || audio || diagnosticRecords }
}
