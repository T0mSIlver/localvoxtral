import AppKit
import SwiftUI

private final class RoundedVisualEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat = 12 {
        didSet {
            guard oldValue != cornerRadius else { return }
            previousMaskSize = .zero
            updateMask()
        }
    }

    private var previousMaskSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        updateMask()
    }

    private func updateMask() {
        layer?.cornerRadius = cornerRadius
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard size != previousMaskSize else { return }
        previousMaskSize = size
        maskImage = Self.makeMaskImage(size: size, cornerRadius: cornerRadius)
    }

    private static func makeMaskImage(size: CGSize, cornerRadius: CGFloat) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.white.setFill()
        NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: size),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        ).fill()
        image.unlockFocus()
        return image
    }
}

private struct RoundedMaterialBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> RoundedVisualEffectView {
        let view = RoundedVisualEffectView(frame: .zero)
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: RoundedVisualEffectView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

struct DictationOverlayView: View {
    let phase: OverlayBufferPhase
    let text: String
    let errorMessage: String?
    let secureInputActive: Bool
    /// Sizing shared with `DictationOverlayController`'s panel measurement —
    /// see `OverlayLayoutMetrics` for why the two must stay in lockstep.
    let metrics: OverlayLayoutMetrics
    var polished: Bool = false
    /// What was on screen before polish replaced it: the words that differ
    /// are marked (#1074).
    var polishedFrom: String? = nil
    /// The polish request is out: "Polishing", and a band sweeps the words.
    var polishing: Bool = false
    /// Drives the level bars while listening; nil draws them at rest.
    var micLevel: OverlayMicLevel? = nil
    var motion: OverlayMotion = .system
    /// What this dictation's Claude Code session join resolved to. `.hidden`
    /// renders nothing — see `OverlayClaudeJoinBadge`.
    var claudeJoin: OverlayClaudeJoinBadge = .hidden
    /// Where the words go at stop (#840). When shown, it takes the join
    /// badge's place: the first pill carries the join.
    var destinations: OverlayDestinationStrip? = nil
    /// The one draft a review dictation acts on (#927). It takes the
    /// destinations' place in the header, and its text sits above the words.
    var draftReview: QuickCaptureDraftSnapshot? = nil
    /// Where each destination pill or row sits, in the view's global space
    /// (top left origin), and nil once it is gone: the panel swallows every
    /// click, so it finds the clicked one from these (#880).
    var onDestinationFrame: ((OverlayDestinationTarget, CGRect?) -> Void)? = nil
    private let cornerRadius: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool {
        motion == .reduced || (motion == .system && systemReduceMotion)
    }

    /// Warning text needs explicit light/dark variants: system `.red` over
    /// the translucent panel material washes out on light desktops.
    static let warningColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1.00, green: 0.48, blue: 0.44, alpha: 1.0)
            : NSColor(srgbRed: 0.63, green: 0.07, blue: 0.05, alpha: 1.0)
    })

    private var phaseTitle: String {
        switch phase {
        case .buffering:
            // Actionable, not just descriptive: the commit re-checks Secure
            // Keyboard Entry at stop, so moving focus to a normal field
            // before then gets a real insert instead of the clipboard.
            return secureInputActive
                ? "Secure input — select another field before finalizing"
                : "Listening"
        case .finalizing:
            if polished { return "Polished" }
            if polishing { return "Polishing" }
            return secureInputActive ? "Finalizing (secure input)" : "Finalizing"
        case .commitFailed:
            return "Insert failed"
        case .idle:
            return "Ready"
        }
    }

    private var isSecureInputTitle: Bool {
        secureInputActive && (phase == .buffering || phase == .finalizing)
    }

    private var titleColor: Color {
        if phase == .finalizing, polished { return OverlayPalette.polish }
        return isSecureInputTitle ? Self.warningColor : .secondary
    }

    /// What the words show besides themselves: the polish wait, or what
    /// polish changed.
    private var bodyEmphasis: OverlayBodyScrollContent.Emphasis {
        guard phase == .finalizing else { return .none }
        if polished, let polishedFrom { return .changed(from: polishedFrom) }
        return polishing ? .sweep : .none
    }

    private var displayText: String {
        let trimmed = text.trimmed
        return trimmed.isEmpty ? "" : text
    }

    /// Maximum height the text area can grow to before scrolling kicks in.
    private var maxScrollableHeight: CGFloat {
        metrics.maxScrollableBodyHeight
    }

    private var minimumBodyTextHeight: CGFloat {
        metrics.bodyLineHeight
    }

    /// Estimated height of the current text content.
    private var textHeight: CGFloat {
        metrics.unclampedBodyTextHeight(for: displayText)
    }

    /// Trailing pill naming the Claude Code session this dictation is grounded
    /// in, or saying that none attached. Quiet weight deliberately: an
    /// unjoined dictation still commits its text correctly, so
    /// this annotates the panel — it is not an error, and the warning color
    /// under the transcript is reserved for text that failed to insert.
    ///
    /// The distinction rides the icon (`link` vs `link.slash`) and the label,
    /// not color, so it reads the same on both desktops without a second
    /// appearance-matched palette.
    @ViewBuilder
    private var claudeJoinBadge: some View {
        switch claudeJoin {
        case .hidden:
            EmptyView()
        case .joined(let label):
            joinPill(
                systemImage: "link",
                title: label,
                accessibilityLabel: "Grounded in Claude Code session \(label)"
            )
        case .unjoined:
            joinPill(
                systemImage: "link.slash",
                title: "No Claude session",
                accessibilityLabel: "No Claude Code session joined for this dictation"
            )
        }
    }

    /// The picked destination, tinted in its own color: the Inbox never
    /// inserts, and a session is another pane, so neither may look like the
    /// focused app. Closed, the header shows it whole; open (#1015), the list
    /// under the header does, and the header keeps only where it sits. The
    /// Tab key says how to move. A tint, not a fill (#1074): the pill was
    /// the loudest thing on the panel.
    private func destinationHeader(_ strip: OverlayDestinationStrip) -> some View {
        HStack(spacing: 4) {
            if !strip.isOpen, let item = strip.selectedItem {
                destinationPill(item)
                    .layoutPriority(-1)
                    .reportingFrame(of: OverlayDestinationTarget(destination: item.destination, inList: false), to: onDestinationFrame)
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: metrics.badgeFontSize * 0.8, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)
                    )
                Text(strip.position)
                    .font(.system(size: metrics.badgeFontSize, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(.tertiary)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Destination \(strip.position). Tab changes where the words go")
        }
        .layoutPriority(-1)
    }

    private func destinationPill(_ item: OverlayDestinationStrip.Item) -> some View {
        let style = DestinationStyle(item.kind)
        return HStack(spacing: 3) {
            destinationIcon(item, style: style)
            Text(item.label)
                .font(.system(size: metrics.badgeFontSize, weight: .semibold))
                .foregroundStyle(style.tint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, metrics.badgeHorizontalPadding)
        .padding(.vertical, metrics.badgeVerticalPadding)
        .background(Capsule(style: .continuous).fill(style.tint.opacity(Self.pillTintOpacity)))
        // The outline keeps the pill's edge on a light desktop, where the
        // tint alone washes out.
        .overlay(Capsule(style: .continuous).strokeBorder(style.tint.opacity(0.45), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibility(item.label))
        .accessibilityAddTraits(.isSelected)
    }

    static let pillTintOpacity = 0.14
    static let rowTintOpacity = 0.18

    /// Every destination, one row each, the picked one tinted. Past
    /// `maximumVisibleDestinationRows` it scrolls, keeping the picked row
    /// in view. Heights mirror `OverlayLayoutMetrics.destinationListHeight`.
    private func destinationList(_ strip: OverlayDestinationStrip) -> some View {
        let scrolls = strip.items.count > OverlayLayoutMetrics.maximumVisibleDestinationRows
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: scrolls) {
                VStack(alignment: .leading, spacing: OverlayLayoutMetrics.destinationRowSpacing) {
                    ForEach(strip.items, id: \.destination) { item in
                        destinationRow(item)
                            .id(item.destination)
                            .reportingFrame(of: OverlayDestinationTarget(destination: item.destination, inList: true), to: onDestinationFrame)
                    }
                }
            }
            .scrollDisabled(!scrolls)
            .frame(height: metrics.destinationListHeight(rows: strip.items.count))
            .onAppear { scrollToSelected(strip, proxy) }
            .onChange(of: strip.selectedItem?.destination) { _, _ in scrollToSelected(strip, proxy) }
        }
    }

    private func scrollToSelected(_ strip: OverlayDestinationStrip, _ proxy: ScrollViewProxy) {
        guard let selected = strip.selectedItem?.destination else { return }
        proxy.scrollTo(selected)
    }

    private func destinationRow(_ item: OverlayDestinationStrip.Item) -> some View {
        let style = DestinationStyle(item.kind)
        return HStack(spacing: 5) {
            destinationIcon(item, style: style)
                .frame(width: metrics.badgeFontSize * 1.2)
            Text(item.label)
                .font(.system(size: metrics.badgeFontSize, weight: .semibold))
                .foregroundStyle(item.isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.badgeHorizontalPadding)
        .frame(height: metrics.destinationRowHeight)
        .background(
            RoundedRectangle(cornerRadius: metrics.destinationRowHeight / 3, style: .continuous)
                .fill(item.isSelected ? style.tint.opacity(Self.rowTintOpacity) : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibility(item.label))
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func destinationIcon(_ item: OverlayDestinationStrip.Item, style: DestinationStyle) -> some View {
        if let systemImage = style.systemImage {
            Image(systemName: systemImage)
                .font(.system(size: metrics.badgeFontSize * (item.kind == .session ? 0.6 : 0.9)))
                .foregroundStyle(item.isSelected || item.kind == .session ? style.tint : Color.secondary)
        }
    }

    /// The Inbox pill, tinted like the destination pills: the words go to
    /// the draft, never into an app.
    private func draftReviewPill(_ draft: QuickCaptureDraftSnapshot) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "tray")
                .font(.system(size: metrics.badgeFontSize * 0.9))
            Text("Inbox for \(draft.projectName)")
                .font(.system(size: metrics.badgeFontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(OverlayPalette.inbox)
        .padding(.horizontal, metrics.badgeHorizontalPadding)
        .padding(.vertical, metrics.badgeVerticalPadding)
        .background(Capsule(style: .continuous).fill(OverlayPalette.inbox.opacity(Self.pillTintOpacity)))
        .overlay(Capsule(style: .continuous).strokeBorder(OverlayPalette.inbox.opacity(0.45), lineWidth: 0.5))
        .layoutPriority(-1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reviewing a draft in the Inbox for \(draft.projectName)")
    }

    /// Title, the start of the body, and what to say. Heights mirror
    /// `OverlayLayoutMetrics.draftReviewHeight`.
    private func draftReviewBlock(_ draft: QuickCaptureDraftSnapshot) -> some View {
        VStack(alignment: .leading, spacing: OverlayLayoutMetrics.draftReviewSpacing) {
            Text(draft.title)
                .font(.system(size: metrics.bodyFontSize, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            let excerpt = draft.bodyExcerpt
            if !excerpt.isEmpty {
                Text(excerpt)
                    .font(.system(size: metrics.errorFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(OverlayLayoutMetrics.draftReviewHint)
                .font(.system(size: metrics.badgeFontSize))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func joinPill(
        systemImage: String,
        title: String,
        accessibilityLabel: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.system(size: metrics.badgeFontSize, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, metrics.badgeHorizontalPadding)
            .padding(.vertical, metrics.badgeVerticalPadding)
            .background(
                Capsule(style: .continuous).fill(Color.primary.opacity(0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            // Yields header width to the phase title, which is the actionable
            // half (the secure-input title tells the user what to DO); a long
            // workspace name truncates instead of pushing it out.
            .layoutPriority(-1)
            .accessibilityLabel(accessibilityLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OverlayLayoutMetrics.stackSpacing) {
            HStack(alignment: .center, spacing: 6) {
                if phase == .buffering {
                    OverlayLevelBars(level: micLevel, reduceMotion: reduceMotion, metrics: metrics)
                }
                Text(phaseTitle)
                    .font(.system(size: metrics.titleFontSize, weight: .semibold))
                    .foregroundStyle(titleColor)
                // The sweep over the words shows the polish wait, and a
                // polished panel has nothing left to wait for.
                if phase == .finalizing, !polishing, !polished {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                if let draftReview {
                    draftReviewPill(draftReview)
                } else if let destinations {
                    destinationHeader(destinations)
                } else {
                    claudeJoinBadge
                }
            }
            .frame(height: metrics.headerHeight)

            if let draftReview {
                draftReviewBlock(draftReview)
            } else if let destinations, destinations.isOpen {
                destinationList(destinations)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    OverlayBodyScrollContent(
                        text: displayText, metrics: metrics, emphasis: bodyEmphasis,
                        motion: reduceMotion ? .reduced : motion)
                }
                .scrollDisabled(textHeight <= maxScrollableHeight)
                .frame(
                    maxWidth: .infinity,
                    minHeight: minimumBodyTextHeight,
                    idealHeight: min(textHeight, maxScrollableHeight),
                    maxHeight: maxScrollableHeight
                )
                .onChange(of: text) { _, _ in
                    if textHeight > maxScrollableHeight {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(OverlayBodyScrollContent.bottomAnchorID, anchor: .bottom)
                        }
                    }
                }
            }

            if let errorMessage, !errorMessage.trimmed.isEmpty {
                Text(errorMessage)
                    .font(.system(size: metrics.errorFontSize))
                    .foregroundStyle(Self.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(OverlayLayoutMetrics.contentPadding)
        .frame(
            minWidth: metrics.panelMinWidth,
            idealWidth: metrics.panelWidth,
            maxWidth: metrics.panelMaxWidth,
            alignment: .leading
        )
        .background(RoundedMaterialBackground(cornerRadius: cornerRadius))
        .overlay(
            // Hairline must survive both appearances: pure white vanished
            // against light desktops.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 8)
    }
}

/// How a destination kind looks in the header pill and the list.
private struct DestinationStyle {
    let tint: Color
    let systemImage: String?
    let accessibility: (String) -> String

    init(_ kind: OverlayDestinationStrip.Kind) {
        switch kind {
        case .focusedApp(let joined):
            tint = OverlayPalette.focusedApp
            systemImage = joined.map { $0 ? "link" : "link.slash" }
            accessibility = { "Into \($0)" }
        case .session:
            tint = OverlayPalette.session
            systemImage = "circle.fill"
            accessibility = { "Answer \($0), which needs you" }
        case .inbox:
            tint = OverlayPalette.inbox
            systemImage = "tray"
            accessibility = { _ in "Save to the Inbox" }
        }
    }
}

/// One place a destination is drawn: the header pill or its list row. Both
/// can be on screen for a moment while the list opens or closes, so each
/// reports its own frame, and one going away never clears the other's.
struct OverlayDestinationTarget: Hashable {
    let destination: DictationDestination
    let inList: Bool
}

private extension View {
    /// Reports where this target is drawn, and nil once it is gone. Inside
    /// a scroll view only the part in view counts: a row scrolled out of
    /// the list still has a frame, over the transcript or the header, and
    /// a click there must not pick it.
    func reportingFrame(
        of target: OverlayDestinationTarget,
        to report: ((OverlayDestinationTarget, CGRect?) -> Void)?
    ) -> some View {
        onGeometryChange(for: CGRect?.self) { proxy in
            let frame = proxy.frame(in: .global)
            guard let visible = proxy.bounds(of: .scrollView) else { return frame }
            let shown = CGRect(origin: .zero, size: proxy.size).intersection(visible)
            guard !shown.isNull, shown.height > 0 else { return nil }
            return shown.offsetBy(dx: frame.minX, dy: frame.minY)
        } action: { frame in
            report?(target, frame)
        }
        .onDisappear { report?(target, nil) }
    }
}

/// The overlay body's scrollable document: the transcript plus the invisible
/// anchor auto-scroll targets. The anchor must be the last thing in the
/// document — anything below it (a bottom padding did this) is scroll range
/// auto-scroll never reaches, so the scroller stops short of the bottom and a
/// manual scroll pushes the last line up.
///
/// Every emphasis draws over the same `Text`, so none of them changes the
/// size `OverlayLayoutMetrics` measured.
/// How the overlay moves. `.system` follows Reduce Motion. The others stand
/// in for it in view snapshots, where the environment has no setter and the
/// clock must not show: `.reduced` draws the Reduce Motion stills, `.frozen`
/// one representative frame of each motion.
enum OverlayMotion: Equatable {
    case system
    case reduced
    case frozen
}

struct OverlayBodyScrollContent: View {
    enum Emphasis: Equatable {
        case none
        /// The polish request is out.
        case sweep
        /// Polish replaced `from` with the text shown.
        case changed(from: String)
    }

    static let bottomAnchorID = "bottom"
    static let bottomAnchorHeight: CGFloat = 1

    let text: String
    let metrics: OverlayLayoutMetrics
    var emphasis: Emphasis = .none
    var motion: OverlayMotion = .system

    var body: some View {
        VStack(spacing: 0) {
            words
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    maxWidth: .infinity,
                    minHeight: metrics.bodyLineHeight,
                    alignment: .topLeading
                )

            Color.clear
                .frame(height: Self.bottomAnchorHeight)
                .id(Self.bottomAnchorID)
        }
    }

    private var plain: Text {
        Text(text).font(.system(size: metrics.bodyFontSize))
    }

    @ViewBuilder
    private var words: some View {
        switch emphasis {
        case .none:
            plain.foregroundStyle(.primary)
        case .sweep:
            OverlayPolishSweep(text: plain, motion: motion)
        case .changed(let before):
            OverlayChangedWords(
                text: text, before: before, font: .system(size: metrics.bodyFontSize),
                fades: motion == .system)
        }
    }
}

/// The polish wait (#1074): the words dim and a band in the polish color
/// crosses them, left to right, until the reply lands. Under Reduce Motion
/// the words only dim.
struct OverlayPolishSweep: View {
    /// One crossing, in seconds.
    static let period: TimeInterval = 1.2
    /// Half the band's width, as a fraction of the text's.
    static let halfBand = 0.22

    let text: Text
    let motion: OverlayMotion

    var body: some View {
        switch motion {
        case .reduced:
            text.foregroundStyle(.secondary)
        case .frozen:
            band(at: 0.5)
        case .system:
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                band(at: time.truncatingRemainder(dividingBy: Self.period) / Self.period)
            }
        }
    }

    /// The frame `progress` (0...1) through one crossing: the band starts
    /// just off the leading edge and ends just off the trailing one.
    func band(at progress: Double) -> some View {
        let center = -Self.halfBand + progress * (1 + 2 * Self.halfBand)
        let clamp = { (location: Double) in min(1, max(0, location)) }
        return text
            .foregroundStyle(.secondary)
            .overlay(alignment: .topLeading) {
                text
                    .foregroundStyle(OverlayPalette.polish)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: clamp(center - Self.halfBand)),
                                .init(color: .black, location: clamp(center)),
                                .init(color: .clear, location: clamp(center + Self.halfBand)),
                            ],
                            startPoint: .leading, endPoint: .trailing)
                    )
            }
    }
}

/// What polish changed (#1074): the words it wrote take the polish color on a
/// highlight, then fade back to plain text as the panel closes. Under Reduce
/// Motion they stay marked until the close.
struct OverlayChangedWords: View {
    /// The marks hold, then fade, ending with the panel's hold
    /// (`TimingConstants.overlayPolishedVisibility`).
    static let fadeDelay: TimeInterval = 0.6
    static let fadeDuration: TimeInterval = 0.6
    static let highlightOpacity = 0.22

    let text: String
    let before: String
    let font: Font
    /// False under Reduce Motion, and in view snapshots.
    let fades: Bool

    @State private var strength = 1.0

    init(text: String, before: String, font: Font, fades: Bool) {
        self.text = text
        self.before = before
        self.font = font
        self.fades = fades
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.primary)
            .overlay(alignment: .topLeading) {
                Text(Self.marked(text, before: before))
                    .font(font)
                    .opacity(strength)
                    .accessibilityHidden(true)
            }
            .onAppear {
                guard fades else { return }
                withAnimation(.easeOut(duration: Self.fadeDuration).delay(Self.fadeDelay)) {
                    strength = 0
                }
            }
    }

    /// `text` with only the words `before` lacked drawn, in the polish color
    /// on its highlight; the rest is clear, so the plain text shows through.
    static func marked(_ text: String, before: String) -> AttributedString {
        var marked = AttributedString(text)
        marked.foregroundColor = .clear
        for range in TranscriptDiff.words(from: before, to: text).added {
            guard let changed = Range<AttributedString.Index>(range, in: marked) else { continue }
            marked[changed].foregroundColor = OverlayPalette.polish
            marked[changed].backgroundColor = OverlayPalette.polish.opacity(highlightOpacity)
        }
        return marked
    }
}

/// The mic's recent levels for the overlay's bars (#1074). Its own
/// observable, so a level moves only the bars: a panel render re-measures
/// the whole panel.
@MainActor
@Observable
final class OverlayMicLevel {
    static let historyLength = 4

    /// Newest first.
    private(set) var history = Array(repeating: 0.0, count: historyLength)

    func push(_ level: Double) {
        history.insert(level, at: 0)
        history.removeLast()
    }

    func reset() {
        history = Array(repeating: 0, count: Self.historyLength)
    }
}

/// Seven thin bars in the menu bar mic's orange, tallest in the middle like
/// a voice. The newest level sits in the middle and older ones spread
/// outward, so a word starts at the center and ripples out. Under Reduce
/// Motion a still mic stands in for them.
struct OverlayLevelBars: View {
    static let profile: [Double] = [0.55, 0.75, 0.9, 1, 0.9, 0.75, 0.55]
    static let barWidth: CGFloat = 2
    static let restingHeight: CGFloat = 3

    let level: OverlayMicLevel?
    let reduceMotion: Bool
    let metrics: OverlayLayoutMetrics

    /// Each bar's share of the full height, 0...1.
    static func heights(history: [Double]) -> [Double] {
        let middle = profile.count / 2
        return profile.indices.map { index in
            let age = min(abs(index - middle), history.count - 1)
            return history[age] * profile[index]
        }
    }

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "mic.fill")
                    .font(.system(size: metrics.titleFontSize, weight: .semibold))
                    .foregroundStyle(OverlayPalette.live)
            } else {
                let fullHeight = metrics.headerHeight - 2
                let heights = Self.heights(
                    history: level?.history ?? Array(repeating: 0, count: OverlayMicLevel.historyLength))
                HStack(alignment: .center, spacing: 2) {
                    ForEach(heights.indices, id: \.self) { index in
                        Capsule()
                            .fill(OverlayPalette.live)
                            .frame(
                                width: Self.barWidth,
                                height: Self.restingHeight + (fullHeight - Self.restingHeight) * heights[index])
                    }
                }
                .frame(height: fullHeight)
                // Posts come 30 times a second; easing between them is what
                // makes the motion read as continuous.
                .animation(.easeOut(duration: 0.08), value: heights)
            }
        }
        .accessibilityHidden(true)
    }
}
