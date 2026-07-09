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
    /// Polishing prompt profile that ran for this session (`standard`/`agent`
    /// rawValue), or nil when polishing did not run. Additive optional field:
    /// SwiftData lightweight-migrates existing stores, and old records decode
    /// with this as nil.
    var polishProfile: String?
    /// Count-only provenance for an attached clipboard polish context (e.g.
    /// `clipboard:412ch`, or `clipboard:2000/5321ch` when the excerpt was
    /// capped), or nil when no context was attached. Never holds clipboard
    /// content — just character counts. Additive optional field: SwiftData
    /// lightweight-migrates existing stores, and old records decode as nil.
    var polishContextSummary: String?

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
        commitSucceeded: Bool,
        polishProfile: String? = nil,
        polishContextSummary: String? = nil
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
        self.polishProfile = polishProfile
        self.polishContextSummary = polishContextSummary
    }
}
