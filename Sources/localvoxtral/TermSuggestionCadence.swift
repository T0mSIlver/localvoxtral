import Foundation

/// Runs the hosted "Suggest terms" pass every N saved dictations, so the list
/// keeps growing after the user has forgotten the button exists (#368).
///
/// It only decides WHEN. The request, the row it lands in and the rule that
/// nothing is added without a click all stay in `SpeakerTermSuggestionModel`.
@MainActor
final class TermSuggestionCadence {
    /// A failed run keeps the counter, and waits this many more dictations:
    /// retrying on every dictation would send one request each while the API
    /// is down (owner ruling, 2026-09-21).
    static let retryAfterFailure = 10
    /// Launch already competes for the network and the helpers.
    static let quietAfterLaunchSeconds: TimeInterval = 60

    private let settings: SettingsStore
    private let model: @MainActor () -> SpeakerTermSuggestionModel?
    /// Blocks a run from STARTING. One already in flight is left alone when a
    /// dictation begins: it is a hosted request that takes minutes, and at a
    /// daily user's pace cancelling would kill most of them (owner ruling).
    private let isDictationActive: @MainActor () -> Bool
    private let launchedAt: Date
    private let now: @MainActor () -> Date
    /// The counter when the run in flight read the history. Dictations saved
    /// while it waits for an answer were not read, so they stay counted.
    private var countAtRunStart: Int?

    init(
        settings: SettingsStore,
        model: @escaping @MainActor () -> SpeakerTermSuggestionModel?,
        isDictationActive: @escaping @MainActor () -> Bool,
        launchedAt: Date,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.settings = settings
        self.model = model
        self.isDictationActive = isDictationActive
        self.launchedAt = launchedAt
        self.now = now
    }

    /// Called once per dictation record saved. Counts whatever the setting
    /// says, so turning it on after a hundred dictations runs at the next one.
    func dictationSaved() {
        settings.termSuggestionDictationsSinceRun += 1
        runIfDue()
    }

    private func runIfDue() {
        let count = settings.termSuggestionDictationsSinceRun
        guard let interval = settings.termSuggestionInterval.dictations,
              count >= interval, count >= settings.termSuggestionRetryAt
        else { return }
        guard let model = model() else { return }
        guard model.phase != .loading, model.unavailableReason == nil,
              settings.llmPolishingConfiguration != nil
        else { return }
        // Both deferrals leave the counter over the threshold, so the next
        // saved dictation asks again.
        guard !isDictationActive() else {
            Log.polishing.info("Term suggestions due, deferred: dictation in progress")
            return
        }
        guard now().timeIntervalSince(launchedAt) >= Self.quietAfterLaunchSeconds else {
            Log.polishing.info("Term suggestions due, deferred: app just launched")
            return
        }
        Log.polishing.info(
            "Term suggestions starting by themselves after \(count, privacy: .public) dictations"
        )
        countAtRunStart = count
        model.startInBackground()
    }

    /// Wired to `SpeakerTermSuggestionModel.onRunFinished`, so the button's
    /// runs count too: a user who just pressed it has nothing new to find
    /// fifty dictations early.
    func runFinished(_ outcome: SpeakerTermSuggestionModel.RunOutcome) {
        let count = settings.termSuggestionDictationsSinceRun
        let read = countAtRunStart ?? count
        countAtRunStart = nil
        switch outcome {
        case .completed:
            settings.termSuggestionDictationsSinceRun = max(0, count - read)
            settings.termSuggestionRetryAt = 0
        case .failed:
            settings.termSuggestionRetryAt = count + Self.retryAfterFailure
        case .notRun:
            break
        }
    }
}
