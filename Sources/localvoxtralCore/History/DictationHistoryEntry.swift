import Foundation

package enum DictationSessionStatus: String, Codable, Sendable {
    case sttCompleted = "stt_completed"
    case completed = "completed"
    case llmFailed = "llm_failed"
}

/// One saved dictation as a value. `DictationSessionRecord` is a SwiftData
/// model bound to the context that fetched it, so nothing outside the store
/// ever holds one: reads come back as these.
package struct DictationHistoryEntry: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let startedAt: Date
    package let finishedAt: Date
    package let rawText: String
    package let polishedText: String?
    package let polishingDurationSeconds: Double?
    package let provider: String
    package let model: String
    package let outputMode: String
    package let targetAppBundleID: String?
    package let status: DictationSessionStatus
    package let commitSucceeded: Bool
    package let polishProfile: String?
    package let polishContextSummary: String?
    package var projectKey: String? = nil
    package var projectName: String? = nil
    package var joinedAgent: String? = nil
    /// Where a quick capture went; nil for every other dictation.
    package var quickCaptureDestination: String? = nil
    /// `EditSignalOutcome`'s raw value, nil when nothing was watched.
    package var editOutcome: String? = nil
    package var polishPromptTokens: Int? = nil
    package var stoppedAt: Date? = nil
    package var polishBackend: String? = nil
    package var polishModel: String? = nil

    package init(
        id: UUID,
        startedAt: Date,
        finishedAt: Date,
        rawText: String,
        polishedText: String?,
        polishingDurationSeconds: Double?,
        provider: String,
        model: String,
        outputMode: String,
        targetAppBundleID: String?,
        status: DictationSessionStatus,
        commitSucceeded: Bool,
        polishProfile: String?,
        polishContextSummary: String?,
        projectKey: String? = nil,
        projectName: String? = nil,
        joinedAgent: String? = nil,
        quickCaptureDestination: String? = nil,
        editOutcome: String? = nil,
        polishPromptTokens: Int? = nil,
        stoppedAt: Date? = nil,
        polishBackend: String? = nil,
        polishModel: String? = nil
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
        self.status = status
        self.commitSucceeded = commitSucceeded
        self.polishProfile = polishProfile
        self.polishContextSummary = polishContextSummary
        self.projectKey = projectKey
        self.projectName = projectName
        self.joinedAgent = joinedAgent
        self.quickCaptureDestination = quickCaptureDestination
        self.editOutcome = editOutcome
        self.polishPromptTokens = polishPromptTokens
        self.stoppedAt = stoppedAt
        self.polishBackend = polishBackend
        self.polishModel = polishModel
    }

    /// The `outputMode` a quick capture is saved under.
    package static let quickCaptureOutputMode = "quickCapture"

    /// What the dictation ended up as, the transcript when nothing changed it.
    package var finalText: String { polishedText ?? rawText }

    /// `polishedText` holds whatever the commit path turned the transcript
    /// into, and that is not always a model's work: with polishing off, the
    /// replacement dictionary and the clipboard marker land there too. The
    /// commit path stores it only when it differs, but a record written by an
    /// older build may hold an equal copy.
    package var textWasChanged: Bool {
        guard let polishedText else { return false }
        return polishedText != rawText
    }

    /// A polish request answered for this dictation. Only the polish path
    /// records a duration.
    package var polishRan: Bool { polishingDurationSeconds != nil && status != .llmFailed }

    /// This entry with `polishedText` replaced, for the in-memory copy that
    /// may hold what History must not (the clipboard payload).
    package func replacingPolishedText(_ text: String?) -> DictationHistoryEntry {
        DictationHistoryEntry(
            id: id, startedAt: startedAt, finishedAt: finishedAt, rawText: rawText,
            polishedText: text, polishingDurationSeconds: polishingDurationSeconds,
            provider: provider, model: model, outputMode: outputMode,
            targetAppBundleID: targetAppBundleID, status: status,
            commitSucceeded: commitSucceeded, polishProfile: polishProfile,
            polishContextSummary: polishContextSummary, projectKey: projectKey,
            projectName: projectName, joinedAgent: joinedAgent,
            quickCaptureDestination: quickCaptureDestination, editOutcome: editOutcome,
            polishPromptTokens: polishPromptTokens, stoppedAt: stoppedAt,
            polishBackend: polishBackend, polishModel: polishModel)
    }

    /// What "Copy last dictation" copies, nil when there is no text.
    package var textToCopy: String? {
        LastDictationCopy.text(
            rawText: rawText, polishedText: polishedText, polishFailed: status == .llmFailed)
    }
}

/// Which saved dictations a read wants.
package struct DictationHistoryQuery: Equatable, Sendable {
    package enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all
        /// The text never reached the target app, so the history is the only
        /// place it still exists.
        case notInserted
        case polishFailed

        package var id: String { rawValue }
    }

    /// Matched against the transcript and the polished text, ignoring case and
    /// diacritics. Empty matches everything.
    package var searchText = ""
    package var filter = Filter.all
    /// Only dictations that started at or after this. Nil is all of them.
    package var since: Date?
    package var limit = 500

    package init(searchText: String = "", filter: Filter = .all, since: Date? = nil, limit: Int = 500) {
        self.searchText = searchText
        self.filter = filter
        self.since = since
        self.limit = limit
    }
}
