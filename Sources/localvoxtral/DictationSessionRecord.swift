import Foundation
import SwiftData

enum DictationSessionStatus: String, Codable, Sendable {
    case sttCompleted = "stt_completed"
    case completed = "completed"
    case llmFailed = "llm_failed"
}

@Model
final class DictationSessionRecord {
    var id: UUID
    var startedAt: Date
    var finishedAt: Date
    var rawText: String
    var polishedText: String?
    var polishingDurationSeconds: Double?
    var provider: String
    var model: String
    var outputMode: String
    var targetAppBundleID: String?
    var status: String
    var commitSucceeded: Bool

    init(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date,
        rawText: String,
        polishedText: String? = nil,
        polishingDurationSeconds: Double? = nil,
        provider: String,
        model: String,
        outputMode: String,
        targetAppBundleID: String? = nil,
        status: DictationSessionStatus,
        commitSucceeded: Bool
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.rawText = rawText
        self.polishedText = polishedText
        self.polishingDurationSeconds = polishingDurationSeconds
        self.provider = provider
        self.model = model
        self.outputMode = outputMode
        self.targetAppBundleID = targetAppBundleID
        self.status = status.rawValue
        self.commitSucceeded = commitSucceeded
    }
}
