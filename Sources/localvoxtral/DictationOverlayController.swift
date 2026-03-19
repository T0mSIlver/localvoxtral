import AppKit
import os
import SwiftUI

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

private final class OverlayContainerView: NSView {
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { false }
}

/// A panel that swallows mouse events on its body so they don't steal
/// keyboard focus or become the key/main window. This prevents
/// interference with Accessibility-based text insertion.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Swallow all mouse clicks on the overlay body.
        // Forwarding to super can steal focus from the target app
        // and disrupt AX text insertion.
    }
}

@MainActor
final class DictationOverlayController {
    private let panel: NonActivatingPanel
    private let hostingView: TransparentHostingView<DictationOverlayView>
    private let panelWidth: CGFloat = 420
    private let maximumPanelHeight: CGFloat = 420
    private let cornerRadius: CGFloat = 12

    /// Locked placement state for the current session. Set on first render,
    /// cleared on hide. Prevents the panel from flipping between above/below
    /// as the content height changes.
    private enum Placement {
        /// Panel sits above the anchor. Top edge is locked; panel grows downward.
        case above(topEdgeY: CGFloat)
        /// Panel sits below the anchor. Top edge is locked; panel grows downward.
        case below(topEdgeY: CGFloat)
    }
    private var lockedPlacement: Placement?
    private var lockedOriginX: CGFloat?

    init() {
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        // NonActivatingPanel handles mouse events via mouseDown override
        // while canBecomeKey/canBecomeMain return false, preventing focus theft.
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let initialView = DictationOverlayView(
            phase: .idle,
            text: "",
            errorMessage: nil
        )
        hostingView = TransparentHostingView(rootView: initialView)
        // Without this, NSHostingView probes the SwiftUI content at ∞×∞ and
        // creates a max-height constraint based on the unwrapped (single-line)
        // text height. That internal constraint caps the rendered content shorter
        // than the panel, clipping the bottom line. Setting sizingOptions to []
        // disables all internal sizing constraints so the hosting view simply
        // fills the frame given by Auto Layout edge constraints.
        // See: https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.isOpaque = false
        let containerView = OverlayContainerView(cornerRadius: cornerRadius)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        panel.contentView = containerView
        panel.contentView?.superview?.wantsLayer = true
        panel.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.superview?.layer?.isOpaque = false
        panel.contentView?.superview?.layer?.cornerRadius = cornerRadius
        panel.contentView?.superview?.layer?.cornerCurve = .continuous
        panel.contentView?.superview?.layer?.masksToBounds = true
        panel.orderOut(nil)
    }

    func render(snapshot: OverlayBufferStateMachine.Snapshot?) {
        guard let snapshot else {
            Log.overlay.info("render: nil snapshot, hiding panel")
            hide()
            return
        }

        hostingView.rootView = DictationOverlayView(
            phase: snapshot.phase,
            text: snapshot.bufferText,
            errorMessage: snapshot.errorMessage
        )

        let contentHeight = Self.measureContentHeight(
            text: snapshot.bufferText,
            errorMessage: snapshot.errorMessage,
            panelWidth: panelWidth
        )
        let size = CGSize(
            width: panelWidth,
            height: min(contentHeight, maximumPanelHeight)
        )

        positionPanel(near: snapshot.anchor, contentSize: size)
        applyFrameViewMask()
        panel.orderFrontRegardless()
        let anchorRect = snapshot.anchor.targetRect
        let panelFrame = self.panel.frame
        Log.overlay.info(
            "render: phase=\(String(describing: snapshot.phase), privacy: .public) anchor=(\(anchorRect.origin.x, privacy: .public),\(anchorRect.origin.y, privacy: .public) \(anchorRect.width, privacy: .public)x\(anchorRect.height, privacy: .public)) panel=(\(panelFrame.origin.x, privacy: .public),\(panelFrame.origin.y, privacy: .public) \(panelFrame.width, privacy: .public)x\(panelFrame.height, privacy: .public)) visible=\(self.panel.isVisible)"
        )
    }

    func hide() {
        lockedPlacement = nil
        lockedOriginX = nil
        panel.orderOut(nil)
    }

    /// Position the overlay panel near the given anchor point.
    ///
    /// Anchor rects arrive in **AppKit screen coordinates** (origin at bottom-left
    /// of the primary display, Y increases upward) — the conversion from AX/Quartz
    /// coordinates happens in `OverlayAnchorResolver`.
    ///
    /// The panel is placed above the anchor when possible; if there isn't
    /// enough room above, it flips to below. The placement decision (above vs
    /// below), X origin, and top edge Y are locked on the first render of each
    /// session. Subsequent renders only change the panel height — the top edge
    /// stays fixed so the panel grows downward and the first line of text
    /// remains at a stable position.
    private func positionPanel(near anchor: OverlayAnchor, contentSize: CGSize) {
        let targetRect = anchor.targetRect
        let visibleFrame = screenVisibleFrame(containing: targetRect)
        let margin: CGFloat = 10

        let originX = resolveLockedOriginX(targetRect: targetRect, contentWidth: contentSize.width, visibleFrame: visibleFrame, margin: margin)
        let originY = resolveLockedOriginY(targetRect: targetRect, contentHeight: contentSize.height, visibleFrame: visibleFrame, margin: margin)

        panel.setFrame(
            NSRect(origin: CGPoint(x: originX, y: originY), size: contentSize),
            display: true
        )
    }

    private func screenVisibleFrame(containing targetRect: CGRect) -> CGRect {
        let midPoint = CGPoint(x: targetRect.midX, y: targetRect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(midPoint) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
    }

    /// Returns the horizontal origin, locking on first call per session.
    private func resolveLockedOriginX(targetRect: CGRect, contentWidth: CGFloat, visibleFrame: CGRect, margin: CGFloat) -> CGFloat {
        if let locked = lockedOriginX { return locked }
        let rawX = targetRect.midX - contentWidth / 2
        let clamped = min(max(rawX, visibleFrame.minX + margin), visibleFrame.maxX - contentWidth - margin)
        lockedOriginX = clamped
        return clamped
    }

    /// Returns the vertical origin, locking the above/below decision and top edge on first call.
    /// On subsequent calls, the top edge stays fixed and the panel grows downward.
    private func resolveLockedOriginY(targetRect: CGRect, contentHeight: CGFloat, visibleFrame: CGRect, margin: CGFloat) -> CGFloat {
        if let placement = lockedPlacement {
            return originYForLocked(placement: placement, contentHeight: contentHeight, visibleFrame: visibleFrame, margin: margin)
        }
        return resolveInitialPlacement(targetRect: targetRect, contentHeight: contentHeight, visibleFrame: visibleFrame, margin: margin)
    }

    private func originYForLocked(placement: Placement, contentHeight: CGFloat, visibleFrame: CGRect, margin: CGFloat) -> CGFloat {
        switch placement {
        case .above(let topEdgeY), .below(let topEdgeY):
            // Both cases lock the top edge; the panel grows downward.
            return max(topEdgeY - contentHeight, visibleFrame.minY + margin)
        }
    }

    private func resolveInitialPlacement(targetRect: CGRect, contentHeight: CGFloat, visibleFrame: CGRect, margin: CGFloat) -> CGFloat {
        let aboveOriginY = targetRect.maxY + margin
        let aboveTopEdge = aboveOriginY + contentHeight
        if aboveTopEdge <= visibleFrame.maxY {
            lockedPlacement = .above(topEdgeY: aboveTopEdge)
            return aboveOriginY
        }

        let belowTopEdge = targetRect.minY - margin
        let belowOriginY = belowTopEdge - contentHeight
        if belowOriginY >= visibleFrame.minY + margin {
            lockedPlacement = .below(topEdgeY: belowTopEdge)
            return belowOriginY
        }

        let clampedTopEdge = min(visibleFrame.maxY, aboveTopEdge)
        lockedPlacement = .above(topEdgeY: clampedTopEdge)
        return max(clampedTopEdge - contentHeight, visibleFrame.minY + margin)
    }

    // MARK: - Content height measurement

    /// Computes the panel height by measuring text with `NSString.boundingRect`,
    /// matching the fonts and layout constants from `DictationOverlayView`.
    ///
    /// This avoids `fittingSize` / `sizeThatFits` which both try to minimise the
    /// overall size and can widen the view to avoid a line wrap, returning a height
    /// that is one line too short.
    private static func measureContentHeight(
        text: String,
        errorMessage: String?,
        panelWidth: CGFloat
    ) -> CGFloat {
        // Must match DictationOverlayView layout constants exactly.
        let horizontalPadding: CGFloat = 20   // .padding(10) left + right
        let verticalPadding: CGFloat = 20     // .padding(10) top + bottom
        let vStackSpacing: CGFloat = 8        // VStack spacing
        let headerHeight: CGFloat = 16        // .frame(height: 16) on header
        let bodyFontSize: CGFloat = 13
        let errorFontSize: CGFloat = 11

        let textWidth = panelWidth - horizontalPadding
        let bodyFont = NSFont.systemFont(ofSize: bodyFontSize)
        let singleLineHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)

        let displayText = text.trimmed.isEmpty ? "" : text
        // Must match DictationOverlayView.maxScrollableHeight exactly:
        // 4 lines of body text + 8pt spacing
        let maxScrollableBodyHeight = singleLineHeight * 4 + 8

        let bodyHeight: CGFloat
        if displayText.isEmpty {
            bodyHeight = singleLineHeight
        } else {
            let rect = (displayText as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: bodyFont]
            )
            let measuredHeight = max(ceil(rect.height), singleLineHeight)
            bodyHeight = min(measuredHeight, maxScrollableBodyHeight)
        }

        // header + spacing + body + padding
        var total = verticalPadding + headerHeight + vStackSpacing + bodyHeight

        if let errorMessage, !errorMessage.trimmed.isEmpty {
            let errorFont = NSFont.systemFont(ofSize: errorFontSize)
            let errorRect = (errorMessage as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: errorFont]
            )
            total += vStackSpacing + ceil(errorRect.height)
        }

        return total
    }

    private func applyFrameViewMask() {
        guard let frameView = panel.contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.clear.cgColor
        frameView.layer?.isOpaque = false
        frameView.layer?.cornerRadius = cornerRadius
        frameView.layer?.cornerCurve = .continuous
        frameView.layer?.masksToBounds = true
    }
}
