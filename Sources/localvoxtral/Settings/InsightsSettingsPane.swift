import Charts
import SwiftUI

/// What the saved dictations add up to over a period. Every number comes from
/// `DictationInsights`; this file only lays them out.
struct InsightsSettingsPane: View {
    let viewModel: DictationViewModel
    var navigator: SettingsNavigator?

    @AppStorage("dictationInsightsPeriod") private var periodRawValue =
        DictationInsightsPeriod.month.rawValue
    @State private var insights: DictationInsights?
    /// The period `insights` was counted over. While it is not the selected
    /// one the rows show no numbers, not the previous period's.
    @State private var countedPeriod: DictationInsightsPeriod?
    /// Where the counted period started, for the History rows Show opens.
    @State private var countedSince: Date?
    /// The last twelve weeks, whatever the period says: a trend inside a
    /// 7-day period is one bar.
    @State private var trend: DictationLearningTrend?
    /// LaunchServices is asked once per bundle id, not once per render.
    @State private var appNames: [String: String] = [:]

    /// For a caller that needs the pane showing given numbers (a rendering
    /// check); the app lets the pane read the store.
    private let fixedInsights: DictationInsights?
    private let fixedTrend: DictationLearningTrend?

    init(
        viewModel: DictationViewModel, navigator: SettingsNavigator? = nil,
        insights: DictationInsights? = nil, trend: DictationLearningTrend? = nil
    ) {
        self.viewModel = viewModel
        self.navigator = navigator
        fixedInsights = insights
        fixedTrend = trend
    }

    private var period: Binding<DictationInsightsPeriod> {
        Binding(
            get: { DictationInsightsPeriod(rawValue: periodRawValue) ?? .month },
            set: { periodRawValue = $0.rawValue }
        )
    }

    /// No count for the selected period yet. A zero would read as a fact.
    private var isCounting: Bool {
        fixedInsights == nil && countedPeriod != period.wrappedValue
    }

    private func count(_ value: Int) -> String {
        isCounting ? "—" : value.formatted()
    }

    private struct ReloadTrigger: Equatable {
        let revision: Int
        let period: String
    }

    var body: some View {
        let counted = countedPeriod == period.wrappedValue ? insights : nil
        let shown = fixedInsights ?? counted ?? DictationInsights()
        SettingsPage(tab: .insights) {
            activityGroup(shown)
            reliabilityGroup(shown)
            polishingGroup(shown)
            learningGroup(fixedTrend ?? trend ?? DictationLearningTrend())
            recurringFixesGroup(shown)
            appsGroup(shown)
        }
        .onAppear { viewModel.applyDictationHistoryRetention() }
        .task(id: ReloadTrigger(
            revision: viewModel.dictationHistoryRevision, period: periodRawValue
        )) {
            guard fixedInsights == nil else { return }
            await reload()
        }
    }

    private func reload() async {
        let period = period.wrappedValue
        guard let store = viewModel.sessionStore else {
            insights = DictationInsights()
            trend = DictationLearningTrend()
            countedPeriod = period
            return
        }
        let now = Date()
        let since = period.start(now: now)
        let entries = await store.entries(since: since)
        let trendStart = DictationLearningTrend.start(now: now)
        let trendEntries = since.map { $0 <= trendStart } == true
            ? entries.filter { $0.startedAt >= trendStart }
            : await store.entries(since: trendStart)
        let terms = viewModel.settings.polishSpeakerTerms
            + (viewModel.learnedTermStore?.snapshot().confirmedEverywhere().map(\.term) ?? [])
        // A year of dictations is thousands of word diffs: not on the main
        // actor, and stopped when the pane closes or the period changes.
        let counting = Task.detached {
            (DictationInsights(entries: entries),
             DictationLearningTrend(entries: trendEntries, terms: terms, now: now))
        }
        let (computed, computedTrend) = await withTaskCancellationHandler {
            await counting.value
        } onCancel: {
            counting.cancel()
        }
        guard !Task.isCancelled else { return }
        trend = computedTrend
        for app in computed.topApps where appNames[app.bundleID] == nil {
            appNames[app.bundleID] =
                DictationHistoryModel.installedAppName(bundleID: app.bundleID) ?? app.bundleID
        }
        insights = computed
        countedPeriod = period
        countedSince = since
    }

    // MARK: - Groups

    private func activityGroup(_ insights: DictationInsights) -> some View {
        SettingsGroup(title: "Activity") {
            SettingsFieldRow(title: "Period") {
                Picker("", selection: period) {
                    ForEach(DictationInsightsPeriod.allCases) { period in
                        Text(period.label).tag(period)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("insights.period")
            }
            InsightRow(title: "Dictations", value: count(insights.dictations))
            InsightRow(title: "Words", value: count(insights.words))
            InsightRow(
                title: "Time dictating",
                value: insights.dictations == 0
                    ? "—" : DictationInsightsText.duration(insights.dictatingSeconds))
            InsightRow(
                title: "Pace",
                value: insights.wordsPerMinute.map { "\(Int($0.rounded())) words per minute" } ?? "—")
            InsightRow(
                title: "Saved over typing at \(Int(DictationInsights.typingWordsPerMinute)) words per minute",
                value: insights.dictations == 0
                    ? "—" : DictationInsightsText.duration(insights.secondsSavedOverTyping))
        }
    }

    private func reliabilityGroup(_ insights: DictationInsights) -> some View {
        SettingsGroup(title: "Reliability") {
            InsightRow(
                title: "Not inserted",
                value: count(insights.notInserted),
                action: insights.notInserted > 0 ? { showHistory(.notInserted) } : nil)
            InsightRow(
                title: "Polish failed",
                value: count(insights.polishFailed),
                action: insights.polishFailed > 0 ? { showHistory(.polishFailed) } : nil)
        }
    }

    private func polishingGroup(_ insights: DictationInsights) -> some View {
        SettingsGroup(title: "Polishing") {
            InsightRow(
                title: "Changed the text",
                value: insights.polishRan == 0
                    ? "—"
                    : "\(DictationInsightsText.share(insights.polishChanged, of: insights.polishRan)) of \(insights.polishRan.formatted()) polished")
            InsightRow(
                title: "Typical wait",
                value: insights.medianPolishSeconds.map(Self.seconds) ?? "—")
            InsightRow(
                title: "One in ten waits over",
                value: insights.slowPolishSeconds.map(Self.seconds) ?? "—")
        }
    }

    private func learningGroup(_ trend: DictationLearningTrend) -> some View {
        SettingsGroup(title: "Learning, last 12 weeks") {
            TrendRow(
                title: "Terms the recognizer spelled right",
                help: "Names and terms and learned terms, before any fix.",
                weeks: trend.weeks,
                share: \.termsSpelledRightShare)
            TrendRow(
                title: "Transcripts inserted as recognized",
                help: "Of the polished dictations.",
                weeks: trend.weeks,
                share: \.transcriptKeptShare)
        }
    }

    private func recurringFixesGroup(_ insights: DictationInsights) -> some View {
        SettingsGroup(title: "What polishing keeps fixing") {
            if insights.recurringFixes.isEmpty {
                SettingsGroupRow {
                    Text(isCounting ? "—" : "No repeated fix yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(insights.recurringFixes) { fix in
                    InsightRow(
                        title: "\(fix.heard) → \(fix.written)",
                        value: "\(fix.dictations.formatted()) dictations")
                }
            }
        }
    }

    private func appsGroup(_ insights: DictationInsights) -> some View {
        SettingsGroup(title: "Apps") {
            if insights.topApps.isEmpty {
                SettingsGroupRow {
                    // Live Auto-Paste records no target app.
                    Text(isCounting ? "—" : "No Overlay Buffer dictation yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(insights.topApps) { app in
                    InsightRow(
                        title: appNames[app.bundleID] ?? app.bundleID,
                        value: DictationInsightsText.share(app.dictations, of: insights.dictations))
                }
            }
        }
    }

    private func showHistory(_ filter: DictationHistoryQuery.Filter) {
        navigator?.historyRequest = .init(filter: filter, since: countedSince)
        navigator?.selectedTab = .history
    }

    private static func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) s"
    }
}

/// A weekly share as bars, and the most recent counted week's value beside
/// them. A week with too few dictations to count draws no bar.
private struct TrendRow: View {
    let title: String
    let help: String
    let weeks: [DictationLearningTrend.Week]
    let share: KeyPath<DictationLearningTrend.Week, Double?>

    private var latest: Double? { weeks.last { $0[keyPath: share] != nil }?[keyPath: share] ?? nil }

    var body: some View {
        SettingsFieldRow(title: title, help: help) {
            HStack(spacing: 10) {
                if weeks.contains(where: { $0[keyPath: share] != nil }) {
                    // By position, not by date: the weeks are 7-day steps back
                    // from now, which calendar-week bins would split.
                    Chart(Array(weeks.enumerated()), id: \.offset) { index, week in
                        if let value = week[keyPath: share] {
                            BarMark(x: .value("Week", String(index)), y: .value("Share", value))
                        }
                    }
                    // Every week keeps its slot, so an empty one is a gap.
                    .chartXScale(domain: weeks.indices.map(String.init))
                    .chartYScale(domain: 0...1)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(width: 120, height: 24)
                    .accessibilityLabel(accessibilitySummary)
                }
                Text(latest.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
    }

    private var accessibilitySummary: String {
        let counted = weeks.enumerated().compactMap { index, week in
            week[keyPath: share].map { (weeksAgo: weeks.count - 1 - index, value: $0) }
        }
        guard let first = counted.first, let last = counted.last else { return "No weeks counted" }
        let percent = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))
        func when(_ weeksAgo: Int) -> String {
            switch weeksAgo {
            case 0: "in the last 7 days"
            case 1: "1 week ago"
            default: "\(weeksAgo) weeks ago"
            }
        }
        return "\(first.value.formatted(percent)) \(when(first.weeksAgo)), "
            + "\(last.value.formatted(percent)) \(when(last.weeksAgo)), "
            + "\(counted.count) of \(weeks.count) weeks counted"
    }
}

/// A label, its number, and optionally a Show button that opens the
/// dictations the number counted.
private struct InsightRow: View {
    let title: String
    let value: String
    var action: (() -> Void)?

    var body: some View {
        SettingsFieldRow(title: title) {
            HStack(spacing: 8) {
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let action {
                    Button("Show", action: action)
                        .controlSize(.small)
                }
            }
        }
    }
}
