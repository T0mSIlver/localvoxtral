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

    /// What the dictation ended up as, the transcript when nothing changed it.
    var finalText: String { polishedText ?? rawText }

    /// `polishedText` holds whatever the commit path turned the transcript
    /// into, and that is not always a model's work: with polishing off, the
    /// replacement dictionary and the clipboard marker land there too. The
    /// commit path stores it only when it differs, but a record written by an
    /// older build may hold an equal copy.
    var textWasChanged: Bool {
        guard let polishedText else { return false }
        return polishedText != rawText
    }

    /// A polish request answered for this dictation. Only the polish path
    /// records a duration.
    var polishRan: Bool { polishingDurationSeconds != nil && status != .llmFailed }

    /// This entry with `polishedText` replaced, for the in-memory copy that
    /// may hold what History must not (the clipboard payload).
    func replacingPolishedText(_ text: String?) -> DictationHistoryEntry {
        DictationHistoryEntry(
            id: id, startedAt: startedAt, finishedAt: finishedAt, rawText: rawText,
            polishedText: text, polishingDurationSeconds: polishingDurationSeconds,
            provider: provider, model: model, outputMode: outputMode,
            targetAppBundleID: targetAppBundleID, status: status,
            commitSucceeded: commitSucceeded, polishProfile: polishProfile,
            polishContextSummary: polishContextSummary)
    }

    /// What "Copy last dictation" copies, nil when there is no text.
    var textToCopy: String? {
        LastDictationCopy.text(
            rawText: rawText, polishedText: polishedText, polishFailed: status == .llmFailed)
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
    /// Only dictations that started at or after this. Nil is all of them.
    var since: Date?
    var limit = 500
}

@MainActor
final class DictationSessionStore {
    private let modelContainer: ModelContainer
    /// Every write runs behind the one before it. Each operation uses its own
    /// `ModelContext`, and two contexts saving at once is how a delete-all
    /// would lose to the insert it was started after.
    private var lastWrite: Task<Void, Never>?
    /// Called after every write that changed something, so an open History
    /// pane reads again.
    var onChange: (@MainActor () -> Void)?
    /// Where each dictation's audio goes when the user keeps it. Set once, at
    /// launch; nil keeps no audio and deletes none.
    var audioStore: DictationAudioStore?

    convenience init?() {
        self.init(inMemory: false)
    }

    /// `inMemory` is for tests: the default configuration writes the user's
    /// real `default.store`.
    convenience init?(inMemory: Bool) {
        let schema = Schema([DictationSessionRecord.self])
        self.init(configuration: ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory))
    }

    /// A store file somewhere else: a copy of a user's history, for the replay
    /// eval.
    convenience init?(url: URL) {
        let schema = Schema([DictationSessionRecord.self])
        self.init(configuration: ModelConfiguration(schema: schema, url: url))
    }

    private init?(configuration: ModelConfiguration) {
        do {
            let schema = Schema([DictationSessionRecord.self])
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
    /// `audio` is the dictation's 16 kHz mono PCM16, written beside the
    /// record in the same step, so no trim can run between the two. The
    /// record is saved first: a save that fails leaves no file behind.
    @discardableResult
    func save(_ record: DictationSessionRecord, audio: Data? = nil) -> Task<Void, Never> {
        let entry = DictationHistoryEntry(record)
        let audioStore = audio == nil ? nil : audioStore
        return enqueueWrite("save dictation \(entry.id)") { context in
            context.insert(entry.makeRecord())
            try context.save()
            if let audio, let audioStore {
                do {
                    try audioStore.write(pcm16: audio, for: entry.id)
                    Log.persistence.info(
                        "History: saved \(audio.count / AudioChunkBuffer.bytesPerSecond, privacy: .public) s of audio for dictation \(entry.id, privacy: .public)"
                    )
                } catch {
                    Log.persistence.error(
                        "History: audio write failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return 1
        }
    }

    @discardableResult
    func delete(id: UUID) -> Task<Void, Never> {
        let audioStore = audioStore
        // The record goes first: a save that fails keeps the dictation with its
        // audio, and a file that will not go is retried by the next sweep.
        return enqueueWrite("delete dictation \(id)") { context in
            let deleted = try Self.deleteRecords(
                matching: #Predicate<DictationSessionRecord> { $0.id == id }, in: context)
            try context.save()
            audioStore?.remove([id])
            return deleted
        }
    }

    @discardableResult
    func deleteAll() -> Task<Void, Never> {
        let audioStore = audioStore
        return enqueueWrite("delete all dictations") { context in
            let deleted = try Self.deleteRecords(matching: nil, in: context)
            try context.save()
            audioStore?.removeAll()
            return deleted
        }
    }

    /// Deletes every dictation that started before `cutoff`
    /// (`DictationHistoryRetention.cutoff(now:)`), and the audio of every
    /// dictation no longer in the store.
    @discardableResult
    func trim(olderThan cutoff: Date) -> Task<Void, Never> {
        let audioStore = audioStore
        return enqueueWrite("trim dictations") { context in
            let deleted = try Self.deleteRecords(
                matching: #Predicate<DictationSessionRecord> { $0.startedAt < cutoff },
                in: context)
            if let audioStore {
                if deleted > 0 { try context.save() }
                try Self.removeOrphanedAudio(audioStore, context: context)
            }
            return deleted
        }
    }

    /// Deletes the recordings whose dictation is gone. Run at launch, where
    /// Forever retention never trims: it is what retries a delete that failed
    /// and clears a file a crash left behind.
    @discardableResult
    func removeOrphanedAudio() -> Task<Void, Never> {
        let audioStore = audioStore
        return enqueueWrite("sweep dictation audio") { context in
            if let audioStore {
                audioStore.removeStrayFiles()
                try Self.removeOrphanedAudio(audioStore, context: context)
            }
            return 0
        }
    }

    /// Only the recordings on disk are looked up: most users keep none, and
    /// this runs after every saved dictation.
    private nonisolated static func removeOrphanedAudio(
        _ audioStore: DictationAudioStore, context: ModelContext
    ) throws {
        let stored = Array(audioStore.storedIDs())
        guard !stored.isEmpty else { return }
        let kept = try Set(context.fetch(FetchDescriptor<DictationSessionRecord>(
            predicate: #Predicate { stored.contains($0.id) })).map(\.id))
        let removed = audioStore.removeAll(except: kept)
        if removed > 0 {
            Log.persistence.info(
                "History: deleted \(removed, privacy: .public) recording(s) whose dictation is gone"
            )
        }
    }

    /// Deletes every recording and keeps the dictations: the audio setting
    /// turned off.
    @discardableResult
    func deleteAllAudio() -> Task<Void, Never> {
        let audioStore = audioStore
        return enqueueWrite("delete all dictation audio") { _ in
            let removed = audioStore?.removeAll() ?? 0
            Log.persistence.info("History: deleted \(removed, privacy: .public) recording(s)")
            return 0
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
            let since = query.since ?? .distantPast
            var descriptor = FetchDescriptor<DictationSessionRecord>(
                predicate: #Predicate { record in
                    (matchAnyText
                        || record.rawText.localizedStandardContains(search)
                        || (record.polishedText?.localizedStandardContains(search) == true))
                        && (!notInsertedOnly || !record.commitSucceeded)
                        && (!polishFailedOnly || record.status == polishFailed)
                        && record.startedAt >= since
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

    /// Recordings on disk and their size, for the Settings row.
    func audioSummary() async -> (recordings: Int, bytes: Int) {
        guard let audioStore else { return (0, 0) }
        return await read("summarize dictation audio") { _ in
            (audioStore.storedIDs().count, audioStore.totalBytes())
        } ?? (0, 0)
    }

    func count() async -> Int {
        await read("count dictations") { context in
            try context.fetchCount(FetchDescriptor<DictationSessionRecord>())
        } ?? 0
    }

    /// How many dictations `trim(olderThan:)` would delete, for the question
    /// the History pane asks before shortening the retention. Nil when the
    /// store could not say: a failed count is not "nothing to delete".
    func count(olderThan cutoff: Date) async -> Int? {
        await read("count dictations before a cutoff") { context in
            try context.fetchCount(
                FetchDescriptor<DictationSessionRecord>(
                    predicate: #Predicate { $0.startedAt < cutoff }))
        }
    }

    /// The text each recent dictation ended up as (polished when there was a
    /// polish, raw otherwise), newest first.
    func recentEntries(limit: Int) async -> [DictationHistoryEntry] {
        var query = DictationHistoryQuery()
        query.limit = limit
        return await entries(matching: query)
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
