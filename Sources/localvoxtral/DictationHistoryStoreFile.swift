import Foundation
import os
import SQLite3
import SwiftData

/// Why the history store was not opened.
enum DictationHistoryOpenFailure: Error, Equatable, Sendable {
    /// The file holds tables or `DictationSessionRecord` columns this build's
    /// model does not have: a newer build wrote it, or another program did.
    /// Opening it would migrate the file to this model, and Core Data's
    /// inferred migration drops whatever the model lacks (#985).
    case unknownContents(tables: [String], columns: [String])
    /// A Core Data file without our table. SwiftData creates the table with
    /// the file, so a file that lacks it lost it: to another program's model,
    /// as `default.store` did to icloudmailagent's (#985).
    case missingHistoryTable
    /// SQLite or SwiftData could not open the file.
    case unreadable(String)

    var logDescription: String {
        switch self {
        case let .unknownContents(tables, columns):
            return "it holds data this build does not know (tables: \(tables), columns: \(columns)); "
                + "a newer localvoxtral or another program wrote it, and opening it would drop that data"
        case .missingHistoryTable:
            return "it is a Core Data store without the dictation table; something else's model replaced ours"
        case let .unreadable(reason):
            return reason
        }
    }
}

/// Where the history store lives, and the checks run on the file before
/// SwiftData may touch it.
///
/// Until #985 the store was SwiftData's default `default.store`, directly in
/// Application Support. Every non-sandboxed process that names no URL opens
/// that same file, Apple's `icloudmailagent` included: it migrated the file to
/// its own model, which dropped every dictation. The store now has a name and
/// a folder of its own.
enum DictationHistoryStoreFile {
    static let fileName = "history.store"
    /// The one entity table this build's model has.
    static let entityTable = "ZDICTATIONSESSIONRECORD"

    /// The app's data folder (`LocalvoxtralDataDirectory`).
    static func defaultDirectoryURL() -> URL {
        LocalvoxtralDataDirectory.url()
    }

    /// SwiftData's default store, where builds before #985 kept the history.
    /// Nil under `LOCALVOXTRAL_DATA_HOME`: a lane with a data folder of its
    /// own must not copy the owner's history into it.
    static func legacyStoreURL() -> URL? {
        guard !LocalvoxtralDataDirectory.isOverridden() else { return nil }
        return applicationSupportURL().appendingPathComponent("default.store")
    }

    private static func applicationSupportURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    enum LegacyImport: Equatable {
        /// The store already exists: the import ran before, or the user
        /// never had a legacy store.
        case storeExists
        case noLegacyStore
        /// The legacy file has no dictation table, or an empty one: another
        /// program's model replaced ours (icloudmailagent's did), or our
        /// migration back recreated it empty. Nothing is copied, and the file
        /// stays for a restore by hand.
        case legacyHoldsNoHistory(tables: [String])
        case imported
        case failed(String)
    }

    /// Copies the legacy store to `destination` once, while `destination`
    /// does not exist. The legacy file is only read, never changed or
    /// deleted: it is the user's copy if the import goes wrong. The copy goes
    /// through SQLite's backup API, so pages still in the legacy file's WAL
    /// come along and the result is one consistent file.
    static func importLegacyStore(from legacy: URL, to destination: URL) -> LegacyImport {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) { return .storeExists }
        guard fileManager.fileExists(atPath: legacy.path) else { return .noLegacyStore }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".importing")
        do {
            let source = try SQLiteFile(readingWithoutChanging: legacy)
            let tables = try source.tableNames()
            guard tables.contains(entityTable), try source.rowCount(of: entityTable) > 0 else {
                return .legacyHoldsNoHistory(tables: tables.filter(isEntityTable).sorted())
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            removeStoreFiles(at: staging)
            try source.backup(to: staging)
            try fileManager.moveItem(at: staging, to: destination)
            return .imported
        } catch {
            removeStoreFiles(at: staging)
            return .failed(String(describing: error))
        }
    }

    /// Why SwiftData must not open the file at `url`: it holds entity tables
    /// other than ours or columns of ours the model lacks, or it is a Core
    /// Data store without our table. Nil for a file this build may open,
    /// including one that does not exist yet.
    static func refusal(of url: URL, schema: Schema) throws -> DictationHistoryOpenFailure? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Ours, and SwiftData opens it read-write right after.
        let allTables = try SQLiteFile(readWrite: url).tableNames()
        if allTables.contains("Z_METADATA"), !allTables.contains(entityTable),
           !allTables.contains(where: { isEntityTable($0) })
        {
            return .missingHistoryTable
        }
        let unknown = try unknownContents(of: url, schema: schema)
        guard unknown.tables.isEmpty, unknown.columns.isEmpty else {
            return .unknownContents(tables: unknown.tables, columns: unknown.columns)
        }
        return nil
    }

    /// What the store at `url` holds that `schema` does not: entity tables
    /// other than ours and columns of ours the model lacks. Empty for a file
    /// that does not exist yet.
    static func unknownContents(
        of url: URL, schema: Schema
    ) throws -> (tables: [String], columns: [String]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], []) }
        let file = try SQLiteFile(readWrite: url)
        let tables = try file.tableNames().filter { isEntityTable($0) && $0 != entityTable }.sorted()
        let known = Set(["Z_PK", "Z_ENT", "Z_OPT"]).union(columnNames(of: schema))
        let columns = try file.columnNames(of: entityTable).filter { !known.contains($0) }.sorted()
        return (tables, columns)
    }

    /// Whether opening `url` with `schema` migrates it: the file has our
    /// table but lacks columns the model has. False for a new file.
    static func needsUpgrade(_ url: URL, schema: Schema) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let columns = Set(try SQLiteFile(readWrite: url).columnNames(of: entityTable))
        guard !columns.isEmpty else { return false }
        return !columnNames(of: schema).isSubset(of: columns)
    }

    /// Core Data names an attribute's column `Z` + its name in capitals.
    static func columnNames(of schema: Schema) -> Set<String> {
        let entity = schema.entities.first { $0.name == "DictationSessionRecord" }
        return Set((entity?.attributes ?? []).map { "Z" + $0.name.uppercased() })
    }

    /// Core Data's entity tables: `Z` + the entity name. Its own tables start
    /// with `Z_`, persistent history's with `A`.
    private static func isEntityTable(_ name: String) -> Bool {
        name.hasPrefix("Z") && !name.hasPrefix("Z_")
    }

    private static func removeStoreFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

struct SQLiteFileError: Error, CustomStringConvertible {
    let description: String
}

/// A SQLite database, closed when released.
final class SQLiteFile {
    private var db: OpaquePointer?

    init(readWrite url: URL) throws {
        try open(url.path, flags: SQLITE_OPEN_READWRITE, name: url.lastPathComponent)
    }

    /// Opens a file another build may still use without writing to it or
    /// beside it. A read-only connection to a WAL database needs the `-shm`
    /// file and cannot create it; with no WAL to read, the file is opened
    /// as immutable instead, which needs neither.
    init(readingWithoutChanging url: URL) throws {
        let wal = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal"))?[.size] as? Int
        if (wal ?? 0) > 0 {
            try open(url.path, flags: SQLITE_OPEN_READONLY, name: url.lastPathComponent)
        } else {
            let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
            try open(
                "file:\(path)?immutable=1", flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                name: url.lastPathComponent)
        }
    }

    private func open(_ filename: String, flags: Int32, name: String) throws {
        let status = sqlite3_open_v2(filename, &db, flags, nil)
        guard status == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            sqlite3_close(db)
            db = nil
            throw SQLiteFileError(description: "cannot open \(name): \(message)")
        }
        // Core Data may hold a lock for a moment (a save, a checkpoint, a
        // second build open at once); a check that failed on it would read
        // as a store that cannot be opened.
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit { sqlite3_close(db) }

    func rowCount(of table: String) throws -> Int {
        try strings("SELECT count(*) FROM \(table)", column: 0).first.flatMap { Int($0) } ?? 0
    }

    func tableNames() throws -> [String] {
        try strings("SELECT name FROM sqlite_master WHERE type = 'table'", column: 0)
    }

    /// Empty when the table does not exist.
    func columnNames(of table: String) throws -> [String] {
        try strings("PRAGMA table_info(\(table))", column: 1)
    }

    func backup(to url: URL) throws {
        var destination: OpaquePointer?
        defer { sqlite3_close(destination) }
        guard sqlite3_open_v2(
            url.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else { throw error(destination, "open the copy") }
        guard let backup = sqlite3_backup_init(destination, "main", db, "main") else {
            throw error(destination, "start the copy")
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw error(destination, "copy") }
    }

    private func strings(_ sql: String, column: Int32) throws -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error(db, sql)
        }
        var values: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW else { throw error(db, sql) }
            if let text = sqlite3_column_text(statement, column) {
                values.append(String(cString: text))
            }
        }
    }

    private func error(_ handle: OpaquePointer?, _ what: String) -> SQLiteFileError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
        return SQLiteFileError(description: "\(what): \(message)")
    }
}
