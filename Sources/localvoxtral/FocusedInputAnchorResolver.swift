import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class FocusedInputAnchorResolver {
    func resolveAnchor() -> OverlayAnchor {
        if let focusedRect = focusedInputRect() {
            return OverlayAnchor(targetRect: focusedRect, source: .focusedInput)
        }

        let cursorPoint = NSEvent.mouseLocation
        return OverlayAnchor(
            targetRect: CGRect(x: cursorPoint.x, y: cursorPoint.y, width: 1, height: 1),
            source: .cursor
        )
    }

    func resolveFocusedInputAppPID() -> pid_t? {
        guard let focusedElement = focusedElement() else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(focusedElement, &pid)
        return pid == 0 ? nil : pid
    }

    private func focusedInputRect() -> CGRect? {
        guard let focusedElement = focusedElement() else { return nil }

        if let frame = rectValue(for: "AXFrame" as CFString, in: focusedElement),
           frame.width > 0, frame.height > 0
        {
            return frame
        }

        guard let position = pointValue(for: kAXPositionAttribute as CFString, in: focusedElement),
              let size = sizeValue(for: kAXSizeAttribute as CFString, in: focusedElement),
              size.width > 0,
              size.height > 0
        else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()

        var focusedObject: AnyObject?
        let focusStatus = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard focusStatus == .success,
              let focusedObject,
              CFGetTypeID(focusedObject) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeDowncast(focusedObject, to: AXUIElement.self)
    }

    private func rectValue(for attribute: CFString, in element: AXUIElement) -> CGRect? {
        var valueObject: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute, &valueObject)
        guard status == .success,
              let valueObject,
              CFGetTypeID(valueObject) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = unsafeDowncast(valueObject, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }

    private func pointValue(for attribute: CFString, in element: AXUIElement) -> CGPoint? {
        var valueObject: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute, &valueObject)
        guard status == .success,
              let valueObject,
              CFGetTypeID(valueObject) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = unsafeDowncast(valueObject, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeValue(for attribute: CFString, in element: AXUIElement) -> CGSize? {
        var valueObject: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute, &valueObject)
        guard status == .success,
              let valueObject,
              CFGetTypeID(valueObject) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = unsafeDowncast(valueObject, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }

        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
}
