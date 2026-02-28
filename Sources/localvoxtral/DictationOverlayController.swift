import AppKit
import os
import SwiftUI

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

@MainActor
final class DictationOverlayController {
    private let panel: NSPanel
    private let minimumPanelSize = CGSize(width: 420, height: 120)
    private let maximumPanelSize = CGSize(width: 560, height: 420)

    /// Locked placement state for the current session. Set on first render,
    /// cleared on hide. Prevents the panel from flipping between above/below
    /// as the content height changes.
    private enum Placement {
        /// Panel sits above the input field. `nearEdgeY` is the panel's bottom edge.
        case above(nearEdgeY: CGFloat)
        /// Panel sits below the input field. `nearEdgeY` is the panel's top edge.
        case below(nearEdgeY: CGFloat)
    }
    private var lockedPlacement: Placement?
    private var lockedOriginX: CGFloat?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
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
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let initialView = DictationOverlayView(
            phase: .idle,
            text: "",
            errorMessage: nil
        )
        let hostingView = TransparentHostingView(rootView: initialView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
        panel.contentView?.superview?.wantsLayer = true
        panel.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.superview?.layer?.isOpaque = false
        panel.orderOut(nil)
    }

    func render(snapshot: OverlayBufferStateMachine.Snapshot?) {
        guard let snapshot else {
            Log.overlay.info("render: nil snapshot, hiding panel")
            hide()
            return
        }

        if let hostingView = panel.contentView as? NSHostingView<DictationOverlayView> {
            hostingView.rootView = DictationOverlayView(
                phase: snapshot.phase,
                text: snapshot.bufferText,
                errorMessage: snapshot.errorMessage
            )
        }

        panel.contentView?.layoutSubtreeIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? NSSize(
            width: minimumPanelSize.width,
            height: minimumPanelSize.height
        )
        let size = CGSize(
            width: min(max(fitting.width, minimumPanelSize.width), maximumPanelSize.width),
            height: min(max(fitting.height, minimumPanelSize.height), maximumPanelSize.height)
        )

        positionPanel(near: snapshot.anchor, contentSize: size)
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

    /// Position the overlay panel near the given anchor rect.
    ///
    /// Anchor rects arrive in **AppKit screen coordinates** (origin at bottom-left
    /// of the primary display, Y increases upward) — the conversion from AX/Quartz
    /// coordinates happens in `OverlayAnchorResolver.axToAppKit(_:)`.
    ///
    /// The panel is placed above the input field when possible; if there isn't
    /// enough room above, it flips to below. The placement decision (above vs
    /// below) and the X origin are locked on the first render of each session.
    /// Subsequent renders only change the panel height — the near edge stays
    /// fixed so the panel grows away from the input field without bouncing.
    private func positionPanel(near anchor: OverlayAnchor, contentSize: CGSize) {
        let targetRect = anchor.targetRect
        let targetMidPoint = CGPoint(x: targetRect.midX, y: targetRect.midY)

        let screen = NSScreen.screens.first {
            $0.frame.contains(targetMidPoint)
        } ?? NSScreen.main

        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let margin: CGFloat = 10

        // Lock horizontal origin on first render.
        let originX: CGFloat
        if let locked = lockedOriginX {
            originX = locked
        } else {
            let rawX = targetRect.midX - contentSize.width / 2
            let clampedX = min(max(rawX, visibleFrame.minX + margin), visibleFrame.maxX - contentSize.width - margin)
            lockedOriginX = clampedX
            originX = clampedX
        }

        // Lock vertical placement (above/below) on first render.
        // On subsequent renders, keep the near edge fixed and grow away from the input.
        let originY: CGFloat
        if let placement = lockedPlacement {
            switch placement {
            case .above(let nearEdgeY):
                // Bottom edge is anchored. Panel grows upward.
                let candidate = nearEdgeY
                // Only clamp if we'd exceed the screen top.
                originY = max(candidate, visibleFrame.minY + margin)
            case .below(let nearEdgeY):
                // Top edge is anchored. Panel grows downward. Origin = topEdge - height.
                let candidate = nearEdgeY - contentSize.height
                // Only clamp if we'd go below the screen bottom.
                originY = max(candidate, visibleFrame.minY + margin)
            }
        } else {
            // First render — decide above or below.
            let aboveOriginY = targetRect.maxY + margin
            if aboveOriginY + contentSize.height <= visibleFrame.maxY {
                // Fits above.
                lockedPlacement = .above(nearEdgeY: aboveOriginY)
                originY = aboveOriginY
            } else {
                // Try below.
                let belowTopEdge = targetRect.minY - margin
                let belowOriginY = belowTopEdge - contentSize.height
                if belowOriginY >= visibleFrame.minY + margin {
                    lockedPlacement = .below(nearEdgeY: belowTopEdge)
                    originY = belowOriginY
                } else {
                    // Neither fits cleanly — place above and clamp to screen.
                    let clamped = max(aboveOriginY, visibleFrame.minY + margin)
                    lockedPlacement = .above(nearEdgeY: clamped)
                    originY = clamped
                }
            }
        }

        panel.setFrame(
            NSRect(origin: CGPoint(x: originX, y: originY), size: contentSize),
            display: true
        )
    }
}
