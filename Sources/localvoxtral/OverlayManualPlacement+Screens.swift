import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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
