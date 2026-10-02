import Foundation
import Synchronization

/// Directory operations the store needs beyond writing one file. Split out as a
/// protocol for the same reason the registry splits its own IO: the pruning
/// rules are the part worth testing, and they should be testable without a real
/// directory or a real clock.
protocol DiagnosticRecordDirectoryIO: Sendable {
    /// File names directly inside `url`, or nil when the directory is absent.
    func contents(of url: URL) throws -> [String]?
    func remove(at url: URL) throws
    func read(from url: URL) throws -> Data?
    /// The file's size in bytes, or nil when it is gone.
    func size(of url: URL) -> Int?
}

struct DiagnosticRecordFileDirectoryIO: DiagnosticRecordDirectoryIO {
    func contents(of url: URL) throws -> [String]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    func remove(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func read(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func size(of url: URL) -> Int? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
        return (size as? NSNumber)?.intValue
    }
}

/// Writes, prunes and deletes `DiagnosticRecord`s: one JSON file per polished
/// dictation, named by its History entry's id, in a folder under Application
/// Support. Nothing sends them anywhere.
///
/// A record follows its dictation the way the dictation's audio does:
/// `DictationSessionStore` deletes it with its entry (Delete, Delete All,
/// retention, History off), and `removeAll(except:)` sweeps a record whose
/// entry is gone. On top of that the store keeps its own, shorter limit
/// (`Retention`), because a record holds far more than the entry.
///
/// * **The hardened write is reused, not reimplemented.**
///   `ClaudeRemoteHostFileStoreIO` already creates the directory 0700 (refusing
///   a symlinked, foreign-owned, or group-writable one), writes the temp file
///   `O_CREAT|O_EXCL|O_NOFOLLOW` at 0600, fsyncs, and replaces by `rename(2)`.
///   These records hold repository contents and screen text; they deserve the
///   same handling as the token store.
/// * **The capture time lives in the FILE NAME**, so a retention pass is a
///   directory listing and never reads a record back off disk.
struct DiagnosticRecordStore: Sendable {
    struct Retention: Sendable, Equatable {
        /// Records kept, newest first.
        var maximumRecords: Int
        /// Records older than this are removed.
        var maximumAge: TimeInterval

        static let `default` = Retention(
            maximumRecords: 500,
            maximumAge: 14 * 24 * 60 * 60
        )
    }

    enum StoreError: Error, Equatable {
        case encodingFailed
        /// Every record was deleted after the writer decided to write.
        case deletedSinceDecision
        /// The id is not a History entry's id.
        case invalidID(String)
        /// The record exists but could not be read back or decoded.
        case unreadableRecord(path: String)
        /// A newer build wrote the record; patching it would lose its fields.
        case newerRecord(schemaVersion: Int)
    }

    /// Serializes every read-modify-write over a record file: the behavior
    /// patch runs from a detached task while a write, a prune or a delete can
    /// run from the History store's queue. Process-wide because the identity
    /// that matters is the directory. Never held across an `await`, and never
    /// re-entered: the locked paths call the private unlocked bodies. Taken
    /// only through `exclusively`, which adds the lock other copies share.
    private static let recordMutationLock = Mutex(0)

    /// Bumped by `removeAll()`, per folder. A write that started before the
    /// user turned records off must not land after the delete: the writer
    /// reads the epoch when it last checked the switch, and `write` refuses
    /// once it has moved. Only a delete-everything bumps it; the orphan sweep
    /// after every trim must not cost the record being written.
    private static let deletionEpochs = Mutex<[String: UInt64]>([:])

    private let directoryURL: URL
    private let io: ClaudeRemoteHostStoreIO
    private let directoryIO: DiagnosticRecordDirectoryIO
    private let retention: Retention
    private let now: @Sendable () -> Date

    init(
        directoryURL: URL? = nil,
        io: ClaudeRemoteHostStoreIO = ClaudeRemoteHostFileStoreIO(),
        directoryIO: DiagnosticRecordDirectoryIO = DiagnosticRecordFileDirectoryIO(),
        retention: Retention = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directoryURL = directoryURL ?? DiagnosticRecordStore.defaultDirectoryURL()
        self.io = io
        self.directoryIO = directoryIO
        self.retention = retention
        self.now = now
    }

    static func defaultDirectoryURL() -> URL {
        LocalvoxtralDataDirectory.url()
            .appendingPathComponent("diagnostic-records", isDirectory: true)
    }

    var directory: URL { directoryURL }

    // MARK: - Writing

    /// The folder's deletion epoch now. See `deletionEpochs`.
    func deletionEpoch() -> UInt64 {
        Self.deletionEpochs.withLock { $0[directoryURL.path] ?? 0 }
    }

    /// Redacts `record`, writes it, and prunes. Returns the file it wrote.
    /// With `epoch`, refuses when every record was deleted since the caller
    /// read it.
    @discardableResult
    func write(_ record: DiagnosticRecord, unlessDeletedSince epoch: UInt64? = nil) throws -> URL {
        try exclusively {
            if let epoch, epoch != deletionEpoch() { throw StoreError.deletedSinceDecision }
            return try writeLocked(record)
        }
    }

    private func writeLocked(_ record: DiagnosticRecord) throws -> URL {
        guard let id = UUID(uuidString: record.id) else { throw StoreError.invalidID(record.id) }
        var redacted = record
        let redactions = DiagnosticRecordRedaction.redact(&redacted)
        if redactions > 0 {
            // A review that finds `<redacted>` in an excerpt needs to know the
            // redactor put it there, not the pipeline. A count, never content.
            Log.backends.info(
                "Diagnostic record: redacted \(redactions, privacy: .public) secret-shaped run(s)"
            )
        }

        guard let data = try? makeEncoder().encode(redacted) else {
            throw StoreError.encodingFailed
        }

        let url = directoryURL.appendingPathComponent(
            DiagnosticRecordFileName.name(id: id, capturedAt: redacted.capturedAt),
            isDirectory: false
        )
        try io.write(data, to: url)
        pruneLocked()
        return url
    }

    // MARK: - Patching

    /// Attaches the post-commit behavior signal to an already-written record.
    ///
    /// A patch rather than a delayed write: holding the record back for up to
    /// fifteen seconds to wait for a signal would lose it to a quit, a crash or
    /// a cancelled task. A record deleted in the meantime (its dictation
    /// deleted, or the switch turned off) is not recreated.
    ///
    /// The behavior block is fixed slugs and numbers, so no re-redaction is
    /// needed.
    func attachBehavior(_ behavior: DiagnosticRecord.Behavior, toRecordAt url: URL) throws {
        try exclusively {
            guard
                let data = try directoryIO.read(from: url),
                var record = try? makeDecoder().decode(DiagnosticRecord.self, from: data)
            else {
                throw StoreError.unreadableRecord(path: url.path)
            }
            // Re-encoding a newer build's record would drop the fields this
            // build does not know (#1042).
            guard record.schemaVersion <= DiagnosticRecord.currentSchemaVersion else {
                Log.backends.error(
                    "Diagnostic record: kept a schema \(record.schemaVersion, privacy: .public) record unpatched; this build writes \(DiagnosticRecord.currentSchemaVersion, privacy: .public)"
                )
                throw StoreError.newerRecord(schemaVersion: record.schemaVersion)
            }
            record.behavior = behavior
            guard let encoded = try? makeEncoder().encode(record) else {
                throw StoreError.encodingFailed
            }
            try io.write(encoded, to: url)
        }
    }

    // MARK: - Listing, pruning, deleting

    struct Entry: Sendable, Equatable {
        var id: UUID
        var url: URL
        var capturedAt: Date
    }

    /// Every record in the directory, newest first. Files that do not parse as
    /// record names are ignored, not deleted.
    func listRecords() throws -> [Entry] {
        guard let names = try directoryIO.contents(of: directoryURL) else { return [] }
        return names.compactMap { name -> Entry? in
            guard let parsed = DiagnosticRecordFileName.parse(name) else { return nil }
            return Entry(
                id: parsed.id,
                url: directoryURL.appendingPathComponent(name, isDirectory: false),
                capturedAt: parsed.capturedAt
            )
        }
        .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// The ids that have a record.
    func storedIDs() -> Set<UUID> {
        Set(((try? listRecords()) ?? []).map(\.id))
    }

    /// How many records there are and their size on disk, for the Settings row.
    /// Throws when the folder will not list: that is not zero (#1166).
    func summary() throws -> (records: Int, bytes: Int) {
        let records = try listRecords()
        let bytes = records.reduce(0) { $0 + (directoryIO.size(of: $1.url) ?? 0) }
        return (records.count, bytes)
    }

    /// Applies the retention rules.
    func prune() {
        exclusively { pruneLocked() }
    }

    private func pruneLocked() {
        let records = (try? listRecords()) ?? []
        let cutoff = now().addingTimeInterval(-retention.maximumAge)
        let doomed = records.enumerated().filter { position, record in
            position >= retention.maximumRecords || record.capturedAt < cutoff
        }.map(\.element)
        removeLocked(doomed)
    }

    /// Deletes the records of these ids. Returns how many it deleted.
    @discardableResult
    func remove(_ ids: some Sequence<UUID>) -> Int {
        let ids = Set(ids)
        return exclusively {
            removeLocked(((try? listRecords()) ?? []).filter { ids.contains($0.id) })
        }
    }

    /// Deletes every record whose dictation is not in `kept`.
    @discardableResult
    func removeAll(except kept: Set<UUID>) -> Int {
        exclusively {
            removeLocked(((try? listRecords()) ?? []).filter { !kept.contains($0.id) })
        }
    }

    /// Moves the records of exactly these ids into `folder`, for the History
    /// sweeps, which never delete what they find outright (#985). Returns how
    /// many moved.
    @discardableResult
    func quarantine(_ ids: Set<UUID>, into folder: URL) -> Int {
        exclusively {
            var moved = 0
            for record in ((try? listRecords()) ?? []) where ids.contains(record.id) {
                do {
                    guard let data = try io.read(from: record.url) else { continue }
                    // Never over a record already there: another running copy
                    // may have quarantined the same one a moment ago.
                    var destination = folder.appendingPathComponent(record.url.lastPathComponent)
                    if try io.read(from: destination) != nil {
                        destination = folder.appendingPathComponent(
                            "\(UUID().uuidString)-\(record.url.lastPathComponent)")
                    }
                    try io.write(data, to: destination)
                    try directoryIO.remove(at: record.url)
                    moved += 1
                } catch {
                    Log.backends.error(
                        "Diagnostic record: could not move \(record.url.lastPathComponent, privacy: .public) to quarantine: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return moved
        }
    }

    /// Deletes the temporary files a write leaves when the app dies between
    /// creating one and renaming it into place (`ClaudeRemoteHostFileStoreIO`
    /// names them `.<record name>.<pid>.<random>.tmp`); they hold a whole
    /// record that no sweep would otherwise find. Launch only, on the History
    /// write queue, where no record write is in flight.
    func removeStrayFiles() {
        exclusively {
            let names = ((try? directoryIO.contents(of: directoryURL)) ?? nil) ?? []
            for name in names
            where name.hasPrefix("." + DiagnosticRecordFileName.prefix) && name.hasSuffix(".tmp") {
                do {
                    try directoryIO.remove(at: directoryURL.appendingPathComponent(name))
                } catch {
                    Log.backends.error(
                        "Diagnostic record: could not delete \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    /// Deletes every record, and whatever else is in the folder: a temporary
    /// file a write left when the app died mid-write holds a record too.
    @discardableResult
    func removeAll() -> Int {
        exclusively {
            Self.deletionEpochs.withLock { $0[directoryURL.path, default: 0] += 1 }
            let names = ((try? directoryIO.contents(of: directoryURL)) ?? nil) ?? []
            var removed = 0
            for name in names {
                do {
                    try directoryIO.remove(at: directoryURL.appendingPathComponent(name))
                    if DiagnosticRecordFileName.parse(name) != nil { removed += 1 }
                } catch {
                    Log.backends.error(
                        "Diagnostic record: could not delete \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return removed
        }
    }

    /// Runs `body` as the only mutation of the folder, in this process and
    /// among every running copy of the app that shares the data folder (#990):
    /// another copy's Delete between a patch's read and its write would
    /// otherwise be undone by the write. The shared lock sits beside the
    /// folder, not in it, because `removeAll()` empties the folder.
    private func exclusively<T: Sendable>(_ body: () throws -> T) rethrows -> T {
        try Self.recordMutationLock.withLock { _ in
            try StoredFileLock.withLock(beside: directoryURL, body)
        }
    }

    private func removeLocked(_ records: [Entry]) -> Int {
        var removed = 0
        for record in records {
            do {
                try directoryIO.remove(at: record.url)
                removed += 1
            } catch {
                // Loud: a delete that failed is why the folder keeps a record
                // the user was told is gone. The next sweep tries again.
                Log.backends.error(
                    "Diagnostic record: could not delete \(record.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return removed
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Record file naming: `dictation-<UTC stamp>-<History id>.json`. The stamp
/// lets retention run on a listing; the id joins the record to its History
/// entry and its audio.
enum DiagnosticRecordFileName {
    static let prefix = "dictation-"
    static let suffix = ".json"

    static func name(id: UUID, capturedAt: Date) -> String {
        "\(prefix)\(makeStampFormatter().string(from: capturedAt))-\(id.uuidString)\(suffix)"
    }

    static func parse(_ name: String) -> (capturedAt: Date, id: UUID)? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let body = name.dropFirst(prefix.count).dropLast(suffix.count)
        // `<stamp>-<id>`; the stamp itself contains no hyphen.
        guard let separator = body.firstIndex(of: "-") else { return nil }
        let stamp = String(body[body.startIndex..<separator])
        guard
            let capturedAt = makeStampFormatter().date(from: stamp),
            let id = UUID(uuidString: String(body[body.index(after: separator)...]))
        else { return nil }
        return (capturedAt, id)
    }

    /// Sortable, hyphen-free, fixed to UTC. A factory rather than a shared
    /// instance: `DateFormatter` is not `Sendable`.
    static func makeStampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}
