import SwiftUI
import WidgetKit
import localvoxtralCore

/// The Engines widget: each engine's state, and its memory or spend (#630).
/// `turnOffPolish` is the extension's App Intent button; previews and
/// snapshots pass a plain one.
package struct EnginesWidgetView<TurnOffPolish: View>: View {
    let content: EnginesWidgetContent
    let size: WidgetSize
    let turnOffPolish: TurnOffPolish

    package init(content: EnginesWidgetContent, size: WidgetSize, @ViewBuilder turnOffPolish: () -> TurnOffPolish) {
        self.content = content
        self.size = size
        self.turnOffPolish = turnOffPolish()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(symbol: "cpu", title: content.title, detail: content.titleDetail)
            switch content.layout {
            case let .rows(rows, footer):
                if size == .small {
                    smallRows(rows, footer: footer)
                } else {
                    mediumRows(rows, footer: footer)
                }
            case let .hostedSpend(amount, caption, lines):
                hostedSpend(amount: amount, caption: caption, lines: lines)
            case let .downloading(role, title, fraction, caption):
                downloading(role: role, title: title, fraction: fraction, caption: caption)
            case let .stopped(title, detail, other):
                stopped(title: title, detail: detail, other: other)
            }
        }
    }

    // MARK: Rows

    private func smallRows(_ rows: [EnginesWidgetContent.Row], footer: EnginesWidgetContent.Footer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows, id: \.role) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            EngineMark(role: row.role, size: 9)
                            Text(row.status.map { "\(row.title) · \($0)" } ?? row.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(row.model ?? row.detail ?? "")
                            Spacer(minLength: 4)
                            Text(row.trailing ?? row.detailTrailing ?? "")
                                .foregroundStyle(.secondary)
                        }
                        // A spend line carries two amounts in the same width.
                        .font(.system(size: row.detail == nil ? 12 : 11, weight: .medium))
                        .minimumScaleFactor(0.8)
                        .monospacedDigit()
                    }
                    .lineLimit(1)
                }
            }
            .padding(.top, 8)
            Spacer(minLength: 6)
            smallFooter(footer)
        }
    }

    @ViewBuilder
    private func smallFooter(_ footer: EnginesWidgetContent.Footer) -> some View {
        switch footer {
        case let .memory(segments, _, caption):
            VStack(alignment: .leading, spacing: 4) {
                MemoryBar(segments: segments)
                Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        case let .spend(amount, caption):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(amount).font(.system(size: 16, weight: .bold)).monospacedDigit()
                Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case let .none(caption):
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func mediumRows(_ rows: [EnginesWidgetContent.Row], footer: EnginesWidgetContent.Footer) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows, id: \.role) { row in
                    HStack(alignment: .top, spacing: 6) {
                        EngineMark(role: row.role, size: 12)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(row.title).font(.system(size: 12, weight: .semibold))
                                if let status = row.status {
                                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            if let line = row.model ?? row.detail {
                                Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                        Spacer(minLength: 4)
                        if let trailing = row.trailing ?? row.detailTrailing {
                            Text(trailing).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        }
                    }
                    .lineLimit(1)
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                switch footer {
                case let .memory(segments, amount, caption):
                    MemoryRing(segments: segments, amount: amount)
                        .frame(width: 72, height: 72)
                    Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                case let .spend(amount, caption):
                    Spacer(minLength: 0)
                    Text(amount).font(.system(size: 22, weight: .bold)).monospacedDigit()
                    Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
                case let .none(caption):
                    Spacer(minLength: 0)
                    Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
                if content.showsTurnOffPolish {
                    turnOffPolish
                }
            }
            .frame(width: 112)
        }
    }

    // MARK: Other layouts

    private func hostedSpend(amount: String, caption: String, lines: [EnginesWidgetContent.Line]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 4)
            Text(amount).font(.system(size: 30, weight: .bold)).monospacedDigit()
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Divider()
            VStack(spacing: 3) {
                ForEach(lines, id: \.label) { line in
                    HStack {
                        Text(line.label).foregroundStyle(.secondary)
                        Spacer()
                        Text(line.value).monospacedDigit()
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(.top, 6)
        }
    }

    private func downloading(role: WidgetSnapshot.EngineRole, title: String, fraction: Double?, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 4)
            HStack(alignment: .top, spacing: 5) {
                EngineMark(role: role, size: 12)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            }
            if let fraction {
                ProgressView(value: fraction).tint(WidgetStyle.color(role))
            } else {
                ProgressView(value: 0).tint(WidgetStyle.color(role))
            }
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 0)
        }
    }

    private func stopped(title: String, detail: String, other: EnginesWidgetContent.Row?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 6)
            if let other {
                HStack(spacing: 4) {
                    EngineMark(role: other.role, size: 10)
                    Text(other.status.map { "\(other.title) · \($0)" } ?? other.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }
        }
    }
}

/// The Mac's memory as a bar, each engine's share filled its own way.
struct MemoryBar: View {
    let segments: [EnginesWidgetContent.MemorySegment]

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                ForEach(segments, id: \.role) { segment in
                    EngineFill(role: segment.role)
                        .frame(width: max(2, proxy.size.width * segment.fraction))
                }
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}

/// The medium widget's ring: memory used, each engine an arc.
struct MemoryRing: View {
    let segments: [EnginesWidgetContent.MemorySegment]
    let amount: String

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 8)
            ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(
                        WidgetStyle.color(arc.role),
                        style: StrokeStyle(lineWidth: 8, lineCap: .butt, dash: arc.role == .polish ? [2.5, 1.5] : [])
                    )
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
            }
            VStack(spacing: -2) {
                Text(amount).font(.system(size: 17, weight: .bold)).monospacedDigit()
                Text("GB").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private var arcs: [(role: WidgetSnapshot.EngineRole, start: Double, end: Double)] {
        var start = 0.0
        return segments.map { segment in
            // A hairline gap between the arcs keeps them apart in one color.
            let end = min(1, start + segment.fraction)
            defer { start = end + 0.012 }
            return (segment.role, start, max(start, end - 0.004))
        }
    }
}
