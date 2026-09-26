import Foundation
import Observation

/// What the Insights pane shows. The app keeps one for its lifetime, so going
/// back to the pane draws the last count at once while it counts again.
@MainActor
@Observable
final class DictationInsightsModel {
    static let periodDefaultsKey = "dictationInsightsPeriod"

    var period: DictationInsightsPeriod {
        didSet { defaults.set(period.rawValue, forKey: Self.periodDefaultsKey) }
    }
    private(set) var insights: DictationInsights?
    /// The period `insights` was counted over. While it is not the selected
    /// one the pane shows no numbers, not the previous period's.
    private(set) var countedPeriod: DictationInsightsPeriod?
    /// Where the counted period started, for the History rows Show opens.
    private(set) var countedSince: Date?
    /// The last twelve weeks, whatever the period says: a trend inside a
    /// 7-day period is one bar.
    private(set) var trend: DictationLearningTrend?
    /// LaunchServices is asked once per bundle id, not once per render.
    private(set) var appNames: [String: String] = [:]

    /// A slow count must not overwrite the result of the one started after it.
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: @MainActor () -> DictationSessionStore?
    @ObservationIgnored private let terms: @MainActor () -> [String]
    @ObservationIgnored private let appName: @MainActor (String) -> String?

    init(
        defaults: UserDefaults = .standard,
        store: @escaping @MainActor () -> DictationSessionStore?,
        terms: @escaping @MainActor () -> [String],
        appName: @escaping @MainActor (String) -> String? = DictationHistoryModel.installedAppName
    ) {
        self.defaults = defaults
        self.store = store
        self.terms = terms
        self.appName = appName
        period = defaults.string(forKey: Self.periodDefaultsKey)
            .flatMap(DictationInsightsPeriod.init(rawValue:)) ?? .month
    }

    /// The speaker's terms are the ones Names and terms lists and the learned
    /// terms confirmed everywhere.
    convenience init(viewModel: DictationViewModel) {
        self.init(
            store: { [weak viewModel] in viewModel?.sessionStore },
            terms: { [weak viewModel] in
                guard let viewModel else { return [] }
                return viewModel.settings.polishSpeakerTerms
                    + (viewModel.learnedTermStore?.snapshot().confirmedEverywhere().map(\.term) ?? [])
            })
    }

    /// No count for the selected period yet. A zero would read as a fact.
    var isCounting: Bool { countedPeriod != period }

    func reload(now: Date = Date()) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let period = period
        guard let store = store() else {
            insights = DictationInsights()
            trend = DictationLearningTrend()
            countedPeriod = period
            countedSince = nil
            return
        }
        let since = period.start(now: now)
        let entries = await store.entries(since: since)
        let trendStart = DictationLearningTrend.start(now: now)
        let trendEntries = since.map { $0 <= trendStart } == true
            ? entries.filter { $0.startedAt >= trendStart }
            : await store.entries(since: trendStart)
        let terms = terms()
        // A year of dictations is thousands of word diffs: not on the main
        // actor, and stopped when the pane closes or the period changes. The
        // two counts run side by side, and the period's numbers show without
        // waiting for the trend.
        let counting = Task.detached { DictationInsights(entries: entries) }
        let trending = Task.detached {
            DictationLearningTrend(entries: trendEntries, terms: terms, now: now)
        }
        let computed = await withTaskCancellationHandler {
            await counting.value
        } onCancel: {
            counting.cancel()
            trending.cancel()
        }
        guard !Task.isCancelled, generation == reloadGeneration else { return }
        for app in computed.topApps where appNames[app.bundleID] == nil {
            appNames[app.bundleID] = appName(app.bundleID) ?? app.bundleID
        }
        insights = computed
        countedPeriod = period
        countedSince = since

        let computedTrend = await withTaskCancellationHandler {
            await trending.value
        } onCancel: {
            trending.cancel()
        }
        guard !Task.isCancelled, generation == reloadGeneration else { return }
        trend = computedTrend
    }
}
