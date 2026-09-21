import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One display, as the overlay's placement math sees it.
///
/// A snapshot rather than `NSScreen` so the geometry below is ordinary value
/// code that unit tests can drive: the cases that matter (a display that is
/// gone, one that changed resolution) cannot be staged with real screens.
struct OverlayScreenSnapshot: Equatable, Sendable {
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect

    init(id: String, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Where the user dragged the overlay, stored against the display it sat on.
///
/// The point is the panel's TOP-LEFT corner measured right and DOWN from its
/// screen's own top-left, not a global coordinate. Two reasons, both of them
/// failures a bare point would cause: rearranging displays (or changing which
/// one is primary) moves every global coordinate under the stored point, and
/// the overlay grows downward from its top edge, so the top edge is the
/// coordinate that has to stay still as the transcript gets longer.
struct OverlayManualPlacement: Equatable, Sendable {
    var screenID: String
    var topLeftOffset: CGPoint

    init(screenID: String, topLeftOffset: CGPoint) {
        self.screenID = screenID
        self.topLeftOffset = topLeftOffset
    }

    /// Whether this is usable at all. A stored placement is read back from
    /// user defaults, where an empty string or a NaN is possible, and both
    /// would resolve to a panel origin nothing could clamp.
    var isWellFormed: Bool {
        !screenID.isEmpty && topLeftOffset.x.isFinite && topLeftOffset.y.isFinite
    }
}

/// Turns a dragged panel frame into a stored placement and back.
///
/// Every restore is re-validated against the displays attached RIGHT NOW: the
/// screen has to still be there, and the panel is clamped back inside its
/// visible frame. Skipping either step is what puts the overlay somewhere the
/// user cannot reach it — an unplugged monitor, or a resolution change while
/// it was unplugged — with no way to drag it back.
enum OverlayManualPlacementResolver {
    /// Gap kept between the panel and the edge of the screen's visible frame.
    /// Matches the margin the anchored placement uses.
    static let edgeMargin: CGFloat = 10

    /// The placement to store for a panel sitting at `panelFrame`.
    ///
    /// The display is the one the panel covers most of, so a panel straddling
    /// two screens is remembered against the one it mostly shows on. Returns
    /// nil when no screen can be named — the drag still moved the panel for
    /// this session, it just teaches nothing for the next one.
    static func capture(
        panelFrame: CGRect,
        screens: [OverlayScreenSnapshot]
    ) -> OverlayManualPlacement? {
        guard let screen = screenHosting(panelFrame: panelFrame, screens: screens) else { return nil }
        return OverlayManualPlacement(
            screenID: screen.id,
            topLeftOffset: CGPoint(
                x: panelFrame.minX - screen.frame.minX,
                y: screen.frame.maxY - panelFrame.maxY
            )
        )
    }

    /// The panel's AppKit origin (bottom-left) for a stored placement, or nil
    /// when the placement cannot be honored and the caller should fall back to
    /// the anchored position.
    ///
    /// Nil means the stored display is not attached. The placement itself is
    /// deliberately NOT discarded in that case: plugging the monitor back in
    /// should put the overlay where the user left it, and the anchored
    /// position is always reachable in the meantime.
    static func resolveOrigin(
        _ placement: OverlayManualPlacement,
        panelSize: CGSize,
        screens: [OverlayScreenSnapshot]
    ) -> CGPoint? {
        guard placement.isWellFormed,
              let screen = screens.first(where: { $0.id == placement.screenID })
        else { return nil }

        let visible = screen.visibleFrame
        let minX = visible.minX + edgeMargin
        // `max(minX,…)` for a panel wider than the screen it is restored onto:
        // pin its left edge rather than invert the clamp.
        let maxX = max(minX, visible.maxX - panelSize.width - edgeMargin)
        let x = min(max(screen.frame.minX + placement.topLeftOffset.x, minX), maxX)

        let maxTopEdge = visible.maxY - edgeMargin
        let minTopEdge = min(maxTopEdge, visible.minY + edgeMargin + panelSize.height)
        let topEdge = min(max(screen.frame.maxY - placement.topLeftOffset.y, minTopEdge), maxTopEdge)

        return CGPoint(x: x, y: topEdge - panelSize.height)
    }

    /// The clamped frame a drag should settle on, and the placement to
    /// remember for it. Dragging runs through the same clamp as restoring, so
    /// the panel can never be dropped where the next session would have to
    /// rescue it.
    static func settle(
        draggedFrame: CGRect,
        screens: [OverlayScreenSnapshot]
    ) -> (frame: CGRect, placement: OverlayManualPlacement)? {
        guard let proposed = capture(panelFrame: draggedFrame, screens: screens),
              let origin = resolveOrigin(proposed, panelSize: draggedFrame.size, screens: screens)
        else { return nil }
        let settledFrame = CGRect(origin: origin, size: draggedFrame.size)
        guard let placement = capture(panelFrame: settledFrame, screens: screens) else { return nil }
        return (settledFrame, placement)
    }

    private static func screenHosting(
        panelFrame: CGRect,
        screens: [OverlayScreenSnapshot]
    ) -> OverlayScreenSnapshot? {
        let overlapping = screens
            .map { (screen: $0, area: intersectionArea($0.frame, panelFrame)) }
            .filter { $0.area > 0 }
            .max { $0.area < $1.area }
        if let overlapping { return overlapping.screen }
        // A panel dragged entirely into the gap between two displays still has
        // to belong somewhere; nearest by center beats refusing to remember.
        return screens.min {
            squaredDistance($0.frame.center, panelFrame.center)
                < squaredDistance($1.frame.center, panelFrame.center)
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    private static func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

extension CGRect {
    fileprivate var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension OverlayScreenSnapshot {
    /// The attached displays, in `NSScreen` order.
    @MainActor
    static func current() -> [OverlayScreenSnapshot] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.overlayPlacementID else { return nil }
            return OverlayScreenSnapshot(
                id: id, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
}

extension NSScreen {
    /// Identity that survives a reboot or a cable swap.
    ///
    /// The ColorSync UUID is tied to the display itself. The display NUMBER is
    /// the fallback and a poorer one — macOS hands those out per session, so a
    /// position stored against one can restore onto whichever display
    /// inherited the number — but it is unique among the displays attached at
    /// any one moment, which is what dragging needs, and a restore is clamped
    /// on screen either way. The two are namespaced apart so a number can
    /// never be mistaken for a UUID.
    var overlayPlacementID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) as String?
        {
            return "uuid:\(string)"
        }
        return "num:\(displayID)"
    }
}
