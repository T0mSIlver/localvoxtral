import AppIntents
import SwiftUI
import WidgetKit
import localvoxtralCore
import localvoxtralWidgetUI

/// The desktop widgets (#630). Each reads the one snapshot file the app
/// writes and maps it with the pure `…WidgetContent` types from the core.
/// The app reloads the timelines when what they show changes; the timelines
/// themselves only carry the clock forward.
@main
struct LocalvoxtralWidgets: WidgetBundle {
    var body: some Widget {
        EnginesWidget()
        DictationWidget()
        VocabularyWidget()
        LastDictationWidget()
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

extension WidgetFamily {
    var size: WidgetSize {
        switch self {
        case .systemSmall: return .small
        case .systemLarge, .systemExtraLarge: return .large
        default: return .medium
        }
    }
}

private func nextMidnight(after date: Date) -> Date {
    Calendar.current.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
        ?? date.addingTimeInterval(86_400)
}

/// Static widgets: one entry now, another at midnight so "today" rolls over.
struct SnapshotProvider: TimelineProvider {
    /// Entries a minute apart for the first hour, so an age like "2 min
    /// ago" stays true without the app writing anything.
    var minuteEntries = false

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: WidgetSampleData.snapshot(now: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let now = Date()
        completion(SnapshotEntry(date: now, snapshot: SnapshotFile.read() ?? (context.isPreview ? WidgetSampleData.snapshot(now: now) : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = SnapshotFile.read()
        var dates = [now]
        if minuteEntries {
            dates += (1...59).map { now.addingTimeInterval(Double($0) * 60) }
        }
        let midnight = nextMidnight(after: now)
        completion(Timeline(
            entries: dates.filter { $0 < midnight }.map { SnapshotEntry(date: $0, snapshot: snapshot) }
                + [SnapshotEntry(date: midnight, snapshot: snapshot)],
            policy: minuteEntries ? .after(now.addingTimeInterval(3_600)) : .after(midnight)
        ))
    }
}

struct PeriodEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let period: DictationWidgetPeriod
}

struct PeriodProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PeriodEntry {
        PeriodEntry(date: .now, snapshot: WidgetSampleData.snapshot(now: .now), period: .today)
    }

    func snapshot(for configuration: DictationPeriodIntent, in context: Context) async -> PeriodEntry {
        let now = Date()
        return PeriodEntry(
            date: now,
            snapshot: SnapshotFile.read() ?? (context.isPreview ? WidgetSampleData.snapshot(now: now) : nil),
            period: configuration.period.period
        )
    }

    func timeline(for configuration: DictationPeriodIntent, in context: Context) async -> Timeline<PeriodEntry> {
        let now = Date()
        let snapshot = SnapshotFile.read()
        let midnight = nextMidnight(after: now)
        return Timeline(
            entries: [now, midnight].map { PeriodEntry(date: $0, snapshot: snapshot, period: configuration.period.period) },
            policy: .after(midnight)
        )
    }
}

struct EnginesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.Kind.engines.rawValue, provider: SnapshotProvider()) { entry in
            EnginesEntryView(entry: entry)
        }
        .configurationDisplayName("Engines")
        .description("The speech and polish engines: state, and memory or spend.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct EnginesEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                EnginesWidgetView(content: EnginesWidgetContent(snapshot.engines, size: family.size), size: family.size) {
                    Button(intent: TurnOffPolishIntent()) {
                        Text("Turn off polish")
                    }
                    .buttonStyle(WidgetPillButtonStyle())
                }
            } else {
                WidgetMessageView(symbol: "cpu", title: "Engines")
            }
        }
        .containerBackground(.background, for: .widget)
    }
}

struct DictationWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetShared.Kind.dictation.rawValue, intent: DictationPeriodIntent.self, provider: PeriodProvider()) { entry in
            DictationEntryView(entry: entry)
        }
        .configurationDisplayName("Dictation")
        .description("Words, dictations and time saved over typing.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct DictationEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PeriodEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                DictationWidgetView(
                    content: DictationWidgetContent(snapshot.dictation, period: entry.period, now: entry.date, calendar: .current),
                    size: family.size
                )
            } else {
                WidgetMessageView(symbol: "mic", title: "Dictation")
            }
        }
        .containerBackground(.background, for: .widget)
    }
}

struct VocabularyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.Kind.vocabulary.rawValue, provider: SnapshotProvider()) { entry in
            VocabularyEntryView(entry: entry)
        }
        .configurationDisplayName("Vocabulary")
        .description("How often your learned terms come out right, week over week.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct VocabularyEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                VocabularyWidgetView(content: VocabularyWidgetContent(snapshot.vocabulary), size: family.size)
            } else {
                WidgetMessageView(symbol: "character.book.closed", title: "Vocabulary")
            }
        }
        .containerBackground(.background, for: .widget)
    }
}

struct LastDictationWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.Kind.lastDictation.rawValue, provider: SnapshotProvider(minuteEntries: true)) { entry in
            LastDictationEntryView(entry: entry)
        }
        .configurationDisplayName("Last Dictation")
        .description("Your last dictation, with a button to copy it.")
        .supportedFamilies([.systemMedium])
    }
}

struct LastDictationEntryView: View {
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                LastDictationWidgetView(content: LastDictationWidgetContent(snapshot), now: entry.date) {
                    Button(intent: CopyLastDictationIntent()) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(WidgetPillButtonStyle())
                }
            } else {
                WidgetMessageView(symbol: "text.bubble", title: "Last dictation")
            }
        }
        .containerBackground(.background, for: .widget)
    }
}
