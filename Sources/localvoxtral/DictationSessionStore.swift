import Foundation
import os
import SwiftData

@MainActor
final class DictationSessionStore {
    private struct Snapshot: Sendable {
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
    }

    private let modelContainer: ModelContainer

    init?() {
        do {
            let schema = Schema([DictationSessionRecord.self])
            let configuration = ModelConfiguration(schema: schema)
            self.modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            Log.persistence.info("DictationSessionStore initialized")
        } catch {
            Log.persistence.error(
                "Failed to initialize DictationSessionStore: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func save(_ record: DictationSessionRecord) {
        let snapshot = Snapshot(
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
            commitSucceeded: record.commitSucceeded
        )
        let container = modelContainer
        Task.detached {
            let context = ModelContext(container)
            let detachedRecord = DictationSessionRecord(
                id: snapshot.id,
                startedAt: snapshot.startedAt,
                finishedAt: snapshot.finishedAt,
                rawText: snapshot.rawText,
                polishedText: snapshot.polishedText,
                polishingDurationSeconds: snapshot.polishingDurationSeconds,
                provider: snapshot.provider,
                model: snapshot.model,
                outputMode: snapshot.outputMode,
                targetAppBundleID: snapshot.targetAppBundleID,
                status: snapshot.status,
                commitSucceeded: snapshot.commitSucceeded
            )
            context.insert(detachedRecord)
            do {
                try context.save()
                Log.persistence.info("Saved dictation session record id=\(snapshot.id, privacy: .public)")
            } catch {
                Log.persistence.error(
                    "Failed to save dictation session record: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
