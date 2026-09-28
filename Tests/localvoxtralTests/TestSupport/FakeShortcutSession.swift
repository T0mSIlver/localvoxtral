import Foundation
@testable import localvoxtral

/// A session for `ShortcutController` that keeps state and records every
/// call. Its status and error tokens derive from the strings the controller
/// wrote, the way the view model's do.
@MainActor
final class FakeShortcutSession: ShortcutSessionControlling {
    var isDictating = false
    var isConnectingRealtimeSession = false
    var isFinalizingStop = false
    var isAwaitingMicrophonePermission = false
    var isAccessibilityTrusted = true
    /// A start makes `isDictating` true and a stop false, as a session that
    /// connects at once would.
    var startDictationSucceeds = false
    var statusText = "Ready"
    var lastError: String?
    var currentStatusToken: DictationViewModel.StatusToken { .from(statusText) }
    var currentErrorToken: DictationViewModel.ErrorToken? {
        lastError.map { .from($0) }
    }

    private(set) var startedModes: [DictationOutputMode?] = []
    private(set) var stopReasons: [String] = []
    private(set) var toggledModes: [DictationOutputMode?] = []
    private(set) var refusalSignalClears = 0
    private(set) var copyLastDictationCalls = 0
    private(set) var answerAgentCalls = 0

    func startDictation(outputMode: DictationOutputMode?) {
        startedModes.append(outputMode)
        if startDictationSucceeds { isDictating = true }
    }
    func endDictation(reason: String) {
        stopReasons.append(reason)
        if startDictationSucceeds { isDictating = false }
    }
    func toggleDictation(outputMode: DictationOutputMode?) { toggledModes.append(outputMode) }
    func clearSecureInputRefusalSignalsIfAttemptEnded() { refusalSignalClears += 1 }
    func overlayReachabilityDidChange(wasReachable: Bool) {}
    func copyLastDictation() { copyLastDictationCalls += 1 }
    func answerAgentThatNeedsYou() { answerAgentCalls += 1 }
    private(set) var toggleQuickCaptureCalls = 0
    func toggleQuickCapture() { toggleQuickCaptureCalls += 1 }
}
