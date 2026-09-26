import Foundation

/// Everything the desktop widgets show, in the one file the app writes and
/// the widget extension reads (#630). The extension is sandboxed and reads
/// nothing else: not the history store, not the settings.
///
/// It holds state, not display text. The `…WidgetContent` mappings turn it
/// into what each widget draws, at the time the widget renders, so a day
/// boundary moves "Today" without the app writing anything.
package struct WidgetSnapshot: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package var version: Int
    package var writtenAt: Date
    package var engines: Engines
    package var dictation: Dictation
    package var vocabulary: Vocabulary
    /// False while history retention is "Don't keep".
    package var historyKept: Bool
    /// Nil while history is off, and after history is deleted.
    package var lastDictation: LastDictation?

    package init(
        version: Int = WidgetSnapshot.currentVersion,
        writtenAt: Date,
        engines: Engines,
        dictation: Dictation,
        vocabulary: Vocabulary,
        historyKept: Bool,
        lastDictation: LastDictation?
    ) {
        self.version = version
        self.writtenAt = writtenAt
        self.engines = engines
        self.dictation = dictation
        self.vocabulary = vocabulary
        self.historyKept = historyKept
        // The text is history: with history off, it is not written anywhere.
        self.lastDictation = historyKept ? lastDictation : nil
    }

    // MARK: Engines

    package enum EngineRole: String, Codable, Sendable, CaseIterable {
        case speech
        case polish
    }

    /// Mirrors the app's `BackendMode`; the widget cannot see that type.
    package enum EngineMode: String, Codable, Sendable {
        case managedLocal
        case mistralAPI
        case externalURL
    }

    package enum EngineState: Codable, Equatable, Sendable {
        case ready
        case starting
        case downloading(downloadedBytes: Int64, totalBytes: Int64?, paused: Bool)
        /// Not loaded; the app starts it when a dictation needs it.
        case idle
        /// Carries no text on purpose: the widget says one sentence and the
        /// error stays in the app.
        case failed
    }

    package struct Engine: Codable, Equatable, Sendable {
        package var mode: EngineMode
        /// Managed local only. "Voxtral 4B".
        package var shortModelName: String?
        /// Managed local only. "Voxtral Mini 4B Realtime".
        package var modelName: String?
        package var state: EngineState
        /// The helper's `phys_footprint`, sampled when the snapshot was
        /// written. Managed local and running only.
        package var memoryBytes: UInt64?

        package init(
            mode: EngineMode,
            shortModelName: String? = nil,
            modelName: String? = nil,
            state: EngineState,
            memoryBytes: UInt64? = nil
        ) {
            self.mode = mode
            self.shortModelName = shortModelName
            self.modelName = modelName
            self.state = state
            self.memoryBytes = memoryBytes
        }
    }

    /// Spend on the Mistral API, from `MistralUsageLedger`.
    package struct MistralSpend: Codable, Equatable, Sendable {
        package var speechTodayEUR: Double
        package var polishTodayEUR: Double
        package var speechLast30DaysEUR: Double
        package var polishLast30DaysEUR: Double
        package var audioSecondsToday: Double
        package var polishesToday: Int

        package init(
            speechTodayEUR: Double = 0,
            polishTodayEUR: Double = 0,
            speechLast30DaysEUR: Double = 0,
            polishLast30DaysEUR: Double = 0,
            audioSecondsToday: Double = 0,
            polishesToday: Int = 0
        ) {
            self.speechTodayEUR = speechTodayEUR
            self.polishTodayEUR = polishTodayEUR
            self.speechLast30DaysEUR = speechLast30DaysEUR
            self.polishLast30DaysEUR = polishLast30DaysEUR
            self.audioSecondsToday = audioSecondsToday
            self.polishesToday = polishesToday
        }

        package var todayEUR: Double { speechTodayEUR + polishTodayEUR }
        package var last30DaysEUR: Double { speechLast30DaysEUR + polishLast30DaysEUR }
    }

    package struct Engines: Codable, Equatable, Sendable {
        package var speech: Engine
        package var polish: Engine
        package var polishEnabled: Bool
        package var physicalMemoryBytes: UInt64
        package var mistral: MistralSpend
        /// False in the snapshot the app writes as it quits: its helpers quit
        /// with it, and nothing is left to answer a button.
        package var appRunning: Bool

        package init(
            speech: Engine,
            polish: Engine,
            polishEnabled: Bool,
            physicalMemoryBytes: UInt64,
            mistral: MistralSpend = MistralSpend(),
            appRunning: Bool = true
        ) {
            self.speech = speech
            self.polish = polish
            self.polishEnabled = polishEnabled
            self.physicalMemoryBytes = physicalMemoryBytes
            self.mistral = mistral
            self.appRunning = appRunning
        }

        package func engine(_ role: EngineRole) -> Engine {
            role == .speech ? speech : polish
        }
    }

    // MARK: Dictation

    /// What one saved dictation adds to the day totals.
    package struct DictationSample: Equatable, Sendable {
        package var startedAt: Date
        package var finishedAt: Date
        package var words: Int
        package var polishingSeconds: Double?

        package init(startedAt: Date, finishedAt: Date, words: Int, polishingSeconds: Double?) {
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.words = words
            self.polishingSeconds = polishingSeconds
        }

        /// One dictation cannot count for more than this. The times are
        /// wall-clock, so a Mac that slept mid-dictation would otherwise own
        /// the total.
        package static let maxDictatingSeconds: Double = 3_600

        /// Start to finish, polishing wait taken out.
        package var dictatingSeconds: Double {
            let elapsed = finishedAt.timeIntervalSince(startedAt) - (polishingSeconds ?? 0)
            return min(max(0, elapsed), Self.maxDictatingSeconds)
        }
    }

    /// Day totals for the `count` local days ending today, oldest first,
    /// one entry per day with a dictation. A dictation counts on the day it
    /// started.
    package static func days(
        from samples: [DictationSample],
        now: Date,
        calendar: Calendar,
        count: Int = 30
    ) -> [Day] {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(count - 1), to: today) else { return [] }
        var byDay: [Date: Day] = [:]
        for sample in samples where sample.startedAt >= first && sample.startedAt <= now {
            let start = calendar.startOfDay(for: sample.startedAt)
            var day = byDay[start] ?? Day(start: start, words: 0, dictations: 0, dictatingSeconds: 0)
            day.words += sample.words
            day.dictations += 1
            day.dictatingSeconds += sample.dictatingSeconds
            byDay[start] = day
        }
        return byDay.values.sorted { $0.start < $1.start }
    }

    /// One local calendar day of dictation.
    package struct Day: Codable, Equatable, Sendable {
        package var start: Date
        package var words: Int
        package var dictations: Int
        /// Start to finish, polishing wait taken out, as the Insights pane counts.
        package var dictatingSeconds: Double

        package init(start: Date, words: Int, dictations: Int, dictatingSeconds: Double) {
            self.start = start
            self.words = words
            self.dictations = dictations
            self.dictatingSeconds = dictatingSeconds
        }
    }

    package struct AppCount: Codable, Equatable, Sendable {
        package var name: String
        package var dictations: Int

        package init(name: String, dictations: Int) {
            self.name = name
            self.dictations = dictations
        }
    }

    package struct RecurringFix: Codable, Equatable, Sendable {
        package var heard: String
        package var written: String
        package var dictations: Int

        package init(heard: String, written: String, dictations: Int) {
            self.heard = heard
            self.written = written
            self.dictations = dictations
        }
    }

    /// What the large Dictation widget adds, per period: the Insights pane's
    /// lists. Totals come from `days`, so they follow the clock.
    package struct PeriodDetail: Codable, Equatable, Sendable {
        package var topApps: [AppCount]
        package var polishRan: Int
        package var polishChanged: Int
        package var medianPolishSeconds: Double?
        package var recurringFixes: [RecurringFix]

        package init(
            topApps: [AppCount] = [],
            polishRan: Int = 0,
            polishChanged: Int = 0,
            medianPolishSeconds: Double? = nil,
            recurringFixes: [RecurringFix] = []
        ) {
            self.topApps = topApps
            self.polishRan = polishRan
            self.polishChanged = polishChanged
            self.medianPolishSeconds = medianPolishSeconds
            self.recurringFixes = recurringFixes
        }
    }

    package struct Dictation: Codable, Equatable, Sendable {
        /// Oldest first; days without a dictation may be missing.
        package var days: [Day]
        package var today: PeriodDetail
        package var last7Days: PeriodDetail
        package var last30Days: PeriodDetail

        package init(
            days: [Day] = [],
            today: PeriodDetail = PeriodDetail(),
            last7Days: PeriodDetail = PeriodDetail(),
            last30Days: PeriodDetail = PeriodDetail()
        ) {
            self.days = days
            self.today = today
            self.last7Days = last7Days
            self.last30Days = last30Days
        }
    }

    // MARK: Vocabulary

    package struct Vocabulary: Codable, Equatable, Sendable {
        /// Share of learned terms spelled right, per week, oldest first; nil
        /// for a week with too few dictations to say.
        package var weeklyShares: [Double?]
        package var termCount: Int
        /// Newest first.
        package var termsLearnedThisWeek: [String]

        package init(weeklyShares: [Double?] = [], termCount: Int = 0, termsLearnedThisWeek: [String] = []) {
            self.weeklyShares = weeklyShares
            self.termCount = termCount
            self.termsLearnedThisWeek = termsLearnedThisWeek
        }
    }

    // MARK: Last dictation

    package struct LastDictation: Codable, Equatable, Sendable {
        package var text: String
        /// Nil when the app is unknown (Live Auto-Paste records none).
        package var appName: String?
        package var finishedAt: Date
        package var words: Int
        package var polishRan: Bool
        package var polishSeconds: Double?

        package init(text: String, appName: String?, finishedAt: Date, words: Int, polishRan: Bool, polishSeconds: Double?) {
            self.text = text
            self.appName = appName
            self.finishedAt = finishedAt
            self.words = words
            self.polishRan = polishRan
            self.polishSeconds = polishSeconds
        }
    }
}
