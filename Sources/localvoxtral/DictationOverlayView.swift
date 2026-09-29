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
    /// Mockup only (#1074): how the panel shows that polish changed the text.
    var polishCue: PolishCueMockup? = nil
    /// Mockup only (#1074): the whole-overlay design directions.
    var design: OverlayDesignMockup? = nil
    private let cornerRadius: CGFloat = 12

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

    /// Subtle, trailing "Polished" pill shown while the LLM-polished text is
    /// held before dismissal. Intentionally quiet — it annotates the panel
    /// rather than competing with the transcript below it.
    private var polishedBadge: some View {
        Label("Polished", systemImage: "wand.and.stars")
            .labelStyle(.titleAndIcon)
            .font(.system(size: metrics.badgeFontSize, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, metrics.badgeHorizontalPadding)
            .padding(.vertical, metrics.badgeVerticalPadding)
            .background(
                Capsule(style: .continuous).fill(Color.primary.opacity(0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            .accessibilityLabel("Polished by the language model")
    }

    /// Trailing pill naming the Claude Code session this dictation is grounded
    /// in, or saying that none attached. Same quiet weight as `polishedBadge`
    /// deliberately: an unjoined dictation still commits its text correctly, so
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

    /// The picked destination, filled in its own color: the Inbox never
    /// inserts, and a session is another pane, so neither may look like the
    /// focused app. Closed, the header shows it whole; open (#1015), the list
    /// under the header does, and the header keeps only where it sits. The
    /// up-down chevrons say there is a list, as on a pop-up button.
    private func destinationHeader(_ strip: OverlayDestinationStrip) -> some View {
        HStack(spacing: 4) {
            if !strip.isOpen, let item = strip.selectedItem {
                destinationPill(item)
                    .layoutPriority(-1)
                    .reportingFrame(of: OverlayDestinationTarget(destination: item.destination, inList: false), to: onDestinationFrame)
            }
            HStack(spacing: 2) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: metrics.badgeFontSize * 0.8, weight: .semibold))
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
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, metrics.badgeHorizontalPadding)
        .padding(.vertical, metrics.badgeVerticalPadding)
        .background(Capsule(style: .continuous).fill(style.tint))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibility(item.label))
        .accessibilityAddTraits(.isSelected)
    }

    /// Every destination, one row each, the picked one filled. Past
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
                .foregroundStyle(item.isSelected ? (softRows ? Color.primary : Color.white) : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.badgeHorizontalPadding)
        .frame(height: metrics.destinationRowHeight)
        .background(
            RoundedRectangle(cornerRadius: metrics.destinationRowHeight / 3, style: .continuous)
                .fill(item.isSelected ? (softRows ? style.tint.opacity(0.18) : style.tint) : Color.clear)
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
                .foregroundStyle(item.isSelected && !softRows ? Color.white : (item.kind == .session || softRows ? style.tint : Color.secondary))
        }
    }

    /// The Inbox pill, filled: the words go to the draft, never into an app.
    private func draftReviewPill(_ draft: QuickCaptureDraftSnapshot) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "tray")
                .font(.system(size: metrics.badgeFontSize * 0.9))
            Text("Inbox for \(draft.projectName)")
                .font(.system(size: metrics.badgeFontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, metrics.badgeHorizontalPadding)
        .padding(.vertical, metrics.badgeVerticalPadding)
        .background(Capsule(style: .continuous).fill(Color.purple))
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

    private var softRows: Bool {
        design?.destination == .outline || design?.destination == .footer
    }

    /// The menu bar's session-active orange: the overlay's listening mark
    /// matches the mic the user already watches.
    private static let listeningColor = Color(nsColor: MenuBarStatusIcon.accentColor)

    @ViewBuilder
    private func designStatus(_ design: OverlayDesignMockup) -> some View {
        let title = Text(phase == .finalizing ? (design.polishing == .today ? "Finalizing" : "Polishing") : phaseTitle)
            .font(.system(size: metrics.titleFontSize, weight: .semibold))
            .foregroundStyle(Color.secondary)
        if phase == .buffering {
            switch design.listening {
            case .today:
                title
            case .dot, .dotOnly:
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.listeningColor)
                        .frame(width: 8, height: 8)
                        .opacity(design.reduceMotion ? 1 : 0.35 + 0.65 * design.pulse)
                    if design.listening == .dot { title }
                }
            case .mic:
                HStack(spacing: 5) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: metrics.titleFontSize, weight: .semibold))
                        .foregroundStyle(Self.listeningColor)
                        .opacity(design.reduceMotion ? 1 : 0.35 + 0.65 * design.pulse)
                    title
                }
            case .bars:
                HStack(spacing: 6) {
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(design.levels.indices, id: \.self) { index in
                            Capsule()
                                .fill(Self.listeningColor)
                                .frame(width: 3, height: 3 + 11 * design.levels[index])
                        }
                    }
                    .frame(height: 14)
                    title
                }
            }
        } else {
            switch design.polishing {
            case .today, .titled:
                title
                ProgressView().controlSize(.small)
            case .shimmer:
                Label {
                    title
                } icon: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: metrics.titleFontSize))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private func tabHint(_ strip: OverlayDestinationStrip) -> some View {
        HStack(spacing: 4) {
            Text("Tab")
                .font(.system(size: metrics.badgeFontSize * 0.85, weight: .semibold))
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
    }

    private func softPill(_ item: OverlayDestinationStrip.Item) -> some View {
        let style = DestinationStyle(item.kind)
        return HStack(spacing: 3) {
            if let systemImage = style.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: metrics.badgeFontSize * (item.kind == .session ? 0.6 : 0.9)))
            }
            Text(item.label)
                .font(.system(size: metrics.badgeFontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(style.tint)
        .padding(.horizontal, metrics.badgeHorizontalPadding)
        .padding(.vertical, metrics.badgeVerticalPadding)
        .background(Capsule(style: .continuous).fill(style.tint.opacity(0.14)))
        .overlay(Capsule(style: .continuous).strokeBorder(style.tint.opacity(0.45), lineWidth: 0.5))
    }

    private func outlineHeader(_ strip: OverlayDestinationStrip) -> some View {
        HStack(spacing: 6) {
            if !strip.isOpen, let item = strip.selectedItem {
                softPill(item).layoutPriority(-1)
            }
            if strip.items.count > 1 { tabHint(strip) }
        }
        .layoutPriority(-1)
    }

    private func footerRow(_ strip: OverlayDestinationStrip) -> some View {
        HStack(spacing: 5) {
            if let item = strip.selectedItem {
                let style = DestinationStyle(item.kind)
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: metrics.badgeFontSize * 0.9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                if let systemImage = style.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: metrics.badgeFontSize * (item.kind == .session ? 0.6 : 0.9)))
                        .foregroundStyle(style.tint)
                }
                Text(item.label)
                    .font(.system(size: metrics.badgeFontSize, weight: .semibold))
                    .foregroundStyle(style.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if strip.items.count > 1 { tabHint(strip) }
        }
        .frame(height: metrics.headerHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OverlayLayoutMetrics.stackSpacing) {
            HStack(alignment: .center, spacing: 6) {
                if let polishCue, polishCue.style == .headerTitle || design != nil {
                    Label(polishCue.headerTitle, systemImage: "wand.and.stars")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: metrics.titleFontSize, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                } else if let design {
                    designStatus(design)
                } else {
                    Text(phaseTitle)
                        .font(.system(size: metrics.titleFontSize, weight: .semibold))
                        .foregroundStyle(isSecureInputTitle ? Self.warningColor : Color.secondary)
                    if phase == .finalizing, polishCue == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
                if let draftReview {
                    draftReviewPill(draftReview)
                } else if destinations != nil, design?.destination == .footer {
                    EmptyView()
                } else if let destinations, design?.destination == .outline {
                    outlineHeader(destinations)
                } else if let destinations {
                    destinationHeader(destinations)
                } else {
                    claudeJoinBadge
                }
                if polished {
                    polishedBadge
                }
            }
            .frame(height: metrics.headerHeight)

            if let draftReview {
                draftReviewBlock(draftReview)
            } else if let destinations, destinations.isOpen, design?.destination != .footer {
                destinationList(destinations)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    if let polishCue {
                        PolishCueBody(cue: polishCue, polished: displayText, metrics: metrics)
                    } else if let design, design.polishing == .shimmer, phase == .finalizing {
                        ShimmerBody(text: displayText, sweep: design.sweep,
                                    reduceMotion: design.reduceMotion, metrics: metrics)
                    } else {
                        OverlayBodyScrollContent(text: displayText, metrics: metrics)
                    }
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

            if let destinations, design?.destination == .footer {
                if destinations.isOpen {
                    destinationList(destinations)
                }
                footerRow(destinations)
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
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(polishCue?.borderOpacity ?? 0)
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
            tint = .accentColor
            systemImage = joined.map { $0 ? "link" : "link.slash" }
            accessibility = { "Into \($0)" }
        case .session:
            tint = .orange
            systemImage = "circle.fill"
            accessibility = { "Answer \($0), which needs you" }
        case .inbox:
            tint = .purple
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
struct OverlayBodyScrollContent: View {
    static let bottomAnchorID = "bottom"
    static let bottomAnchorHeight: CGFloat = 1

    let text: String
    let metrics: OverlayLayoutMetrics

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: metrics.bodyFontSize))
                .foregroundStyle(.primary)
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
}


/// Mockup only (#1074): the options for showing that polish changed the text.
struct PolishCueMockup {
    enum Style { case wordMarks, crossFade, borderPulse, headerTitle }
    var style: Style
    /// 0 when the polished text lands (insertion runs in the same turn), 1 at
    /// the panel's close.
    var progress: Double
    var raw: String
    var reduceMotion = false

    var headerTitle: String { "Polished" }

    var borderOpacity: Double {
        guard style == .borderPulse else { return 0 }
        if reduceMotion { return 1 }
        // One pulse: up over the first 30 %, down by 80 %.
        if progress < 0.3 { return progress / 0.3 }
        return max(0, 1 - (progress - 0.3) / 0.5)
    }

    var markOpacity: Double {
        guard style == .wordMarks else { return 0 }
        if reduceMotion { return 1 }
        // Held for the first half, faded out by the close.
        return progress < 0.5 ? 1 : max(0, 1 - (progress - 0.5) / 0.5)
    }

    var polishedOpacity: Double {
        guard style == .crossFade, !reduceMotion else { return 1 }
        return min(1, progress / 0.6)
    }
}

struct PolishCueBody: View {
    let cue: PolishCueMockup
    let polished: String
    let metrics: OverlayLayoutMetrics

    private var marked: AttributedString {
        var out = AttributedString(polished)
        guard cue.style == .wordMarks else { return out }
        let diff = TranscriptDiff.words(from: cue.raw, to: polished)
        for range in diff.added {
            let lower = polished.distance(from: polished.startIndex, to: range.lowerBound)
            let upper = polished.distance(from: polished.startIndex, to: range.upperBound)
            let a = out.index(out.startIndex, offsetByCharacters: lower)
            let b = out.index(out.startIndex, offsetByCharacters: upper)
            out[a..<b].backgroundColor = Color.accentColor.opacity(0.32 * cue.markOpacity)
            if cue.markOpacity > 0 {
                out[a..<b].underlineStyle = Text.LineStyle(
                    pattern: .solid, color: Color.accentColor.opacity(cue.markOpacity))
            }
        }
        return out
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if cue.style == .crossFade, cue.polishedOpacity < 1 {
                Text(cue.raw)
                    .font(.system(size: metrics.bodyFontSize))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(1 - cue.polishedOpacity)
            }
            Text(marked)
                .font(.system(size: metrics.bodyFontSize))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(cue.polishedOpacity)
        }
        .frame(maxWidth: .infinity, minHeight: metrics.bodyLineHeight, alignment: .topLeading)
    }
}

/// Mockup only (#1074): one direction for the whole overlay.
struct OverlayDesignMockup {
    enum Listening { case today, dot, dotOnly, bars, mic }
    enum Destination { case today, outline, footer }
    enum Polishing { case today, titled, shimmer }
    var listening: Listening = .today
    var destination: Destination = .today
    var polishing: Polishing = .today
    /// The listening dot's breath, 0 dim to 1 full.
    var pulse: Double = 1
    /// Mic level per bar, 0...1.
    var levels: [Double] = [0.35, 0.8, 0.55, 0.95, 0.4]
    /// Where the polishing sweep is across the text, 0...1.
    var sweep: Double = 0.45
    var reduceMotion = false
}

struct ShimmerBody: View {
    let text: String
    let sweep: Double
    let reduceMotion: Bool
    let metrics: OverlayLayoutMetrics

    private var base: some View {
        Text(text)
            .font(.system(size: metrics.bodyFontSize))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: metrics.bodyLineHeight, alignment: .topLeading)
    }

    var body: some View {
        base
            .foregroundStyle(.secondary)
            .overlay {
                if !reduceMotion {
                    base
                        .foregroundStyle(.primary)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: max(0, sweep - 0.22)),
                                    .init(color: .black, location: sweep),
                                    .init(color: .clear, location: min(1, sweep + 0.22)),
                                ],
                                startPoint: .leading, endPoint: .trailing)
                        )
                }
            }
    }
}
