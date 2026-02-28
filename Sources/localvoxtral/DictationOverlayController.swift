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
