import CoreGraphics
@testable import localvoxtral

/// The real overlay coordinator's panel and focus, for tests that run it
/// without a screen.
@MainActor
final class MockOverlayRenderer: OverlayBufferRendering {
    var snapshots: [OverlayBufferStateMachine.Snapshot?] = []
    var hideCallCount = 0
    var micLevels: [Double] = []

    func updateMicLevel(_ level: Double) {
        micLevels.append(level)
    }

    /// Runs after each render is recorded, for tests that wait for the
    /// panel to show a text.
    var onRender: ((OverlayBufferStateMachine.Snapshot?) -> Void)?

    func render(snapshot: OverlayBufferStateMachine.Snapshot?) {
        snapshots.append(snapshot)
        onRender?(snapshot)
    }

    func hide() {
        hideCallCount += 1
    }
}

@MainActor
final class MockOverlayAnchorResolver: OverlayAnchorResolving {
    var focusedPID: pid_t?
    var anchor = OverlayAnchor(
        targetRect: CGRect(x: 0, y: 0, width: 80, height: 24),
        source: .windowCenter
    )

    func resolveAnchor() -> OverlayAnchor {
        anchor
    }

    func resolveFrontmostAppPID() -> pid_t? {
        focusedPID
    }
}
