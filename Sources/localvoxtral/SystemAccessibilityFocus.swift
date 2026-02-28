import ApplicationServices
import Foundation

/// Shared utility for querying the system-wide Accessibility focus.
/// Used by both `OverlayAnchorResolver` and `TextInsertionService`
/// to avoid duplicating the same AX system-wide focus query.
enum SystemAccessibilityFocus {
    /// Returns the currently focused UI element and the PID of its owning application,
    /// queried from the system-wide accessibility element.
    static func focusedElement() -> (element: AXUIElement, pid: pid_t)? {
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

        let focusedElement = unsafeDowncast(focusedObject, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(focusedElement, &pid)
        return (focusedElement, pid)
    }

    /// Returns the focused UI element within a specific application, identified by PID.
    static func focusedElement(inApplicationPID pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedObject: AnyObject?
        let focusStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard focusStatus == .success,
              let focusedObject,
              CFGetTypeID(focusedObject) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let focusedElement = unsafeDowncast(focusedObject, to: AXUIElement.self)
        var focusedPID: pid_t = 0
        AXUIElementGetPid(focusedElement, &focusedPID)
        guard focusedPID == pid else { return nil }
        return focusedElement
    }
}
