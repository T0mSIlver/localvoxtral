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
    /// Every feature that called a model in the selected period, from the
    /// usage ledger. Summed apart from the dictation count: the ledger
    /// changes on every request, and a sum of it is cheap.
    private(set) var featureUsage: [FeatureUsage] = []
    /// Shown instead of the numbers when the store did not open or failed to
    /// answer (#985): a zero would read as a fact.
    private(set) var unavailableText: String?

    /// A slow count must not overwrite the result of the one started after it.
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: @MainActor () -> DictationSessionStore?
    @ObservationIgnored private let unavailable: @MainActor () -> String?
    @ObservationIgnored private let terms: @MainActor () -> [String]
    @ObservationIgnored private let appName: @MainActor (String) -> String?
    @ObservationIgnored private let usage: @MainActor () -> [UsageEntry]

    init(
        defaults: UserDefaults = .standard,
        store: @escaping @MainActor () -> DictationSessionStore?,
        unavailable: @escaping @MainActor () -> String? = { nil },
        terms: @escaping @MainActor () -> [String],
        appName: @escaping @MainActor (String) -> String? = DictationHistoryModel.installedAppName,
        usage: @escaping @MainActor () -> [UsageEntry] = { [] }
    ) {
        self.defaults = defaults
        self.store = store
        self.unavailable = unavailable
        self.terms = terms
        self.appName = appName
        self.usage = usage
        period = defaults.string(forKey: Self.periodDefaultsKey)
            .flatMap(DictationInsightsPeriod.init(rawValue:)) ?? .month
    }

    /// The speaker's terms are the ones Global terms lists and the learned
    /// terms confirmed everywhere.
    convenience init(viewModel: DictationViewModel) {
        self.init(
            store: { [weak viewModel] in viewModel?.sessionStore },
            unavailable: { [weak viewModel] in viewModel?.historyUnavailableText },
            terms: { [weak viewModel] in
                guard let viewModel else { return [] }
                return viewModel.settings.polishSpeakerTerms
                    + (viewModel.learnedTermStore?.snapshot().confirmedEverywhere().map(\.term) ?? [])
            },
            usage: { [weak viewModel] in viewModel?.engines.usageLedger?.entries() ?? [] })
    }

    func reloadUsage(now: Date = Date()) {
        featureUsage = FeatureUsage.summarize(usage(), since: period.start(now: now))
    }

    /// No count for the selected period yet. A zero would read as a fact.
    var isCounting: Bool { countedPeriod != period }

    func reload(now: Date = Date()) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let period = period
        guard let store = store() else {
            showUnavailable()
            return
        }
        let since = period.start(now: now)
        let entries = await store.entries(since: since)
        let trendStart = DictationLearningTrend.start(now: now)
        let trendEntries = since.map { $0 <= trendStart } == true
            ? entries.filter { $0.startedAt >= trendStart }
            : await store.entries(since: trendStart)
        guard generation == reloadGeneration else { return }
        if unavailable() != nil {
            showUnavailable()
            return
        }
        unavailableText = nil
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

    /// No store, or one that failed to answer: the reason when there is one,
    /// and no numbers. With History off there is no reason and the counts are
    /// zero.
    private func showUnavailable() {
        unavailableText = unavailable()
        if unavailableText == nil {
            insights = DictationInsights()
            trend = DictationLearningTrend()
            countedPeriod = period
        } else {
            insights = nil
            trend = nil
            countedPeriod = nil
        }
        countedSince = nil
    }
}
