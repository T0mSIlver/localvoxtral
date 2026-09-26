import SwiftUI
import localvoxtralCore

/// What a widget shows before the app has written its first snapshot.
package struct WidgetMessageView: View {
    let symbol: String
    let title: String

    package init(symbol: String, title: String) {
        self.symbol = symbol
        self.title = title
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(symbol: symbol, title: title)
            Spacer(minLength: 6)
            Text("Open localvoxtral").font(.system(size: 15, weight: .semibold))
            Text("The widget fills in once the app has run.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.top, 3)
            Spacer(minLength: 0)
        }
    }
}

/// A made-up snapshot for WidgetKit's placeholders and the gallery before
/// the app has run. Nothing in it is anyone's data.
package enum WidgetSampleData {
    package static func snapshot(now: Date, calendar: Calendar = .current) -> WidgetSnapshot {
        let today = calendar.startOfDay(for: now)
        let dailyWords = [0, 1180, 1420, 960, 1330, 1100, 180, 0, 1510, 1210, 1380, 940, 1260, 1284]
        let days = dailyWords.enumerated().compactMap { index, words -> WidgetSnapshot.Day? in
            guard words > 0, let start = calendar.date(byAdding: .day, value: index - (dailyWords.count - 1), to: today)
            else { return nil }
            return WidgetSnapshot.Day(start: start, words: words, dictations: words / 56, dictatingSeconds: Double(words) / 142 * 60)
        }
        let week = WidgetSnapshot.PeriodDetail(
            topApps: [.init(name: "Terminal", dictations: 64), .init(name: "Notes", dictations: 27), .init(name: "Mail", dictations: 9)],
            polishRan: 98, polishChanged: 61, medianPolishSeconds: 0.9,
            recurringFixes: [.init(heard: "swift ui", written: "SwiftUI", dictations: 4)]
        )
        let gib: UInt64 = 1_073_741_824
        return WidgetSnapshot(
            writtenAt: now,
            engines: WidgetSnapshot.Engines(
                speech: .init(mode: .managedLocal, shortModelName: "Voxtral 4B", modelName: "Voxtral Mini 4B Realtime", state: .ready, memoryBytes: 42 * gib / 10),
                polish: .init(mode: .managedLocal, shortModelName: "Qwen3.5 4B", modelName: "Qwen3.5 4B", state: .ready, memoryBytes: 29 * gib / 10),
                polishEnabled: true,
                physicalMemoryBytes: 32 * gib
            ),
            dictation: WidgetSnapshot.Dictation(days: days, today: week, last7Days: week, last30Days: week),
            vocabulary: WidgetSnapshot.Vocabulary(
                weeklyShares: [0.71, 0.74, 0.79, 0.82, 0.85, 0.88, 0.90, 0.93],
                termCount: 412,
                termsLearnedThisWeek: ["SwiftPM", "xctest", "WidgetKit", "notarize"]
            ),
            historyKept: true,
            lastDictation: WidgetSnapshot.LastDictation(
                text: "Run the core tests on Linux first, then push the draft.",
                appName: "Terminal", finishedAt: now.addingTimeInterval(-120), words: 11, polishRan: true, polishSeconds: 0.8)
        )
    }
}
