import AppKit
import XCTest

@testable import localvoxtral

/// A click on a destination in the overlay panel picks it (#880): the
/// header pill while the list is closed, a row while it is open (#1015).
/// The panel swallows every click to keep the target app's focus, so the
/// controller finds the destination from the frames the view reports; these
/// tests click the rendered panel where each one is drawn.
@MainActor
final class OverlayDestinationClickTests: XCTestCase {
    private var controller: DictationOverlayController!
    private var clicked: [DictationDestination] = []

    /// A panel listening with one session waiting, its list open or not.
    /// Synchronous: the run loop turn below is unavailable from async code.
    private func showPanel(open: Bool) {
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
            sessionName: { _ in "payments" },
            isOpen: open
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
    private func center(
        of destination: DictationDestination, inList: Bool, file: StaticString = #filePath, line: UInt = #line
    ) throws -> NSPoint {
        let frame = try XCTUnwrap(
            controller.destinationFramesForTesting(inList: inList)[destination], "no frame for \(destination)",
            file: file, line: line)
        return NSPoint(x: frame.midX, y: controller.contentHeightForTesting - frame.midY)
    }

    /// Closed, the header shows only the picked destination, and a click
    /// on it reports it: the session controller then opens the list.
    func testClosedTheHeaderPillIsTheOnlyTarget() throws {
        showPanel(open: false)
        XCTAssertEqual(Array(controller.destinationFramesForTesting(inList: false).keys), [.focusedApp])
        XCTAssertEqual(controller.destinationFramesForTesting(inList: true), [:])
        let pill = try XCTUnwrap(controller.destinationFramesForTesting(inList: false)[.focusedApp])
        XCTAssertLessThan(pill.maxY, controller.contentHeightForTesting / 3, "\(pill) is in the header")

        controller.clickForTesting(at: try center(of: .focusedApp, inList: false))
        XCTAssertEqual(clicked, [.focusedApp])
    }

    /// Open, one row per destination under the header, top to bottom in
    /// list order, and a click on each picks it.
    func testOpenAClickOnEachRowPicksIt() throws {
        showPanel(open: true)
        let all: [DictationDestination] = [.focusedApp, .inbox, .session(id: "pay")]
        let frames = controller.destinationFramesForTesting(inList: true)
        XCTAssertEqual(Set(frames.keys), Set(all))
        XCTAssertEqual(controller.destinationFramesForTesting(inList: false), [:], "the header pill makes way")
        let minYs = all.compactMap { frames[$0]?.minY }
        XCTAssertEqual(minYs, minYs.sorted())
        XCTAssertEqual(Set(minYs).count, all.count, "one row each")

        for destination in all {
            controller.clickForTesting(at: try center(of: destination, inList: true))
        }
        XCTAssertEqual(clicked, all)
    }

    /// A drag that starts on a row moves the panel and picks nothing, and
    /// a click on the transcript picks nothing.
    func testADragOrAClickOffTheRowsPicksNothing() throws {
        showPanel(open: true)
        controller.dragForTesting(at: try center(of: .inbox, inList: true))
        controller.clickForTesting(at: NSPoint(x: 30, y: 10))
        XCTAssertEqual(clicked, [])
    }
}
