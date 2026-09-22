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
    private(set) var reachabilityTransitions: [Bool] = []

    func startDictation(outputMode: DictationOutputMode?) { startedModes.append(outputMode) }
    func endDictation(reason: String) { stopReasons.append(reason) }
    func toggleDictation(outputMode: DictationOutputMode?) { toggledModes.append(outputMode) }
    func clearSecureInputRefusalSignalsIfAttemptEnded() { refusalSignalClears += 1 }
    func overlayReachabilityDidChange(wasReachable: Bool) { reachabilityTransitions.append(wasReachable) }
}
