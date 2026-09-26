import Foundation

/// Turns the app's state into the widgets' snapshot (#630). The history and
/// learned-term parts are counted off the main actor; the rest is read from
/// the settings and the helpers when the snapshot is written.
enum WidgetSnapshotAssembler {
    /// History read for one snapshot: the trend's twelve weeks, which cover
    /// the Dictation widget's thirty days.
    static func historyStart(now: Date) -> Date {
        DictationLearningTrend.start(now: now)
    }

    static func engineState(_ status: ManagedBackendStatus) -> WidgetSnapshot.EngineState {
        switch status {
        case .preparingModel(let progress):
            return .downloading(downloadedBytes: progress.downloadedBytes, totalBytes: progress.totalBytes, paused: false)
        case .pausedModelDownload(let progress):
            return .downloading(downloadedBytes: progress.downloadedBytes, totalBytes: progress.totalBytes, paused: true)
        case .starting: return .starting
        case .ready: return .ready
        case .stopped: return .idle
        case .failed: return .failed
        }
    }

    static func engineMode(_ mode: BackendMode) -> WidgetSnapshot.EngineMode {
        switch mode {
        case .managedLocal: return .managedLocal
        case .mistralAPI: return .mistralAPI
        case .externalURL: return .externalURL
        }
    }

    static func mistralSpend(_ entries: [MistralUsageEntry], now: Date, calendar: Calendar) -> WidgetSnapshot.MistralSpend {
        let today = calendar.startOfDay(for: now)
        let month = now.addingTimeInterval(-30 * 86_400)
        var spend = WidgetSnapshot.MistralSpend()
        for entry in entries where entry.date >= month {
            let cost = entry.costEUR ?? 0
            let isToday = entry.date >= today
            switch entry.kind {
            case .dictation:
                spend.speechLast30DaysEUR += cost
                if isToday {
                    spend.speechTodayEUR += cost
                    spend.audioSecondsToday += entry.audioSeconds ?? 0
                }
            case .retranscription:
                // Speech spend; its audio was already counted by the realtime
                // socket (MistralUsageEntry.Kind.retranscription).
                spend.speechLast30DaysEUR += cost
                if isToday {
                    spend.speechTodayEUR += cost
                }
            case .polish:
                spend.polishLast30DaysEUR += cost
                if isToday {
                    spend.polishTodayEUR += cost
                    spend.polishesToday += 1
                }
            }
        }
        return spend
    }

    /// What the history adds: day totals, each period's Insights lists, the
    /// vocabulary trend and the last dictation. `entries` is newest first,
    /// as the store returns them. Pure; runs detached.
    struct History: Sendable {
        var dictation: WidgetSnapshot.Dictation
        var weeklyShares: [Double?]
        var lastDictation: WidgetSnapshot.LastDictation?
        /// Bundle ids the lists name, for the main actor to turn into app names.
        var bundleIDs: Set<String>
    }

    static func history(
        entries: [DictationHistoryEntry],
        terms: [String],
        now: Date,
        calendar: Calendar
    ) -> History {
        let samples = entries.map {
            WidgetSnapshot.DictationSample(
                startedAt: $0.startedAt,
                finishedAt: $0.finishedAt,
                words: TranscriptDiff.wordRanges(in: $0.finalText).count,
                polishingSeconds: $0.polishingDurationSeconds
            )
        }
        let today = calendar.startOfDay(for: now)
        func detail(days: Int) -> (WidgetSnapshot.PeriodDetail, Set<String>) {
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
            let insights = DictationInsights(entries: entries.filter { $0.startedAt >= start })
            return (
                WidgetSnapshot.PeriodDetail(
                    // A bundle id until the main actor names it.
                    topApps: insights.topApps.map { .init(name: $0.bundleID, dictations: $0.dictations) },
                    polishRan: insights.polishRan,
                    polishChanged: insights.polishChanged,
                    medianPolishSeconds: insights.medianPolishSeconds,
                    recurringFixes: insights.recurringFixes.map {
                        .init(heard: $0.heard, written: $0.written, dictations: $0.dictations)
                    }
                ),
                Set(insights.topApps.map(\.bundleID))
            )
        }
        let (todayDetail, todayApps) = detail(days: 1)
        let (weekDetail, weekApps) = detail(days: 7)
        let (monthDetail, monthApps) = detail(days: 30)
        let trend = DictationLearningTrend(
            entries: entries.filter { $0.startedAt >= DictationLearningTrend.start(now: now) },
            terms: terms,
            now: now
        )
        let latest = entries.lazy.compactMap { entry in entry.textToCopy.map { (entry, $0) } }.first
        let last = latest.map { entry, text in
            WidgetSnapshot.LastDictation(
                text: text,
                appName: entry.targetAppBundleID,
                finishedAt: entry.finishedAt,
                words: TranscriptDiff.wordRanges(in: text).count,
                polishRan: entry.polishRan,
                polishSeconds: entry.polishRan ? entry.polishingDurationSeconds : nil
            )
        }
        var bundleIDs = todayApps.union(weekApps).union(monthApps)
        if let id = latest?.0.targetAppBundleID { bundleIDs.insert(id) }
        return History(
            dictation: WidgetSnapshot.Dictation(
                days: WidgetSnapshot.days(from: samples, now: now, calendar: calendar),
                today: todayDetail,
                last7Days: weekDetail,
                last30Days: monthDetail
            ),
            weeklyShares: trend.weeks.map(\.termsSpelledRightShare),
            lastDictation: last,
            bundleIDs: bundleIDs
        )
    }

    /// Swaps the bundle ids `history` left in for app names.
    static func named(_ history: History, names: [String: String]) -> History {
        var history = history
        func rename(_ detail: inout WidgetSnapshot.PeriodDetail) {
            detail.topApps = detail.topApps.map { .init(name: names[$0.name] ?? $0.name, dictations: $0.dictations) }
        }
        rename(&history.dictation.today)
        rename(&history.dictation.last7Days)
        rename(&history.dictation.last30Days)
        if let id = history.lastDictation?.appName {
            history.lastDictation?.appName = names[id] ?? id
        }
        return history
    }

    /// Terms first seen in the last seven days, newest first, each spelling once.
    static func termsLearnedThisWeek(_ terms: LearnedTerms, now: Date) -> [String] {
        let weekStart = now.addingTimeInterval(-7 * 86_400)
        var seen: Set<String> = []
        return terms.projects.flatMap(\.terms)
            .filter { $0.firstSeen >= weekStart }
            .sorted { $0.firstSeen > $1.firstSeen }
            .compactMap { seen.insert($0.term.caseFoldedForMatching).inserted ? $0.term : nil }
    }
}
