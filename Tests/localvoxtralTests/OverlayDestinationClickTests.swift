import AppKit
import XCTest

@testable import localvoxtral

/// A click on a destination pill in the overlay panel picks that pill
/// (#880). The panel swallows every click to keep the target app's focus,
/// so the controller finds the pill from the frames the view reports; these
/// tests click the rendered panel where each pill is drawn.
@MainActor
final class OverlayDestinationClickTests: XCTestCase {
    private var controller: DictationOverlayController!
    private var clicked: [DictationDestination] = []

    /// A panel listening with one session waiting. Synchronous: the run
    /// loop turn below is unavailable from async code.
    private func showPanel() {
        controller = DictationOverlayController(
            placementWriter: { _ in },
            screensProvider: { [] }
        )
        clicked = []
        controller.onDestinationClick = { [weak self] in self?.clicked.append($0) }
        let strip = OverlayDestinationStrip(
            list: DictationDestinationList(waitingSessionIDs: ["pay"], focusedSessionID: nil),
            focusedAppLabel: "Safari",
            focusedAppJoined: nil,
            sessionName: { _ in "payments" }
        )
        controller.render(snapshot: OverlayBufferStateMachine.Snapshot(
            phase: .buffering,
            bufferText: "dictated words",
            errorMessage: nil,
            secureInputActive: false,
            polished: false,
            claudeJoin: .hidden,
            destinations: strip,
            anchor: OverlayAnchor(targetRect: CGRect(x: 400, y: 400, width: 10, height: 10), source: .mouseLocation)
        ))
        // The view reports its frames once SwiftUI has laid out; this
        // handles what is pending and returns without waiting on the clock.
        RunLoop.main.run(mode: .default, before: .distantPast)
    }

    override func tearDown() async throws {
        controller?.hide()
        controller = nil
    }

    /// Where a pill is drawn, as a point in the panel's content view
    /// (bottom-left origin), which is what a mouse event carries.
    private func center(of destination: DictationDestination, file: StaticString = #filePath, line: UInt = #line) throws -> NSPoint {
        let frame = try XCTUnwrap(
            controller.destinationFramesForTesting[destination], "no frame for \(destination)", file: file, line: line)
        return NSPoint(x: frame.midX, y: controller.contentHeightForTesting - frame.midY)
    }

    func testAClickOnEachPillPicksIt() throws {
        showPanel()
        let all: [DictationDestination] = [.focusedApp, .session(id: "pay"), .inbox]
        let frames = controller.destinationFramesForTesting
        XCTAssertEqual(Set(frames.keys), Set(all))
        // Left to right in list order, in the header line.
        let minXs = all.compactMap { frames[$0]?.minX }
        XCTAssertEqual(minXs, minXs.sorted())
        for frame in frames.values {
            XCTAssertLessThan(frame.maxY, controller.contentHeightForTesting / 2, "\(frame) is in the top line")
        }

        for destination in all {
            controller.clickForTesting(at: try center(of: destination))
        }
        XCTAssertEqual(clicked, all)
    }

    /// A drag that starts on a pill moves the panel and picks nothing, and
    /// a click on the transcript picks nothing.
    func testADragOrAClickOffThePillsPicksNothing() throws {
        showPanel()
        controller.dragForTesting(at: try center(of: .inbox))
        controller.clickForTesting(at: NSPoint(x: 30, y: 10))
        XCTAssertEqual(clicked, [])
    }
}
