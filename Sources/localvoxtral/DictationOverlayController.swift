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

/// The one region of the overlay that tracks the mouse.
///
/// The rest of the panel stays inert on purpose. @joostliebregts's fork made
/// the whole panel draggable and lost the Overlay Buffer's auto-paste: a
/// window-wide drag hands the mouse to AppKit's own window-drag machinery,
/// which moves the panel by making it the window the click belongs to — and
/// the panel is precisely the window that must never take focus from the app
/// the text is about to be inserted into. So this view never calls
/// `performDrag(with:)`, never sets `isMovableByWindowBackground`, and never
/// lets the event reach the window: it moves the frame itself and swallows the
/// click, exactly as `NonActivatingPanel.mouseDown` does for the body.
private final class OverlayDragHandleView: NSView {
    /// Drag started, at this screen location.
    var onDragBegan: ((CGPoint) -> Void)?
    /// Mouse moved during a drag, now at this screen location.
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Double-click: put the panel back where the anchor says it goes.
    var onReanchorRequested: (() -> Void)?

    private var isDragging = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Drag to move the overlay. Double-click to re-anchor it."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { false }

    /// The app is never frontmost while dictating, so without this the first
    /// click on the handle would be spent activating it instead of dragging.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeAlways`, not cursor rects: those only apply to a key window,
        // and this panel is never key.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        (isDragging ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else {
            isDragging = false
            NSCursor.openHand.set()
            onReanchorRequested?()
            return
        }
        isDragging = true
        NSCursor.closedHand.set()
        onDragBegan?(NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDragMoved?(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.openHand.set()
        onDragEnded?()
    }
}

@MainActor
final class DictationOverlayController {
    private let panel: NonActivatingPanel
    private let hostingView: TransparentHostingView<DictationOverlayView>
    private let dragHandleView = OverlayDragHandleView(frame: .zero)
    private let dragHandleHeightConstraint: NSLayoutConstraint
    private let cornerRadius: CGFloat = 12
    /// Builds metrics from the user's overlay settings at the start of each
    /// overlay session; they are then locked until `hide()` (see
    /// `OverlaySessionMetricsLock` — the panel's locked X origin assumes a
    /// constant width), so setting changes apply to the next dictation.
    private let metricsProvider: @MainActor () -> OverlayLayoutMetrics
    /// The position the user dragged to in an earlier session, if any.
    private let storedPlacementProvider: @MainActor () -> OverlayManualPlacement?
    /// Persists a dragged position, or clears it on a re-anchor.
    private let placementWriter: @MainActor (OverlayManualPlacement?) -> Void
    private let screensProvider: @MainActor () -> [OverlayScreenSnapshot]
    private var metricsLock = OverlaySessionMetricsLock()
    /// Writes the buffer's line breaks itself so streamed text never re-wraps
    /// (`OverlayStableLineWrapper`). Built from the session's locked metrics on
    /// first render — the wrapper's widths assume the panel width that lock
    /// guarantees — and dropped on hide, along with the breaks it remembers.
    private var lineWrapper: OverlayStableLineWrapper?

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

    /// The position an in-flight (or just-finished) drag put the panel at.
    /// Held here rather than written to settings on every mouse move: it wins
    /// over the stored placement for the rest of the session and is persisted
    /// once, when the mouse comes up.
    private var draggedPlacement: OverlayManualPlacement?
    /// Panel frame when the current drag started, plus the mouse location then.
    /// The translation is measured against both, so a drag never accumulates
    /// rounding drift from the clamped positions it passes through.
    private var dragAnchor: (panelOrigin: CGPoint, mouse: CGPoint)?

    init(
        metricsProvider: @escaping @MainActor () -> OverlayLayoutMetrics = {
            OverlayLayoutMetrics(bodyFontSize: OverlayLayoutMetrics.defaultBodyFontSize)
        },
        storedPlacementProvider: @escaping @MainActor () -> OverlayManualPlacement? = { nil },
        placementWriter: @escaping @MainActor (OverlayManualPlacement?) -> Void = { _ in },
        screensProvider: @escaping @MainActor () -> [OverlayScreenSnapshot] = {
            OverlayScreenSnapshot.current()
        }
    ) {
        self.metricsProvider = metricsProvider
        self.storedPlacementProvider = storedPlacementProvider
        self.placementWriter = placementWriter
        self.screensProvider = screensProvider
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

        let initialMetrics = metricsProvider()
        let initialView = DictationOverlayView(
            phase: .idle,
            text: "",
            errorMessage: nil,
            secureInputActive: false,
            metrics: initialMetrics,
            polished: false,
            claudeJoin: .hidden
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

        // The handle covers the header band the grip is drawn in, above the
        // hosting view so it wins the hit test. The transcript below it stays
        // untouchable, which is what keeps a stray click off the text.
        dragHandleView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dragHandleView, positioned: .above, relativeTo: hostingView)
        dragHandleHeightConstraint = dragHandleView.heightAnchor.constraint(
            equalToConstant: Self.dragHandleHeight(for: initialMetrics))
        NSLayoutConstraint.activate([
            dragHandleView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            dragHandleView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            dragHandleView.topAnchor.constraint(equalTo: containerView.topAnchor),
            dragHandleHeightConstraint,
        ])

        panel.contentView = containerView
        panel.contentView?.superview?.wantsLayer = true
        panel.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.superview?.layer?.isOpaque = false
        panel.contentView?.superview?.layer?.cornerRadius = cornerRadius
        panel.contentView?.superview?.layer?.cornerCurve = .continuous
        panel.contentView?.superview?.layer?.masksToBounds = true
        panel.orderOut(nil)

        dragHandleView.onDragBegan = { [weak self] mouse in
            guard let self else { return }
            self.dragAnchor = (panelOrigin: self.panel.frame.origin, mouse: mouse)
        }
        dragHandleView.onDragMoved = { [weak self] mouse in
            self?.continueDrag(to: mouse)
        }
        dragHandleView.onDragEnded = { [weak self] in
            self?.endDrag()
        }
        dragHandleView.onReanchorRequested = { [weak self] in
            self?.reanchor()
        }
    }

    func render(snapshot: OverlayBufferStateMachine.Snapshot?) {
        guard let snapshot else {
            Log.overlay.info("render: nil snapshot, hiding panel")
            hide()
            return
        }

        let metrics = metricsLock.metrics(current: metricsProvider)
        var wrapper = lineWrapper ?? metrics.makeStableLineWrapper()
        let bufferText = wrapper.wrapped(snapshot.bufferText)
        lineWrapper = wrapper

        hostingView.rootView = DictationOverlayView(
            phase: snapshot.phase,
            text: bufferText,
            errorMessage: snapshot.errorMessage,
            secureInputActive: snapshot.secureInputActive,
            metrics: metrics,
            polished: snapshot.polished,
            claudeJoin: snapshot.claudeJoin
        )
        dragHandleHeightConstraint.constant = Self.dragHandleHeight(for: metrics)

        let contentHeight = metrics.contentHeight(
            text: bufferText,
            errorMessage: snapshot.errorMessage
        )
        let size = CGSize(
            width: metrics.panelWidth,
            height: min(contentHeight, metrics.maximumPanelHeight)
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
        lineWrapper = nil
        lockedPlacement = nil
        lockedOriginX = nil
        draggedPlacement = nil
        dragAnchor = nil
        metricsLock.unlock()
        panel.orderOut(nil)
    }

    /// Height of the band the drag handle covers: the panel's top padding plus
    /// the header row the grip is drawn in. Stops at the transcript.
    private static func dragHandleHeight(for metrics: OverlayLayoutMetrics) -> CGFloat {
        OverlayLayoutMetrics.contentPadding + metrics.headerHeight
    }

    // MARK: - Dragging

    private func continueDrag(to mouse: CGPoint) {
        guard let dragAnchor else { return }
        let size = panel.frame.size
        let proposed = CGRect(
            origin: CGPoint(
                x: dragAnchor.panelOrigin.x + (mouse.x - dragAnchor.mouse.x),
                y: dragAnchor.panelOrigin.y + (mouse.y - dragAnchor.mouse.y)
            ),
            size: size
        )
        guard let settled = OverlayManualPlacementResolver.settle(
            draggedFrame: proposed, screens: screensProvider())
        else {
            // No display could be named, so there is nothing to remember this
            // against. Still follow the mouse: a handle that does nothing is
            // worse than a move that is forgotten at the end of the session.
            panel.setFrame(proposed, display: true)
            return
        }
        draggedPlacement = settled.placement
        panel.setFrame(settled.frame, display: true)
    }

    private func endDrag() {
        dragAnchor = nil
        guard let draggedPlacement else { return }
        placementWriter(draggedPlacement)
        Log.overlay.info(
            "drag: overlay moved to screen \(draggedPlacement.screenID, privacy: .public) offset=(\(draggedPlacement.topLeftOffset.x, privacy: .public),\(draggedPlacement.topLeftOffset.y, privacy: .public))"
        )
    }

    /// Drops the remembered position, here and in settings. The next render
    /// falls back to this session's anchored placement, which is still locked,
    /// so the panel snaps to where it would have opened.
    private func reanchor() {
        draggedPlacement = nil
        dragAnchor = nil
        placementWriter(nil)
        Log.overlay.info("drag: overlay re-anchored")
    }

    /// Position the overlay panel near the given anchor point.
    ///
    /// Anchor rects arrive in **AppKit screen coordinates** (origin at bottom-left
    /// of the primary display, Y increases upward) — the conversion from AX/Quartz
    /// coordinates happens in `OverlayAnchorResolver`.
    ///
    /// A position the user dragged to wins, when the display it was stored
    /// against is still attached (`OverlayManualPlacementResolver`). Otherwise
    /// the panel is placed above the anchor when possible; if there isn't
    /// enough room above, it flips to below. The placement decision (above vs
    /// below), X origin, and top edge Y are locked on the first render of each
    /// session. Subsequent renders only change the panel height — the top edge
    /// stays fixed so the panel grows downward and the first line of text
    /// remains at a stable position.
    private func positionPanel(near anchor: OverlayAnchor, contentSize: CGSize) {
        if let placement = draggedPlacement ?? storedPlacementProvider(),
           let origin = OverlayManualPlacementResolver.resolveOrigin(
               placement, panelSize: contentSize, screens: screensProvider())
        {
            panel.setFrame(NSRect(origin: origin, size: contentSize), display: true)
            return
        }

        let targetRect = anchor.targetRect
        let visibleFrame = screenVisibleFrame(containing: targetRect)
        let margin = OverlayManualPlacementResolver.edgeMargin

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
