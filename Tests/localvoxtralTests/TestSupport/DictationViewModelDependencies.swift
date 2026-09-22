import Foundation
@testable import localvoxtral

extension DictationViewModel {
    /// Makes the commit-time target resolve to `bundleID`: gives the mock
    /// overlay a commit PID (the production lookup runs only with one) and
    /// answers the bundle lookup for it. Unit tests have no running target
    /// app to ask `NSRunningApplication` about.
    @MainActor
    func stubCommitTarget(_ bundleID: @escaping () -> String?) {
        guard let overlay = session.overlayBufferCoordinator as? MockOverlayCoordinator else {
            preconditionFailure("stubCommitTarget needs a MockOverlayCoordinator")
        }
        overlay.commitTargetAppPID = 1
        dependencies.bundleIdentifier = { _ in bundleID() }
    }
}
