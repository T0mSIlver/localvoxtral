import AppKit
import XCTest

@testable import localvoxtral

/// TEMPORARY (#1162): builds, shows, hides and releases overlay controllers
/// in a loop, the lifecycle OverlayDestinationClickTests gives each test.
/// Runs only under LV_STRESS_1162=1, from the stress-1162 workflow.
@MainActor
final class OverlayControllerChurnStressTests: XCTestCase {
    private func snapshot(waiting: Int) -> OverlayBufferStateMachine.Snapshot {
        OverlayBufferStateMachine.Snapshot(
            phase: .buffering,
            bufferText: "dictated words",
            errorMessage: nil,
            secureInputActive: false,
            polished: false,
            claudeJoin: .hidden,
            destinations: OverlayDestinationStrip(
                list: DictationDestinationList(
                    waitingSessionIDs: (0..<waiting).map { "s\($0)" }, focusedSessionID: nil),
                focusedAppLabel: "Safari",
                focusedAppJoined: nil,
                sessionName: { _ in "payments" },
                isOpen: true
            ),
            anchor: OverlayAnchor(targetRect: CGRect(x: 400, y: 400, width: 10, height: 10), source: .mouseLocation)
        )
    }

    func testChurn() {
        guard ProcessInfo.processInfo.environment["LV_STRESS_1162"] == "1" else { return }
        let rounds = Int(ProcessInfo.processInfo.environment["LV_STRESS_ROUNDS"] ?? "") ?? 300
        for round in 0..<rounds {
            autoreleasepool {
                let controller = DictationOverlayController(placementWriter: { _ in }, screensProvider: { [] })
                controller.render(snapshot: snapshot(waiting: round % 2 == 0 ? 10 : 1))
                RunLoop.main.run(mode: .default, before: .distantPast)
                controller.clickForTesting(at: NSPoint(x: 30, y: 10))
                controller.hide()
            }
            // Let whatever the released panel left queued run, the way the
            // next test's first run loop turn does.
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: Double(round % 4) * 0.01))
        }
    }
}
