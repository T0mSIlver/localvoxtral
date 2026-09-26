import AppKit
import SwiftUI
import XCTest

@testable import localvoxtral
import localvoxtralWidgetUI

/// The desktop widgets (#630): every widget, size and state, light and dark.
/// The views are the extension's own, fed the core's content for made-up
/// snapshots; the frame and background stand in for WidgetKit's container.
extension ViewSnapshotTests {
    private static let gib: UInt64 = 1_073_741_824

    private var widgetCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Saturday 2026-09-26 15:00 UTC.
    private var widgetNow: Date { Date(timeIntervalSince1970: 1_790_434_800) }
    private var widgetLocale: Locale { Locale(identifier: "en_US") }

    func testEnginesWidget() throws {
        let voxtral = WidgetSnapshot.Engine(
            mode: .managedLocal, shortModelName: "Voxtral 4B", modelName: "Voxtral Mini 4B Realtime",
            state: .ready, memoryBytes: 42 * Self.gib / 10)
        let qwen = WidgetSnapshot.Engine(
            mode: .managedLocal, shortModelName: "Qwen3.5 4B", modelName: "Qwen3.5 4B",
            state: .ready, memoryBytes: 29 * Self.gib / 10)
        let mistral = WidgetSnapshot.Engine(mode: .mistralAPI, state: .ready)
        let external = WidgetSnapshot.Engine(mode: .externalURL, state: .ready)
        var downloading = voxtral
        downloading.state = .downloading(downloadedBytes: 1_612_000_000, totalBytes: 2_600_000_000, paused: false)
        downloading.memoryBytes = nil
        var failed = voxtral
        failed.state = .failed
        failed.memoryBytes = nil
        var idle = qwen
        idle.state = .idle
        idle.memoryBytes = nil

        func engines(_ speech: WidgetSnapshot.Engine, _ polish: WidgetSnapshot.Engine, polishEnabled: Bool = true, appRunning: Bool = true) -> WidgetSnapshot.Engines {
            WidgetSnapshot.Engines(
                speech: speech, polish: polish, polishEnabled: polishEnabled, physicalMemoryBytes: 32 * Self.gib,
                mistral: WidgetSnapshot.MistralSpend(
                    speechTodayEUR: 0.03, polishTodayEUR: 0.01, speechLast30DaysEUR: 0.71, polishLast30DaysEUR: 0.41,
                    audioSecondsToday: 18 * 60, polishesToday: 23),
                appRunning: appRunning)
        }
        let states: [(String, WidgetSnapshot.Engines)] = [
            ("local", engines(voxtral, qwen)),
            ("polish-off", engines(voxtral, idle, polishEnabled: false)),
            ("mixed", engines(voxtral, mistral)),
            ("mistral", engines(mistral, mistral)),
            ("external", engines(external, external)),
            ("downloading", engines(downloading, qwen)),
            ("stopped", engines(failed, qwen)),
            ("app-quit", engines(idle, idle, appRunning: false)),
        ]
        for (state, snapshot) in states {
            for size in [WidgetSize.small, .medium] {
                try recordWidget(name: "widget-engines-\(size.rawValue)-\(state)", size: size) {
                    EnginesWidgetView(content: EnginesWidgetContent(snapshot, size: size, locale: widgetLocale), size: size) {
                        Button("Turn off polish") {}.buttonStyle(WidgetPillButtonStyle())
                    }
                }
            }
        }
    }

    func testDictationWidget() throws {
        let snapshot = WidgetSampleData.snapshot(now: widgetNow, calendar: widgetCalendar)
        for size in WidgetSize.allCases {
            for period in DictationWidgetPeriod.allCases {
                let content = DictationWidgetContent(
                    snapshot.dictation, period: period, now: widgetNow, calendar: widgetCalendar, locale: widgetLocale)
                try recordWidget(name: "widget-dictation-\(size.rawValue)-\(period.rawValue)", size: size) {
                    DictationWidgetView(content: content, size: size)
                }
            }
        }
        // No dictation at all: the first day.
        let empty = DictationWidgetContent(
            WidgetSnapshot.Dictation(), period: .last7Days, now: widgetNow, calendar: widgetCalendar, locale: widgetLocale)
        try recordWidget(name: "widget-dictation-large-empty", size: .large) {
            DictationWidgetView(content: empty, size: .large)
        }
    }

    func testVocabularyWidget() throws {
        let states: [(String, WidgetSnapshot.Vocabulary)] = [
            ("trend", WidgetSnapshot.Vocabulary(
                weeklyShares: [0.71, 0.74, nil, 0.82, 0.85, 0.88, 0.90, 0.93], termCount: 412,
                termsLearnedThisWeek: ["SwiftPM", "xctest", "WidgetKit", "notarize", "Metal", "speechd", "herdr", "polishd"])),
            ("empty", WidgetSnapshot.Vocabulary()),
            ("no-trend-yet", WidgetSnapshot.Vocabulary(weeklyShares: [nil, nil], termCount: 14, termsLearnedThisWeek: ["SwiftPM"])),
        ]
        for (state, vocabulary) in states {
            for size in [WidgetSize.small, .medium] {
                try recordWidget(name: "widget-vocabulary-\(size.rawValue)-\(state)", size: size) {
                    VocabularyWidgetView(content: VocabularyWidgetContent(vocabulary, locale: widgetLocale), size: size)
                }
            }
        }
    }

    func testLastDictationWidget() throws {
        var snapshot = WidgetSampleData.snapshot(now: widgetNow, calendar: widgetCalendar)
        let copy = { Button {} label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(WidgetPillButtonStyle()) }
        let dictation = LastDictationWidgetContent(snapshot, locale: widgetLocale)
        try recordWidget(name: "widget-last-dictation-medium", size: .medium) {
            LastDictationWidgetView(content: dictation, now: widgetNow, copy: copy)
        }
        // What the lock screen shows: macOS redacts privacy-sensitive views.
        try recordWidget(name: "widget-last-dictation-medium-locked", size: .medium) {
            LastDictationWidgetView(content: dictation, now: widgetNow, copy: copy)
                .redacted(reason: .privacy)
        }
        snapshot.lastDictation = nil
        try recordWidget(name: "widget-last-dictation-medium-none", size: .medium) {
            LastDictationWidgetView(content: LastDictationWidgetContent(snapshot, locale: widgetLocale), now: widgetNow, copy: copy)
        }
        snapshot.historyKept = false
        try recordWidget(name: "widget-last-dictation-medium-history-off", size: .medium) {
            LastDictationWidgetView(content: LastDictationWidgetContent(snapshot, locale: widgetLocale), now: widgetNow, copy: copy)
        }
    }

    /// One widget in both appearances, at its family's size, on a card like
    /// the desktop's.
    private func recordWidget<V: View>(name: String, size: WidgetSize, @ViewBuilder _ view: () -> V) throws {
        let frame = WidgetStyle.size(size)
        let card = view()
            .padding(14)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(nsColor: .windowBackgroundColor)))
            .padding(12)
            .tint(.accentColor)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let url = try ViewSnapshot.record(
                card, name: "\(name)-\(suffix)", width: frame.width + 24, height: frame.height + 24, appearance: appearance)
            XCTAssertNotNil(NSImage(contentsOf: url), "\(name)-\(suffix).png does not read back")
        }
    }
}
