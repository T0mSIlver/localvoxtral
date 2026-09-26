import Foundation
import XCTest

@testable import localvoxtralCore

/// What each desktop widget shows for a given snapshot (#630). The cases are
/// the states in the issue's mockups.
final class WidgetContentTests: XCTestCase {
    typealias Row = EnginesWidgetContent.Row
    typealias Engine = WidgetSnapshot.Engine

    private let locale = Locale(identifier: "en_US")
    private static let gib: UInt64 = 1_073_741_824

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Saturday 2026-09-26 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_434_800)

    private func voxtral(_ state: WidgetSnapshot.EngineState = .ready, memory: UInt64? = 4_509_715_661) -> Engine {
        Engine(mode: .managedLocal, shortModelName: "Voxtral 4B", modelName: "Voxtral Mini 4B Realtime", state: state, memoryBytes: memory)
    }

    private func qwen(_ state: WidgetSnapshot.EngineState = .ready, memory: UInt64? = 3_113_851_290) -> Engine {
        Engine(mode: .managedLocal, shortModelName: "Qwen3.5 4B", modelName: "Qwen3.5 4B", state: state, memoryBytes: memory)
    }

    private let mistral = Engine(mode: .mistralAPI, state: .ready)
    private let external = Engine(mode: .externalURL, state: .ready)

    private let spend = WidgetSnapshot.MistralSpend(
        speechTodayEUR: 0.03, polishTodayEUR: 0.01,
        speechLast30DaysEUR: 0.71, polishLast30DaysEUR: 0.41,
        audioSecondsToday: 18 * 60, polishesToday: 23
    )

    private func engines(
        speech: Engine, polish: Engine, polishEnabled: Bool = true, appRunning: Bool = true
    ) -> WidgetSnapshot.Engines {
        WidgetSnapshot.Engines(
            speech: speech, polish: polish, polishEnabled: polishEnabled,
            physicalMemoryBytes: 32 * Self.gib, mistral: spend, appRunning: appRunning
        )
    }

    // MARK: Engines

    func testEnginesCases() {
        let cases: [(String, WidgetSnapshot.Engines, WidgetSize, EnginesWidgetContent)] = [
            ("all local, small", engines(speech: voxtral(), polish: qwen()), .small, EnginesWidgetContent(
                layout: .rows([
                    Row(role: .speech, title: "Speech", status: "Ready", model: "Voxtral 4B", trailing: "4.2 GB"),
                    Row(role: .polish, title: "Polish", status: "Ready", model: "Qwen3.5 4B", trailing: "2.9 GB"),
                ], footer: .memory(
                    segments: [.init(role: .speech, fraction: 4_509_715_661 / (32.0 * 1_073_741_824)),
                               .init(role: .polish, fraction: 3_113_851_290 / (32.0 * 1_073_741_824))],
                    amount: "7.1", caption: "7.1 of 32 GB memory")),
                showsTurnOffPolish: false)),
            ("all local, medium: full names and the button", engines(speech: voxtral(), polish: qwen()), .medium, EnginesWidgetContent(
                layout: .rows([
                    Row(role: .speech, title: "Speech", status: "Ready", model: "Voxtral Mini 4B Realtime", trailing: "4.2 GB"),
                    Row(role: .polish, title: "Polish", status: "Ready", model: "Qwen3.5 4B", trailing: "2.9 GB"),
                ], footer: .memory(
                    segments: [.init(role: .speech, fraction: 4_509_715_661 / (32.0 * 1_073_741_824)),
                               .init(role: .polish, fraction: 3_113_851_290 / (32.0 * 1_073_741_824))],
                    amount: "7.1", caption: "of 32 GB memory")),
                showsTurnOffPolish: true)),
            ("polish off: its row stays and reads Off, no button", engines(speech: voxtral(), polish: qwen(.idle, memory: nil), polishEnabled: false), .medium, EnginesWidgetContent(
                layout: .rows([
                    Row(role: .speech, title: "Speech", status: "Ready", model: "Voxtral Mini 4B Realtime", trailing: "4.2 GB"),
                    Row(role: .polish, title: "Polish", model: "Off"),
                ], footer: .memory(
                    segments: [.init(role: .speech, fraction: 4_509_715_661 / (32.0 * 1_073_741_824))],
                    amount: "4.2", caption: "of 32 GB memory")),
                showsTurnOffPolish: false)),
            ("mixed: each row follows its engine's mode", engines(speech: voxtral(), polish: mistral), .small, EnginesWidgetContent(
                layout: .rows([
                    Row(role: .speech, title: "Speech", status: "Ready", model: "Voxtral 4B", trailing: "4.2 GB"),
                    Row(role: .polish, title: "Polish", status: "Mistral API", detail: "€0.01 today", detailTrailing: "€0.41 / 30 d"),
                ], footer: .memory(
                    segments: [.init(role: .speech, fraction: 4_509_715_661 / (32.0 * 1_073_741_824))],
                    amount: "4.2", caption: "4.2 of 32 GB memory")),
                showsTurnOffPolish: false)),
            ("Mistral API, small: spend replaces the rows", engines(speech: mistral, polish: mistral), .small, EnginesWidgetContent(
                titleDetail: "Mistral API",
                layout: .hostedSpend(amount: "€1.12", caption: "last 30 days", lines: [
                    .init(label: "Today", value: "€0.04"), .init(label: "Audio today", value: "18 min"),
                ]),
                showsTurnOffPolish: false)),
            ("Mistral API, medium: spend replaces the memory ring", engines(speech: mistral, polish: mistral), .medium, EnginesWidgetContent(
                layout: .rows([
                    Row(role: .speech, title: "Speech", model: "Mistral API · 18 min today", trailing: "€0.03"),
                    Row(role: .polish, title: "Polish", model: "Mistral API · 23 polishes today", trailing: "€0.01"),
                ], footer: .spend(amount: "€1.12", caption: "last 30 days")),
                showsTurnOffPolish: true)),
            ("External URL: the mode only", engines(speech: external, polish: external), .small, EnginesWidgetContent(
                layout: .rows([
                    Row(role: .speech, title: "Speech", status: "External URL"),
                    Row(role: .polish, title: "Polish", status: "External URL"),
                ], footer: .none(caption: "No local model in memory")),
                showsTurnOffPolish: false)),
            ("downloading: progress in place of the rows",
             engines(speech: voxtral(.downloading(downloadedBytes: 1_612_000_000, totalBytes: 2_600_000_000, paused: false), memory: nil), polish: qwen()),
             .small, EnginesWidgetContent(
                layout: .downloading(role: .speech, title: "Downloading the speech model", fraction: 0.62, caption: "1.6 of 2.6 GB · 62%"),
                showsTurnOffPolish: false)),
            ("stopped: one sentence, never the error, and the engine that still works",
             engines(speech: voxtral(.failed, memory: nil), polish: qwen()), .small, EnginesWidgetContent(
                layout: .stopped(title: "Speech engine stopped", detail: "Open localvoxtral to restart it.",
                                 other: Row(role: .polish, title: "Polish", status: "Ready · 2.9 GB")),
                showsTurnOffPolish: false)),
            ("the app quit: nothing left to answer the button",
             engines(speech: voxtral(.idle, memory: nil), polish: qwen(.idle, memory: nil), appRunning: false), .medium, EnginesWidgetContent(
                layout: .stopped(title: "localvoxtral is not running", detail: "Open it to start its engines.", other: nil),
                showsTurnOffPolish: false)),
        ]
        for (name, engines, size, expected) in cases {
            XCTAssertEqual(EnginesWidgetContent(engines, size: size, locale: locale), expected, name)
        }
    }

    /// A managed engine that is not loaded yet is waiting for a dictation,
    /// not broken.
    func testAnIdleEngineIsARowNotAStoppedEngine() {
        let content = EnginesWidgetContent(engines(speech: voxtral(.idle, memory: nil), polish: qwen()), size: .small, locale: locale)
        guard case let .rows(rows, _) = content.layout else { return XCTFail("\(content.layout)") }
        XCTAssertEqual(rows[0], Row(role: .speech, title: "Speech", status: "Not loaded", model: "Voxtral 4B"))
    }

    // MARK: Dictation

    private func day(_ daysAgo: Int, words: Int, dictations: Int, seconds: Double) -> WidgetSnapshot.Day {
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        return WidgetSnapshot.Day(start: start, words: words, dictations: dictations, dictatingSeconds: seconds)
    }

    private var dictation: WidgetSnapshot.Dictation {
        WidgetSnapshot.Dictation(
            days: [
                day(20, words: 5_000, dictations: 40, seconds: 2_000),
                day(3, words: 1_000, dictations: 10, seconds: 400),
                day(0, words: 1_284, dictations: 23, seconds: 543),
            ],
            today: WidgetSnapshot.PeriodDetail(topApps: [.init(name: "Ghostty", dictations: 20)], polishRan: 20, polishChanged: 12, medianPolishSeconds: 0.84),
            last7Days: WidgetSnapshot.PeriodDetail(
                topApps: [.init(name: "Ghostty", dictations: 64), .init(name: "Claude", dictations: 27),
                          .init(name: "Slack", dictations: 9), .init(name: "Mail", dictations: 2)],
                polishRan: 98, polishChanged: 61, medianPolishSeconds: 0.9,
                recurringFixes: [.init(heard: "cloud code", written: "Claude Code", dictations: 7),
                                 .init(heard: "swift ui", written: "SwiftUI", dictations: 4),
                                 .init(heard: "get hub", written: "GitHub", dictations: 3)]),
            last30Days: WidgetSnapshot.PeriodDetail()
        )
    }

    func testEachDictationPeriodCountsItsOwnDays() {
        let cases: [(DictationWidgetPeriod, String, String, String, String, String?)] = [
            // period, words, dictations, speaking, saved, wpm
            (.today, "1,284", "23", "9 min", "23 min", "142"),
            (.last7Days, "2,284", "33", "16 min", "41 min", "145"),
            (.last30Days, "7,284", "73", "49 min", "2 h 13 min", "149"),
        ]
        for (period, words, dictations, speaking, saved, wpm) in cases {
            let content = DictationWidgetContent(dictation, period: period, now: now, calendar: calendar, locale: locale)
            XCTAssertEqual(content.periodLabel, period.label)
            XCTAssertEqual(
                [content.words, content.dictations, content.speaking, content.saved, content.wordsPerMinute],
                [words, dictations, speaking, saved, wpm], "\(period)")
        }
    }

    /// The chart covers two weeks whatever the period, and a day the snapshot
    /// has no entry for is an empty bar.
    func testTheChartAlwaysCoversTwoWeeks() {
        for period in DictationWidgetPeriod.allCases {
            let content = DictationWidgetContent(dictation, period: period, now: now, calendar: calendar, locale: locale)
            XCTAssertEqual(content.chart.count, 14)
            XCTAssertEqual(content.chartStartLabel, "Sep 13")
            XCTAssertEqual(content.chart.last, .init(height: 1, isToday: true))
            XCTAssertEqual(content.chart[10], .init(height: 1_000.0 / 1_284.0, isToday: false))
            XCTAssertEqual(content.chart.filter { $0.height == 0 }.count, 12)
        }
    }

    /// A snapshot written yesterday reads as zero today: the widget counts
    /// days against the clock, not against when the app last wrote.
    func testTodayFollowsTheClock() {
        let tomorrow = now.addingTimeInterval(86_400)
        let content = DictationWidgetContent(dictation, period: .today, now: tomorrow, calendar: calendar, locale: locale)
        XCTAssertEqual([content.words, content.dictations, content.saved], ["0", "0", "0 s"])
        XCTAssertNil(content.wordsPerMinute)
    }

    func testTheLargeSizeListsWhatInsightsShows() {
        let content = DictationWidgetContent(dictation, period: .last7Days, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(content.apps, [
            .init(name: "Ghostty", dictations: "64", share: 1),
            .init(name: "Claude", dictations: "27", share: 27.0 / 64),
            .init(name: "Slack", dictations: "9", share: 9.0 / 64),
        ])
        XCTAssertEqual(content.polish, "Changed 61 of 98 · median 0.9 s")
        XCTAssertEqual(content.fixes, [
            .init(heard: "cloud code", written: "Claude Code", times: "×7"),
            .init(heard: "swift ui", written: "SwiftUI", times: "×4"),
        ])
        let empty = DictationWidgetContent(dictation, period: .last30Days, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(empty.polish, "No dictation polished")
        XCTAssertEqual(empty.apps, [])
    }

    func testDaysGroupSamplesByLocalDayAndCapASleptDictation() {
        let start = calendar.startOfDay(for: now)
        let samples = [
            WidgetSnapshot.DictationSample(startedAt: start.addingTimeInterval(60), finishedAt: start.addingTimeInterval(90), words: 10, polishingSeconds: 2),
            WidgetSnapshot.DictationSample(startedAt: start.addingTimeInterval(120), finishedAt: start.addingTimeInterval(120 + 7_200), words: 5, polishingSeconds: nil),
            WidgetSnapshot.DictationSample(startedAt: start.addingTimeInterval(-60), finishedAt: start.addingTimeInterval(-30), words: 3, polishingSeconds: nil),
            // Older than the 30 days kept.
            WidgetSnapshot.DictationSample(startedAt: start.addingTimeInterval(-31 * 86_400), finishedAt: start.addingTimeInterval(-31 * 86_400 + 5), words: 99, polishingSeconds: nil),
        ]
        XCTAssertEqual(WidgetSnapshot.days(from: samples, now: now, calendar: calendar), [
            WidgetSnapshot.Day(start: start.addingTimeInterval(-86_400), words: 3, dictations: 1, dictatingSeconds: 30),
            WidgetSnapshot.Day(start: start, words: 15, dictations: 2, dictatingSeconds: 28 + 3_600),
        ])
    }

    // MARK: Vocabulary

    func testVocabularyWithoutATrendShowsAnEmptyState() {
        XCTAssertEqual(
            VocabularyWidgetContent(WidgetSnapshot.Vocabulary(weeklyShares: [nil, nil], termCount: 0), locale: locale).layout,
            .empty(title: "Nothing learned yet", detail: "Terms show up here as the app learns the words you use."))
        XCTAssertEqual(
            VocabularyWidgetContent(WidgetSnapshot.Vocabulary(weeklyShares: [nil, nil], termCount: 14, termsLearnedThisWeek: ["herdr"]), locale: locale).layout,
            .empty(title: "14 terms learned", detail: "The trend shows once a week has five dictations with your terms."))
    }

    func testVocabularyTrendShowsTheLastEightWeeks() {
        let shares: [Double?] = [0.5, 0.6, nil, 0.71, 0.74, 0.79, 0.82, 0.85, 0.88, 0.90, 0.93]
        let terms = ["herdr", "polishd", "OptiQ", "cmux", "SwiftPM", "xctest", "Metal", "speechd"]
        let content = VocabularyWidgetContent(WidgetSnapshot.Vocabulary(weeklyShares: shares, termCount: 412, termsLearnedThisWeek: terms), locale: locale)
        XCTAssertEqual(content.layout, .trend(.init(
            share: "93%", shareCaption: "learned terms spelled right this week",
            weeklyShares: Array(shares.suffix(8)), firstShare: "71%",
            countLine: "412 terms · +8 this week", total: "412 total",
            newTerms: Array(terms.prefix(6)), moreTerms: "+2 more")))
    }

    func testAWeekTooQuietToMeasureDoesNotClaimThisWeek() {
        let content = VocabularyWidgetContent(WidgetSnapshot.Vocabulary(weeklyShares: [0.8, 0.9, nil], termCount: 3), locale: locale)
        guard case let .trend(trend) = content.layout else { return XCTFail("\(content.layout)") }
        XCTAssertEqual(trend.share, "90%")
        XCTAssertEqual(trend.shareCaption, "learned terms spelled right in the last measured week")
        XCTAssertNil(trend.moreTerms)
    }

    // MARK: Last dictation

    private func snapshot(historyKept: Bool, last: WidgetSnapshot.LastDictation?) -> WidgetSnapshot {
        WidgetSnapshot(
            writtenAt: now,
            engines: engines(speech: voxtral(), polish: qwen()),
            dictation: WidgetSnapshot.Dictation(),
            vocabulary: WidgetSnapshot.Vocabulary(),
            historyKept: historyKept,
            lastDictation: last
        )
    }

    private let last = WidgetSnapshot.LastDictation(
        text: "Run the core tests on Linux first.", appName: "Ghostty",
        finishedAt: Date(timeIntervalSince1970: 1_790_434_680), words: 7, polishRan: true, polishSeconds: 0.84)

    /// With retention "Don't keep" the text never reaches the file, whatever
    /// the caller passes.
    func testWithHistoryOffTheSnapshotHoldsNoText() throws {
        let off = snapshot(historyKept: false, last: last)
        XCTAssertNil(off.lastDictation)
        let written = try JSONEncoder().encode(off)
        XCTAssertFalse(String(decoding: written, as: UTF8.self).contains("core tests"))
        XCTAssertEqual(
            LastDictationWidgetContent(off, locale: locale).layout,
            .message(title: "History is off", detail: "Keep history in localvoxtral to see your last dictation here."))
        XCTAssertFalse(LastDictationWidgetContent(off, locale: locale).showsCopy)
    }

    func testLastDictation() {
        XCTAssertEqual(LastDictationWidgetContent(snapshot(historyKept: true, last: last), locale: locale).layout, .dictation(.init(
            text: "Run the core tests on Linux first.", title: "Ghostty", finishedAt: last.finishedAt,
            badge: "Polished", footer: "7 words · polish 0.8 s")))
        var live = last
        live.appName = nil
        live.polishRan = false
        live.polishSeconds = nil
        XCTAssertEqual(LastDictationWidgetContent(snapshot(historyKept: true, last: live), locale: locale).layout, .dictation(.init(
            text: live.text, title: "Last dictation", finishedAt: last.finishedAt, badge: nil, footer: "7 words")))
        XCTAssertEqual(
            LastDictationWidgetContent(snapshot(historyKept: true, last: nil), locale: locale).layout,
            .message(title: "No dictation yet", detail: "Your last dictation shows here, with a button to copy it."))
    }

    func testTheSnapshotRoundTripsThroughItsFile() throws {
        let original = snapshot(historyKept: true, last: last)
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(WidgetSnapshot.self, from: JSONEncoder().encode(original)), original)
    }
}
