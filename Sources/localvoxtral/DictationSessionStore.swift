import Foundation
import os
import SwiftData

/// One saved dictation as a value. `DictationSessionRecord` is a SwiftData
/// model bound to the context that fetched it, so nothing outside the store
/// ever holds one: reads come back as these.
struct DictationHistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let finishedAt: Date
    let rawText: String
    let polishedText: String?
    let polishingDurationSeconds: Double?
    let provider: String
    let model: String
    let outputMode: String
    let targetAppBundleID: String?
    let status: DictationSessionStatus
    let commitSucceeded: Bool
    let polishProfile: String?
    let polishContextSummary: String?

    /// What the dictation ended up as: the polished text when polishing
    /// changed it, the transcript otherwise.
    var finalText: String { polishedText ?? rawText }

    /// The commit path stores `polishedText` only when it differs from the
    /// transcript, but a record written by an older build may hold an equal
    /// copy.
    var polishChangedText: Bool {
        guard let polishedText else { return false }
        return polishedText != rawText
    }
}

extension DictationHistoryEntry {
    init(_ record: DictationSessionRecord) {
        self.init(
            id: record.id,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            rawText: record.rawText,
            polishedText: record.polishedText,
            polishingDurationSeconds: record.polishingDurationSeconds,
            provider: record.provider,
            model: record.model,
            outputMode: record.outputMode,
            targetAppBundleID: record.targetAppBundleID,
            status: DictationSessionStatus(rawValue: record.status) ?? .completed,
            commitSucceeded: record.commitSucceeded,
            polishProfile: record.polishProfile,
            polishContextSummary: record.polishContextSummary
        )
    }

    fileprivate func makeRecord() -> DictationSessionRecord {
        DictationSessionRecord(
            id: id,
            startedAt: startedAt,
            finishedAt: finishedAt,
            rawText: rawText,
            polishedText: polishedText,
            polishingDurationSeconds: polishingDurationSeconds,
            provider: provider,
            model: model,
            outputMode: outputMode,
            targetAppBundleID: targetAppBundleID,
            status: status,
            commitSucceeded: commitSucceeded,
            polishProfile: polishProfile,
            polishContextSummary: polishContextSummary
        )
    }
}

/// Which saved dictations a read wants.
struct DictationHistoryQuery: Equatable, Sendable {
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all
        /// The text never reached the target app, so the history is the only
        /// place it still exists.
        case notInserted
        case polishFailed

        var id: String { rawValue }
    }

    /// Matched against the transcript and the polished text, ignoring case and
    /// diacritics. Empty matches everything.
    var searchText = ""
    var filter = Filter.all
    var limit = 500
}

@MainActor
final class DictationSessionStore {
    private let modelContainer: ModelContainer
    /// Every write runs behind the one before it. Each operation uses its own
    /// `ModelContext`, and two contexts saving at once is how a delete-all
    /// would lose to the insert it was started after.
    private var lastWrite: Task<Void, Never>?
    /// Bumped after every write that landed, so an open History window knows
    /// to read again.
    var onChange: (@MainActor () -> Void)?

    convenience init?() {
        self.init(inMemory: false)
    }

    /// `inMemory` is for tests: the default configuration writes the user's
    /// real `default.store`.
    init?(inMemory: Bool) {
        do {
            let schema = Schema([DictationSessionRecord.self])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
            self.modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            Log.persistence.info("DictationSessionStore initialized")
        } catch {
            Log.persistence.error(
                "Failed to initialize DictationSessionStore: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - Writes

    /// The returned task finishes once the record is on disk; production
    /// callers drop it.
    @discardableResult
    func save(_ record: DictationSessionRecord) -> Task<Void, Never> {
        let entry = DictationHistoryEntry(record)
        return enqueueWrite("save dictation \(entry.id)") { context in
            context.insert(entry.makeRecord())
            return 1
        }
    }

    @discardableResult
    func delete(id: UUID) -> Task<Void, Never> {
        enqueueWrite("delete dictation \(id)") { context in
            try Self.deleteRecords(
                matching: #Predicate<DictationSessionRecord> { $0.id == id }, in: context)
        }
    }

    @discardableResult
    func deleteAll() -> Task<Void, Never> {
        enqueueWrite("delete all dictations") { context in
            try Self.deleteRecords(matching: nil, in: context)
        }
    }

    /// Deletes every dictation that started before `cutoff`
    /// (`DictationHistoryRetention.cutoff(now:)`).
    @discardableResult
    func trim(olderThan cutoff: Date) -> Task<Void, Never> {
        enqueueWrite("trim dictations") { context in
            try Self.deleteRecords(
                matching: #Predicate<DictationSessionRecord> { $0.startedAt < cutoff },
                in: context)
        }
    }

    /// Fetch-then-delete rather than `ModelContext.delete(model:where:)`: the
    /// batch form bypasses the context, and these sets are small.
    private nonisolated static func deleteRecords(
        matching predicate: Predicate<DictationSessionRecord>?,
        in context: ModelContext
    ) throws -> Int {
        let records = try context.fetch(FetchDescriptor<DictationSessionRecord>(predicate: predicate))
        for record in records { context.delete(record) }
        return records.count
    }

    private func enqueueWrite(
        _ label: String,
        _ body: @escaping @Sendable (ModelContext) throws -> Int
    ) -> Task<Void, Never> {
        let container = modelContainer
        let previous = lastWrite
        let task = Task.detached { [weak self] in
            await previous?.value
            var changed = 0
            do {
                let context = ModelContext(container)
                changed = try body(context)
                if changed > 0 { try context.save() }
                Log.persistence.info(
                    "History: \(label, privacy: .public) changed \(changed, privacy: .public) record(s)"
                )
            } catch {
                changed = 0
                Log.persistence.error(
                    "History: \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            if changed > 0 {
                await self?.onChange?()
            }
        }
        lastWrite = task
        return task
    }

    // MARK: - Reads

    /// Newest first. Waits for the writes already queued, so a read that
    /// follows a delete never shows the deleted row.
    func entries(matching query: DictationHistoryQuery = DictationHistoryQuery()) async
        -> [DictationHistoryEntry]
    {
        await read("fetch dictations") { context in
            let search = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchAnyText = search.isEmpty
            let notInsertedOnly = query.filter == .notInserted
            let polishFailedOnly = query.filter == .polishFailed
            let polishFailed = DictationSessionStatus.llmFailed.rawValue
            var descriptor = FetchDescriptor<DictationSessionRecord>(
                predicate: #Predicate { record in
                    (matchAnyText
                        || record.rawText.localizedStandardContains(search)
                        || (record.polishedText?.localizedStandardContains(search) == true))
                        && (!notInsertedOnly || !record.commitSucceeded)
                        && (!polishFailedOnly || record.status == polishFailed)
                },
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
            descriptor.fetchLimit = query.limit
            return try context.fetch(descriptor).map(DictationHistoryEntry.init)
        } ?? []
    }

    /// Every dictation that started at or after `since` (all of them for nil),
    /// for the insights, which count rather than list.
    func entries(since: Date?) async -> [DictationHistoryEntry] {
        await read("fetch dictations for insights") { context in
            let from = since ?? .distantPast
            let descriptor = FetchDescriptor<DictationSessionRecord>(
                predicate: #Predicate { $0.startedAt >= from },
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
            return try context.fetch(descriptor).map(DictationHistoryEntry.init)
        } ?? []
    }

    func count() async -> Int {
        await read("count dictations") { context in
            try context.fetchCount(FetchDescriptor<DictationSessionRecord>())
        } ?? 0
    }

    /// The text each recent dictation ended up as (polished when there was a
    /// polish, raw otherwise), newest first.
    func recentFinalTexts(limit: Int) async -> [String] {
        var query = DictationHistoryQuery()
        query.limit = limit
        return await entries(matching: query).map(\.finalText)
    }

    private func read<Value: Sendable>(
        _ label: String,
        _ body: @escaping @Sendable (ModelContext) throws -> Value
    ) async -> Value? {
        let container = modelContainer
        let pendingWrite = lastWrite
        return await Task.detached {
            await pendingWrite?.value
            do {
                return try body(ModelContext(container))
            } catch {
                Log.persistence.error(
                    "History: \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }.value
    }
}
