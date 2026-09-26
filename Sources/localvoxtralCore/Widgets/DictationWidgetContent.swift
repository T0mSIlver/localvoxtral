import Foundation

/// The period the Dictation widget counts, picked in Edit Widget.
package enum DictationWidgetPeriod: String, Sendable, CaseIterable {
    case today
    case last7Days
    case last30Days

    package var label: String {
        switch self {
        case .today: return "Today"
        case .last7Days: return "Last 7 days"
        case .last30Days: return "Last 30 days"
        }
    }

    /// Local days counted, today included.
    package var dayCount: Int {
        switch self {
        case .today: return 1
        case .last7Days: return 7
        case .last30Days: return 30
        }
    }
}

/// What the Dictation widget draws (#630).
package struct DictationWidgetContent: Equatable, Sendable {
    package struct Bar: Equatable, Sendable {
        /// 0...1 of the tallest day in the chart.
        package var height: Double
        package var isToday: Bool

        package init(height: Double, isToday: Bool) {
            self.height = height
            self.isToday = isToday
        }
    }

    package struct App: Equatable, Sendable {
        package var name: String
        package var dictations: String
        /// 0...1 of the first app's count.
        package var share: Double

        package init(name: String, dictations: String, share: Double) {
            self.name = name
            self.dictations = dictations
            self.share = share
        }
    }

    package struct Fix: Equatable, Sendable {
        package var heard: String
        package var written: String
        package var times: String

        package init(heard: String, written: String, times: String) {
            self.heard = heard
            self.written = written
            self.times = times
        }
    }

    package var periodLabel: String
    package var words: String
    package var dictations: String
    package var speaking: String
    /// "23 min"; the view adds "≈ … saved".
    package var saved: String
    /// Nil under ten seconds of dictating.
    package var wordsPerMinute: String?
    /// The last 14 days, oldest first, whatever the period.
    package var chart: [Bar]
    package var chartStartLabel: String
    package var apps: [App]
    /// "Changed 61 of 98 · median 0.9 s".
    package var polish: String
    package var fixes: [Fix]

    package static let chartDays = 14
    package static let maxApps = 3
    package static let maxFixes = 2

    package init(
        _ dictation: WidgetSnapshot.Dictation,
        period: DictationWidgetPeriod,
        now: Date,
        calendar: Calendar,
        locale: Locale = .current
    ) {
        let today = calendar.startOfDay(for: now)
        let periodStart = calendar.date(byAdding: .day, value: -(period.dayCount - 1), to: today) ?? today
        let inPeriod = dictation.days.filter { $0.start >= periodStart && $0.start <= now }
        let words = inPeriod.reduce(0) { $0 + $1.words }
        let seconds = inPeriod.reduce(0) { $0 + $1.dictatingSeconds }

        periodLabel = period.label
        self.words = WidgetFormat.count(words, locale: locale)
        dictations = WidgetFormat.count(inPeriod.reduce(0) { $0 + $1.dictations }, locale: locale)
        speaking = WidgetFormat.duration(seconds)
        saved = WidgetFormat.duration(TypingPace.secondsSaved(words: words, dictatingSeconds: seconds))
        wordsPerMinute = TypingPace.wordsPerMinute(words: words, dictatingSeconds: seconds)
            .map { WidgetFormat.count(Int($0.rounded()), locale: locale) }

        let chartStart = calendar.date(byAdding: .day, value: -(Self.chartDays - 1), to: today) ?? today
        let dayWords: [Int] = (0..<Self.chartDays).map { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: chartStart) else { return 0 }
            return dictation.days.first { calendar.isDate($0.start, inSameDayAs: day) }?.words ?? 0
        }
        let tallest = max(dayWords.max() ?? 0, 1)
        chart = dayWords.enumerated().map { index, words in
            Bar(height: Double(words) / Double(tallest), isToday: index == Self.chartDays - 1)
        }
        var dayFormat = Date.FormatStyle(date: .omitted, time: .omitted).month(.abbreviated).day()
        dayFormat.locale = locale
        dayFormat.timeZone = calendar.timeZone
        chartStartLabel = chartStart.formatted(dayFormat)

        let detail: WidgetSnapshot.PeriodDetail
        switch period {
        case .today: detail = dictation.today
        case .last7Days: detail = dictation.last7Days
        case .last30Days: detail = dictation.last30Days
        }
        let topCount = max(detail.topApps.first?.dictations ?? 0, 1)
        apps = detail.topApps.prefix(Self.maxApps).map {
            App(name: $0.name, dictations: WidgetFormat.count($0.dictations, locale: locale), share: Double($0.dictations) / Double(topCount))
        }
        if detail.polishRan == 0 {
            polish = "No dictation polished"
        } else {
            var line = "Changed \(WidgetFormat.count(detail.polishChanged, locale: locale)) of \(WidgetFormat.count(detail.polishRan, locale: locale))"
            if let median = detail.medianPolishSeconds {
                line += " · median \(median.formatted(.number.precision(.fractionLength(1)).locale(locale))) s"
            }
            polish = line
        }
        fixes = detail.recurringFixes.prefix(Self.maxFixes).map {
            Fix(heard: $0.heard, written: $0.written, times: "×\($0.dictations)")
        }
    }
}
