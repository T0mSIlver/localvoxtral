import SwiftUI

/// What the saved dictations add up to over a period. Every number comes from
/// `DictationInsights`; this file only lays them out.
struct InsightsSettingsPane: View {
    let viewModel: DictationViewModel
    var navigator: SettingsNavigator?

    @AppStorage("dictationInsightsPeriod") private var periodRawValue =
        DictationInsightsPeriod.month.rawValue
    @State private var insights: DictationInsights?
    /// LaunchServices is asked once per bundle id, not once per render.
    @State private var appNames: [String: String] = [:]

    /// For a caller that needs the pane showing given numbers (a rendering
    /// check); the app lets the pane read the store.
    private let fixedInsights: DictationInsights?

    init(
        viewModel: DictationViewModel, navigator: SettingsNavigator? = nil,
        insights: DictationInsights? = nil
    ) {
        self.viewModel = viewModel
        self.navigator = navigator
        fixedInsights = insights
    }

    private var period: Binding<DictationInsightsPeriod> {
        Binding(
            get: { DictationInsightsPeriod(rawValue: periodRawValue) ?? .month },
            set: { periodRawValue = $0.rawValue }
        )
    }

    private struct ReloadTrigger: Equatable {
        let revision: Int
        let period: String
    }

    var body: some View {
        let shown = fixedInsights ?? insights ?? DictationInsights()
        SettingsPage(tab: .insights) {
            activityGroup(shown)
            reliabilityGroup(shown)
            polishingGroup(shown)
            recurringFixesGroup(shown)
            appsGroup(shown)
        }
        .task(id: ReloadTrigger(
            revision: viewModel.dictationHistoryRevision, period: periodRawValue
        )) {
            guard fixedInsights == nil else { return }
            await reload()
        }
    }

    private func reload() async {
        guard let store = viewModel.sessionStore else {
            insights = DictationInsights()
            return
        }
        let entries = await store.entries(since: period.wrappedValue.start(now: Date()))
        // A year of dictations is thousands of word diffs: not on the main actor.
        let computed = await Task.detached { DictationInsights(entries: entries) }.value
        guard !Task.isCancelled else { return }
        for app in computed.topApps where appNames[app.bundleID] == nil {
            appNames[app.bundleID] =
                DictationHistoryModel.installedAppName(bundleID: app.bundleID) ?? app.bundleID
        }
        insights = computed
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
            InsightRow(title: "Dictations", value: insights.dictations.formatted())
            InsightRow(title: "Words", value: insights.words.formatted())
            InsightRow(
                title: "Time dictating",
                value: insights.dictations == 0
                    ? "—" : DictationInsightsText.duration(insights.dictatingSeconds))
            InsightRow(
                title: "Pace",
                value: insights.wordsPerMinute.map { "\(Int($0.rounded())) words per minute" } ?? "—")
            InsightRow(
                title: "Saved over typing",
                help: "Against \(Int(DictationInsights.typingWordsPerMinute)) words per minute.",
                value: insights.dictations == 0
                    ? "—" : DictationInsightsText.duration(insights.secondsSavedOverTyping))
        }
    }

    private func reliabilityGroup(_ insights: DictationInsights) -> some View {
        SettingsGroup(title: "Reliability") {
            InsightRow(
                title: "Not inserted",
                help: "The text never reached the app. History still has it.",
                value: insights.notInserted.formatted(),
                action: insights.notInserted > 0 ? { showHistory(.notInserted) } : nil)
            InsightRow(
                title: "Polish failed",
                help: "The transcript went in unpolished.",
                value: insights.polishFailed.formatted(),
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
                title: "Slow wait",
                help: "One polish in ten takes longer.",
                value: insights.slowPolishSeconds.map(Self.seconds) ?? "—")
        }
    }

    private func recurringFixesGroup(_ insights: DictationInsights) -> some View {
        SettingsGroup(title: "What polishing keeps fixing") {
            if insights.recurringFixes.isEmpty {
                SettingsGroupRow {
                    Text("Nothing in \(DictationInsights.recurringFixMinimumDictations) dictations or more.")
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
                    Text("No Overlay Buffer dictation yet.")
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
        navigator?.historyFilterRequest = filter
        navigator?.selectedTab = .history
    }

    private static func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) s"
    }
}

/// A label, its number, and optionally a Show button that opens the
/// dictations the number counted.
private struct InsightRow: View {
    let title: String
    var help: String?
    let value: String
    var action: (() -> Void)?

    var body: some View {
        SettingsFieldRow(title: title, help: help) {
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
