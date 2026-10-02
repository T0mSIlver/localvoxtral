import ApplicationServices
import XCTest
@testable import localvoxtral

/// A wedged frontmost app must not stall overlay start or stop: the resolver
/// runs on the main actor, so its AX reads have to be bounded.
@MainActor
final class OverlayAnchorResolverTests: XCTestCase {
    func testWedgedAppElementFallsBackToMouseWithinTimeout() {
        let ax = WedgedAppAX(wedged: .application)
        let resolver = OverlayAnchorResolver(ax: ax, frontmostPID: { 4242 })

        let anchor = resolver.resolveAnchor()

        XCTAssertEqual(anchor.source, .mouseLocation)
        XCTAssertLessThan(ax.stalledSeconds, 1.0, "main actor stalled \(ax.stalledSeconds) s")
    }

    func testWedgedWindowElementFallsBackToMouseWithinTimeout() {
        let ax = WedgedAppAX(wedged: .window)
        let resolver = OverlayAnchorResolver(ax: ax, frontmostPID: { 4242 })

        let anchor = resolver.resolveAnchor()

        XCTAssertEqual(anchor.source, .mouseLocation)
        XCTAssertLessThan(ax.stalledSeconds, 1.0, "main actor stalled \(ax.stalledSeconds) s")
    }
}

/// Models an unresponsive app the way AX treats one: each message to it
/// blocks for the element's own messaging timeout (the system default, about
/// 6 s, when none was set; timeouts are per element and an element copied out
/// of another does not inherit its timeout), then fails. Time is counted, not
/// slept.
@MainActor
private final class WedgedAppAX: OverlayAnchorAXReading {
    enum Wedged { case application, window }

    static let systemDefaultTimeout: Float = 6

    let wedged: Wedged
    private(set) var stalledSeconds: Float = 0
    private var timeouts: [ObjectIdentifier: Float] = [:]
    private var appElement: AXUIElement?
    // A distinct real AXUIElement standing in for the focused window. Creating
    // one sends no message, so it needs no Accessibility trust.
    private let windowElement = AXUIElementCreateApplication(1)

    init(wedged: Wedged) {
        self.wedged = wedged
    }

    func applicationElement(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        appElement = element
        return element
    }

    func setMessagingTimeout(_ element: AXUIElement, seconds: Float) {
        timeouts[ObjectIdentifier(element)] = seconds
    }

    func copyAttribute(_ element: AXUIElement, _ attribute: String) -> (AXError, AnyObject?) {
        let isApp = appElement.map { $0 === element } ?? false
        let isWedged = (wedged == .application && isApp) || (wedged == .window && !isApp)
        if isWedged {
            stalledSeconds += timeouts[ObjectIdentifier(element)] ?? Self.systemDefaultTimeout
            return (.cannotComplete, nil)
        }
        if isApp, attribute == kAXFocusedWindowAttribute {
            return (.success, windowElement)
        }
        return (.attributeUnsupported, nil)
    }
}
