import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Resolves the overlay panel's anchor position.
///
/// The panel is anchored to the **center of the frontmost app's focused window**
/// (not the focused text field). This is a deliberate simplification: resolving the
/// actual input element is fragile across apps and frameworks. Window-center
/// placement keeps the overlay predictably visible regardless of input field
/// position. Falls back to the mouse location when no window is available.
///
/// Start and stop call this on the main actor, so every AX element it queries
/// gets `TerminalScreenAXReader.messagingTimeoutSeconds`: a wedged frontmost
/// app then costs at most three short timeouts instead of the system default
/// (about 6 s per message), and the anchor falls back to the mouse.
@MainActor
final class OverlayAnchorResolver {
    private let ax: OverlayAnchorAXReading
    private let frontmostPID: @MainActor () -> pid_t?

    init(
        ax: OverlayAnchorAXReading = SystemOverlayAnchorAX(),
        frontmostPID: (@MainActor () -> pid_t?)? = nil
    ) {
        self.ax = ax
        self.frontmostPID = frontmostPID ?? {
            guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
                  frontmostApp.processIdentifier != getpid()
            else { return nil }
            return frontmostApp.processIdentifier
        }
    }

    func resolveAnchor() -> OverlayAnchor {
        if let center = frontmostWindowCenter() {
            return OverlayAnchor(targetRect: center, source: .windowCenter)
        }

        let mousePoint = NSEvent.mouseLocation
        Log.overlay.info(
            "anchor: mouse fallback at (\(mousePoint.x, privacy: .public),\(mousePoint.y, privacy: .public))"
        )
        return OverlayAnchor(
            targetRect: CGRect(x: mousePoint.x, y: mousePoint.y, width: 1, height: 1),
            source: .mouseLocation
        )
    }

    func resolveFrontmostAppPID() -> pid_t? {
        frontmostPID()
    }

    private func frontmostWindowCenter() -> CGRect? {
        guard let pid = frontmostPID() else { return nil }

        let appElement = ax.applicationElement(pid: pid)
        ax.setMessagingTimeout(appElement, seconds: TerminalScreenAXReader.messagingTimeoutSeconds)
        let (status, windowObject) = ax.copyAttribute(appElement, kAXFocusedWindowAttribute)
        guard status == .success,
              let windowObject,
              CFGetTypeID(windowObject) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let windowElement = unsafeDowncast(windowObject, to: AXUIElement.self)
        // The timeout is per element: the window copied out of the app element
        // does not inherit it.
        ax.setMessagingTimeout(windowElement, seconds: TerminalScreenAXReader.messagingTimeoutSeconds)
        guard let frame = elementFrame(of: windowElement) else { return nil }
        let converted = axToAppKit(frame)
        guard converted.width > 0, converted.height > 0 else { return nil }
        return CGRect(x: converted.midX, y: converted.midY, width: 1, height: 1)
    }

    private func elementFrame(of element: AXUIElement) -> CGRect? {
        let (posStatus, positionObject) = ax.copyAttribute(element, kAXPositionAttribute)
        guard posStatus == .success,
              let positionObject,
              CFGetTypeID(positionObject) == AXValueGetTypeID()
        else { return nil }
        let posValue = unsafeDowncast(positionObject, to: AXValue.self)
        guard AXValueGetType(posValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(posValue, .cgPoint, &point) else { return nil }

        let (sizeStatus, sizeObject) = ax.copyAttribute(element, kAXSizeAttribute)
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
        guard let mainDisplayMaxY = mainDisplayReferenceMaxY() else {
            return axRect
        }

        let convertedUsingMainDisplay = convertAXRectToAppKit(
            axRect,
            referenceMaxY: mainDisplayMaxY
        )
        if intersectsAnyVisibleScreen(convertedUsingMainDisplay) {
            return convertedUsingMainDisplay
        }

        // Fallback for uncommon coordinate-space differences in multi-display
        // arrangements: if main-display conversion lands off-screen, retry with
        // the global desktop top edge.
        let desktopMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? mainDisplayMaxY
        return convertAXRectToAppKit(axRect, referenceMaxY: desktopMaxY)
    }

    private func convertAXRectToAppKit(_ axRect: CGRect, referenceMaxY: CGFloat) -> CGRect {
        CGRect(
            x: axRect.origin.x,
            y: referenceMaxY - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }

    private func intersectsAnyVisibleScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
    }

    private func mainDisplayReferenceMaxY() -> CGFloat? {
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

/// The AX calls `OverlayAnchorResolver` makes, so a test can stand in for a
/// wedged app.
@MainActor
protocol OverlayAnchorAXReading {
    func applicationElement(pid: pid_t) -> AXUIElement
    func setMessagingTimeout(_ element: AXUIElement, seconds: Float)
    func copyAttribute(_ element: AXUIElement, _ attribute: String) -> (AXError, AnyObject?)
}

struct SystemOverlayAnchorAX: OverlayAnchorAXReading {
    func applicationElement(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    func setMessagingTimeout(_ element: AXUIElement, seconds: Float) {
        _ = AXUIElementSetMessagingTimeout(element, seconds)
    }

    func copyAttribute(_ element: AXUIElement, _ attribute: String) -> (AXError, AnyObject?) {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (status, value)
    }
}
