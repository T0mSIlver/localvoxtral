import SwiftUI
import WidgetKit
import localvoxtralCore

/// The Dictation widget: totals for the period picked in Edit Widget, a
/// two-week chart on medium, and the Insights pane's lists on large (#630).
package struct DictationWidgetView: View {
    let content: DictationWidgetContent
    let size: WidgetSize

    package init(content: DictationWidgetContent, size: WidgetSize) {
        self.content = content
        self.size = size
    }

    package var body: some View {
        switch size {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    private var header: some View {
        WidgetHeader(symbol: "mic", title: content.periodLabel)
    }

    private var saved: some View {
        Text("≈ \(content.saved) saved")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(WidgetStyle.savedColor)
            .monospacedDigit()
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(content.words)
                .font(.system(size: 32, weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.top, 8)
            Text("words dictated").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("\(content.dictations) dictations · \(content.speaking)")
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
            saved
        }
    }

    private var medium: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Text(content.words)
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.top, 8)
                Text("words").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let wpm = content.wordsPerMinute {
                    (Text(wpm).fontWeight(.semibold) + Text(" wpm").foregroundColor(.secondary))
                        .font(.system(size: 12))
                        .monospacedDigit()
                }
                saved
            }
            .frame(width: 118, alignment: .leading)
            VStack(spacing: 5) {
                WordsChart(bars: content.chart)
                HStack {
                    Text(content.chartStartLabel)
                    Spacer()
                    Text("Today")
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    StatTile(value: content.dictations, label: "dictations")
                    StatTile(value: content.words, label: "words")
                }
                GridRow {
                    StatTile(value: content.speaking, label: "speaking")
                    StatTile(value: content.saved, label: "saved over typing", highlighted: true)
                }
            }
            if !content.apps.isEmpty {
                section("Where you dictate") {
                    ForEach(Array(content.apps.enumerated()), id: \.offset) { _, app in
                        HStack(spacing: 8) {
                            Text(app.name).frame(width: 70, alignment: .leading).lineLimit(1)
                            GeometryReader { proxy in
                                Capsule().fill(.quaternary)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(.tint)
                                            .frame(width: max(4, proxy.size.width * app.share))
                                            .widgetAccentable()
                                    }
                            }
                            .frame(height: 7)
                            Text(app.dictations).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                        }
                        .font(.system(size: 11))
                        .monospacedDigit()
                    }
                }
            }
            section("Polish") {
                Text(content.polish).font(.system(size: 11)).monospacedDigit()
            }
            if !content.fixes.isEmpty {
                section("Recurring fixes") {
                    ForEach(Array(content.fixes.enumerated()), id: \.offset) { _, fix in
                        HStack(spacing: 5) {
                            Text(fix.heard).foregroundStyle(.secondary)
                            Text("→").foregroundStyle(.secondary)
                            Text(fix.written)
                            Spacer(minLength: 4)
                            Text(fix.times).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// Words per day for two weeks; today's bar solid, the others lighter.
struct WordsChart: View {
    let bars: [DictationWidgetContent.Bar]

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bar.height == 0 ? AnyShapeStyle(.quaternary)
                              : bar.isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.4)))
                        .frame(height: max(3, proxy.size.height * bar.height))
                        .widgetAccentable(bar.isToday)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(highlighted ? AnyShapeStyle(WidgetStyle.savedColor) : AnyShapeStyle(.primary))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.6)))
    }
}
