import Foundation
import os

/// Snapshots of the history store, taken before anything could lose rows:
/// a schema migration, a retention trim or a sweep that deletes, and once a
/// day. Each is a consistent copy made through SQLite's backup API, WAL
/// included, so it opens on its own (#985).
///
/// Rotation keeps the newest snapshot of each of the last seven days, the
/// ten newest event snapshots, and always the newest snapshot that holds a
/// dictation: a store that lost its rows must never rotate away the copy
/// that still has them. Files it cannot parse are left alone.
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
/// (Delete, Delete All, turning a setting off) is deleted for real.
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
