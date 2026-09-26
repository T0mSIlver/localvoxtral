import Charts
import SwiftUI

/// What the saved dictations add up to over a period. Every number comes from
/// `DictationInsights`; this file only lays them out.
struct InsightsSettingsPane: View {
    let viewModel: DictationViewModel
    let model: DictationInsightsModel
    var navigator: SettingsNavigator?

    private var period: Binding<DictationInsightsPeriod> {
        Binding(get: { model.period }, set: { model.period = $0 })
    }

    private var isCounting: Bool { model.isCounting }

    private func count(_ value: Int) -> String {
        isCounting ? "—" : value.formatted()
    }

    private struct ReloadTrigger: Equatable {
        let revision: Int
        let period: DictationInsightsPeriod
    }

    var body: some View {
        let shown = (isCounting ? nil : model.insights) ?? DictationInsights()
        SettingsPage(tab: .insights) {
            activityGroup(shown)
            reliabilityGroup(shown)
            polishingGroup(shown)
            learningGroup(model.trend ?? DictationLearningTrend())
            recurringFixesGroup(shown)
            appsGroup(shown)
        }
        .onAppear { viewModel.applyDictationHistoryRetention() }
        .task(id: ReloadTrigger(
            revision: viewModel.dictationHistoryRevision, period: model.period
        )) {
            await model.reload()
        }
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
                title: "Your terms recognized correctly",
                weeks: trend.weeks,
                share: \.termsSpelledRightShare)
            TrendRow(
                title: "Polished dictations needing no fix",
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
                        title: model.appNames[app.bundleID] ?? app.bundleID,
                        value: DictationInsightsText.share(app.dictations, of: insights.dictations))
                }
            }
        }
    }

    private func showHistory(_ filter: DictationHistoryQuery.Filter) {
        navigator?.historyRequest = .init(filter: filter, since: model.countedSince)
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
    let weeks: [DictationLearningTrend.Week]
    let share: KeyPath<DictationLearningTrend.Week, Double?>

    private var latest: Double? { weeks.last { $0[keyPath: share] != nil }?[keyPath: share] ?? nil }

    var body: some View {
        SettingsFieldRow(title: title) {
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
