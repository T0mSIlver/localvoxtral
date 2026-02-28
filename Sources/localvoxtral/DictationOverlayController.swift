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

@MainActor
final class DictationOverlayController {
    private let panel: NSPanel
    private let hostingView: TransparentHostingView<DictationOverlayView>
    private let minimumPanelSize = CGSize(width: 420, height: 120)
    private let maximumPanelSize = CGSize(width: 560, height: 420)
    private let cornerRadius: CGFloat = 12

    /// Locked placement state for the current session. Set on first render,
    /// cleared on hide. Prevents the panel from flipping between above/below
    /// as the content height changes.
    private enum Placement {
        /// Panel sits above the anchor. `nearEdgeY` is the panel's bottom edge.
        case above(nearEdgeY: CGFloat)
        /// Panel sits below the anchor. `nearEdgeY` is the panel's top edge.
        case below(nearEdgeY: CGFloat)
    }
    private var lockedPlacement: Placement?
    private var lockedOriginX: CGFloat?

    init() {
        panel = NSPanel(
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
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let initialView = DictationOverlayView(
            phase: .idle,
            text: "",
            errorMessage: nil
        )
        hostingView = TransparentHostingView(rootView: initialView)
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

        panel.contentView?.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let boundedFitting = (fitting.width > 0 && fitting.height > 0) ? fitting : NSSize(
            width: minimumPanelSize.width,
            height: minimumPanelSize.height
        )
        let size = CGSize(
            width: min(max(boundedFitting.width, minimumPanelSize.width), maximumPanelSize.width),
            height: min(max(boundedFitting.height, minimumPanelSize.height), maximumPanelSize.height)
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
    /// below) and the X origin are locked on the first render of each session.
    /// Subsequent renders only change the panel height — the near edge stays
    /// fixed so the panel grows away from the anchor without bouncing.
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

    /// Returns the vertical origin, locking the above/below decision on first call per session.
    /// On subsequent calls, the near edge stays fixed and the panel grows away from the anchor.
    private func resolveLockedOriginY(targetRect: CGRect, contentHeight: CGFloat, visibleFrame: CGRect, margin: CGFloat) -> CGFloat {
        if let placement = lockedPlacement {
            return originYForLocked(placement: placement, contentHeight: contentHeight, visibleFrame: visibleFrame, margin: margin)
        }
        return resolveInitialPlacement(targetRect: targetRect, contentHeight: contentHeight, visibleFrame: visibleFrame, margin: margin)
    }

    private func originYForLocked(placement: Placement, contentHeight: CGFloat, visibleFrame: CGRect, margin: CGFloat) -> CGFloat {
        switch placement {
        case .above(let nearEdgeY):
            return max(nearEdgeY, visibleFrame.minY + margin)
        case .below(let nearEdgeY):
            return max(nearEdgeY - contentHeight, visibleFrame.minY + margin)
        }
    }

    private func resolveInitialPlacement(targetRect: CGRect, contentHeight: CGFloat, visibleFrame: CGRect, margin: CGFloat) -> CGFloat {
        let aboveOriginY = targetRect.maxY + margin
        if aboveOriginY + contentHeight <= visibleFrame.maxY {
            lockedPlacement = .above(nearEdgeY: aboveOriginY)
            return aboveOriginY
        }

        let belowTopEdge = targetRect.minY - margin
        let belowOriginY = belowTopEdge - contentHeight
        if belowOriginY >= visibleFrame.minY + margin {
            lockedPlacement = .below(nearEdgeY: belowTopEdge)
            return belowOriginY
        }

        let clamped = max(aboveOriginY, visibleFrame.minY + margin)
        lockedPlacement = .above(nearEdgeY: clamped)
        return clamped
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
