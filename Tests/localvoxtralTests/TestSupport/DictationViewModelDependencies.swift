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

/// What a view model wrote to the clipboard, in order.
@MainActor
final class PasteboardWrites {
    fileprivate(set) var values: [String] = []
}

extension DictationViewModel {
    /// Records every clipboard write instead of making it; `onWrite` runs
    /// after each.
    @MainActor
    func recordPasteboardWrites(onWrite: @escaping @MainActor () -> Void = {}) -> PasteboardWrites {
        let written = PasteboardWrites()
        dependencies.pasteboardWriter = {
            written.values.append($0)
            onWrite()
        }
        return written
    }
}
