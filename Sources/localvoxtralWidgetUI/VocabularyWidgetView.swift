import SwiftUI
import WidgetKit
import localvoxtralCore

/// The Vocabulary widget: whether the app spells the speaker's terms right,
/// week over week, and what it learned this week (#630).
package struct VocabularyWidgetView: View {
    let content: VocabularyWidgetContent
    let size: WidgetSize

    package init(content: VocabularyWidgetContent, size: WidgetSize) {
        self.content = content
        self.size = size
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(symbol: "character.book.closed", title: "Vocabulary")
            switch content.layout {
            case let .empty(title, detail):
                Spacer(minLength: 6)
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).padding(.top, 3)
            case let .trend(trend):
                if size == .small { small(trend) } else { medium(trend) }
            }
        }
    }

    private func small(_ trend: VocabularyWidgetContent.Trend) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(trend.share).font(.system(size: 30, weight: .bold)).monospacedDigit().padding(.top, 6)
            Text(trend.shareCaption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 4)
            Sparkline(shares: trend.weeklyShares).frame(height: 26)
            Text(trend.countLine).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().padding(.top, 5).lineLimit(1)
        }
    }

    private func medium(_ trend: VocabularyWidgetContent.Trend) -> some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Spacer(minLength: 0)
                ShareBars(shares: trend.weeklyShares).frame(height: 80)
                HStack {
                    Text(trend.firstShare)
                    Spacer()
                    Text("\(trend.weeklyShares.count) weeks")
                    Spacer()
                    Text(trend.share).foregroundStyle(.primary).fontWeight(.semibold)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                Text("Learned terms spelled right").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(width: 168)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("New this week").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(trend.total).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                if trend.newTerms.isEmpty {
                    Text("None yet").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    TermChips(terms: trend.newTerms)
                }
                if let more = trend.moreTerms {
                    Text(more).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        }
    }
}

/// The weekly shares as a line; a week too quiet to measure is a gap.
struct Sparkline: View {
    let shares: [Double?]

    var body: some View {
        GeometryReader { proxy in
            let points = Self.points(shares, in: proxy.size)
            Path { path in
                var drawing = false
                for point in points {
                    guard let point else { drawing = false; continue }
                    if drawing { path.addLine(to: point) } else { path.move(to: point) }
                    drawing = true
                }
            }
            .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .widgetAccentable()
            if let last = points.compactMap({ $0 }).last {
                Circle().fill(.tint).frame(width: 6, height: 6).position(last).widgetAccentable()
            }
        }
    }

    static func points(_ shares: [Double?], in size: CGSize) -> [CGPoint?] {
        let known = shares.compactMap { $0 }
        let low = (known.min() ?? 0) - 0.05
        let high = (known.max() ?? 1) + 0.01
        let span = max(high - low, 0.01)
        let step = shares.count > 1 ? size.width / CGFloat(shares.count - 1) : 0
        return shares.enumerated().map { index, share in
            share.map { CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(($0 - low) / span))) }
        }
    }
}

/// The weekly shares as bars, this week solid.
struct ShareBars: View {
    let shares: [Double?]

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                    let isLast = index == shares.count - 1
                    RoundedRectangle(cornerRadius: 3)
                        .fill(share == nil ? AnyShapeStyle(.quaternary)
                              : isLast ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.4)))
                        .frame(height: max(3, proxy.size.height * (share ?? 0)))
                        .widgetAccentable(isLast)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Terms as chips that wrap onto a second line.
struct TermChips: View {
    let terms: [String]

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(terms, id: \.self) { term in
                Text(term)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        let rows = arrange(subviews, width: bounds.width)
        // A chip that does not fit on the two lines is moved out of the
        // widget, where its container clips it, instead of drawing over the
        // others.
        let placed = Set(rows.flatMap(\.indices))
        for index in subviews.indices where !placed.contains(index) {
            subviews[index].place(at: CGPoint(x: bounds.maxX + 10_000, y: bounds.minY), proposal: .zero)
        }
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Drops what does not fit on two lines.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                guard rows.count < 2 else { break }
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
