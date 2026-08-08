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
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
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

    private func joinPill(
        systemImage: String,
        title: String,
        accessibilityLabel: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
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
                Text(phaseTitle)
                    .font(.system(size: metrics.titleFontSize, weight: .semibold))
                    .foregroundStyle(isSecureInputTitle ? Self.warningColor : Color.secondary)
                if phase == .finalizing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                claudeJoinBadge
                if polished {
                    polishedBadge
                }
            }
            .frame(height: metrics.headerHeight)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        Text(displayText)
                            .font(.system(size: metrics.bodyFontSize))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: minimumBodyTextHeight,
                                alignment: .topLeading
                            )

                        // Invisible anchor for scroll-to-bottom
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.bottom, 12)
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
                            proxy.scrollTo("bottom", anchor: .bottom)
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
