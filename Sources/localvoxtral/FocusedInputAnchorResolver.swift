import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class OverlayAnchorResolver {
    func resolveAnchor() -> OverlayAnchor {
        if let windowCenter = focusedWindowCenterRect() {
            return OverlayAnchor(targetRect: windowCenter, source: .focusedWindow)
        }

        let cursorPoint = NSEvent.mouseLocation
        Log.overlay.info(
            "anchor: CURSOR FALLBACK at (\(cursorPoint.x, privacy: .public),\(cursorPoint.y, privacy: .public))"
        )
        return OverlayAnchor(
            targetRect: CGRect(x: cursorPoint.x, y: cursorPoint.y, width: 1, height: 1),
            source: .cursor
        )
    }

    func resolveFrontmostAppPID() -> pid_t? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier != getpid()
        else {
            return nil
        }
        return frontmostApp.processIdentifier
    }

    private func focusedWindowCenterRect() -> CGRect? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier != getpid()
        else {
            return nil
        }

        let pid = frontmostApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var windowObject: AnyObject?
        let status = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowObject
        )
        guard status == .success,
              let windowObject,
              CFGetTypeID(windowObject) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let windowElement = unsafeDowncast(windowObject, to: AXUIElement.self)
        guard let frame = elementFrame(of: windowElement) else { return nil }
        let converted = axToAppKit(frame)
        guard converted.width > 0, converted.height > 0 else { return nil }
        return CGRect(x: converted.midX, y: converted.midY, width: 1, height: 1)
    }

    private func elementFrame(of element: AXUIElement) -> CGRect? {
        var positionObject: AnyObject?
        let posStatus = AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &positionObject
        )
        guard posStatus == .success,
              let positionObject,
              CFGetTypeID(positionObject) == AXValueGetTypeID()
        else { return nil }
        let posValue = unsafeDowncast(positionObject, to: AXValue.self)
        guard AXValueGetType(posValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(posValue, .cgPoint, &point) else { return nil }

        var sizeObject: AnyObject?
        let sizeStatus = AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &sizeObject
        )
        guard sizeStatus == .success,
              let sizeObject,
              CFGetTypeID(sizeObject) == AXValueGetTypeID()
        else { return nil }
        let szValue = unsafeDowncast(sizeObject, to: AXValue.self)
        guard AXValueGetType(szValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(szValue, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }

        return CGRect(origin: point, size: size)
    }

    /// Converts a rect from AX/Quartz global display coordinates (Y-down)
    /// to AppKit screen coordinates (Y-up).
    private func axToAppKit(_ axRect: CGRect) -> CGRect {
        guard let maxY = primaryScreenMaxY() else {
            return axRect
        }
        return CGRect(
            x: axRect.origin.x,
            y: maxY - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }

    private func primaryScreenMaxY() -> CGFloat? {
        let mainDisplayID = CGMainDisplayID()
        if let mainScreen = NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == mainDisplayID
        }) {
            return mainScreen.frame.maxY
        }
        return NSScreen.screens.first?.frame.maxY
    }
}
