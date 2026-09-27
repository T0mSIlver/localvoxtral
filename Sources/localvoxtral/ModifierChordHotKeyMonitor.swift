import AppKit
import ApplicationServices
import Foundation
import ShortcutRecorder

/// Fires the action shortcuts set to a modifier-only chord, such as left
/// Shift + right Shift (#831), and the dictation key set to one (#863). No
/// Carbon hotkey can express one, so like `ModifierOnlyHotKeyManager` this
/// watches NSEvent flagsChanged and keyDown monitors, which need
/// Accessibility trust. `ModifierChordDetector` decides when an action chord
/// fires and `ModifierChordGesture` whether the dictation chord is a tap or a
/// hold; this feeds them each event with the event's timestamp.
@MainActor
final class ModifierChordHotKeyMonitor {
    typealias Action = HotKeyManager.ActionHotKey

    var onChord: ((Action) -> Void)?
    /// The dictation chord was tapped: a toggle.
    var onDictationTap: (() -> Void)?
    /// The dictation chord is still down after the hold delay: push to talk.
    var onDictationHoldStart: (() -> Void)?
    var onDictationHoldEnd: (() -> Void)?
    /// Runs the hold delay. Tests replace it to play the timer.
    var holdScheduler: ModifierOnlyHotKeyManager.HoldScheduler = ModifierOnlyHotKeyManager.defaultHoldScheduler

    private var detectors: [Action: ModifierChordDetector] = [:]
    private var dictationGesture: ModifierChordGesture?
    private var holdDelay = 0.35
    private var monitors: [Any] = []

    var chords: [Action: ModifierChord] { detectors.mapValues(\.chord) }
    var dictationChord: ModifierChord? { dictationGesture?.chord }
    private var hasAnyChord: Bool { !detectors.isEmpty || dictationGesture != nil }

    /// Sets the chord for one action, nil to remove it. Installs the event
    /// monitors with the first chord and removes them with the last. False
    /// when the monitors can't be installed; the action then has no chord.
    func setChord(_ chord: ModifierChord?, for action: Action) -> Bool {
        if let chord {
            detectors[action] = ModifierChordDetector(chord: chord)
        } else {
            detectors[action] = nil
        }
        guard hasAnyChord else {
            removeMonitors()
            return true
        }
        guard installMonitorsIfNeeded() else {
            detectors[action] = nil
            if !hasAnyChord { removeMonitors() }
            return false
        }
        if let chord {
            Log.modifierKeys.notice(
                "\(String(describing: action), privacy: .public) set to the \(chord.storageValue, privacy: .public) chord"
            )
        }
        return true
    }

    /// Sets the dictation key's chord, nil to remove it, under the rules of
    /// `setChord`. A hold in progress ends without `onDictationHoldEnd`, as
    /// when the single-modifier gesture stops.
    func setDictationChord(_ chord: ModifierChord?, holdDelay: Double) -> Bool {
        dictationGesture = chord.map { ModifierChordGesture(chord: $0) }
        self.holdDelay = holdDelay
        guard hasAnyChord else {
            removeMonitors()
            return true
        }
        guard installMonitorsIfNeeded() else {
            dictationGesture = nil
            if !hasAnyChord { removeMonitors() }
            return false
        }
        if let chord {
            Log.modifierKeys.notice(
                "dictation key set to the \(chord.storageValue, privacy: .public) chord, hold delay \(Int(holdDelay * 1000), privacy: .public) ms"
            )
        }
        return true
    }

    private func installMonitorsIfNeeded() -> Bool {
        guard monitors.isEmpty else { return true }
        #if DEBUG
        if Self.debugForceInstallFailure { return false }
        // Same pin as ModifierOnlyHotKeyManager: the runner's Accessibility
        // grant must not decide a unit test. Tests drive the debug entry points.
        if TerminalTargetDetector.isRunningUnderXCTest {
            monitors = [Self.xctestMonitorToken]
            return true
        }
        #endif
        guard AXIsProcessTrusted() else {
            Log.modifierKeys.error(
                "Accessibility trust is required for modifier-chord shortcuts; chord not installed.")
            return false
        }

        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            let flags = event.modifierFlags.rawValue
            let time = event.timestamp
            MainActor.assumeIsolated { self?.handleFlagsChanged(rawFlags: flags, timestamp: time) }
        }
        let keyDownHandler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.handleKeyDown() }
        }
        let installed: [Any?] = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flagsHandler($0); return $0 },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyDownHandler),
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { keyDownHandler($0); return $0 },
        ]
        monitors = installed.compactMap { $0 }
        guard monitors.count == installed.count else {
            Log.modifierKeys.error("Unable to install the modifier-chord NSEvent monitors.")
            removeMonitors()
            return false
        }
        Log.modifierKeys.notice("Installed the modifier-chord NSEvent monitors.")
        return true
    }

    private func removeMonitors() {
        for monitor in monitors {
            #if DEBUG
            if (monitor as? String) == Self.xctestMonitorToken { continue }
            #endif
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        for action in detectors.keys { detectors[action]?.reset() }
        dictationGesture?.reset()
    }

    private func handleFlagsChanged(rawFlags: UInt, timestamp: TimeInterval) {
        // Recording a chord in Settings must not also fire the one it replaces.
        if let recorder = NSApp?.keyWindow?.firstResponder as? RecorderControl, recorder.isRecording {
            for action in Array(detectors.keys) { detectors[action]!.reset() }
            dictationGesture?.reset()
            return
        }
        let held = SidedModifier.held(inDeviceFlags: rawFlags)
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        let otherHeld = flags.contains(.function) || flags.contains(.capsLock)
        for action in Array(detectors.keys) {
            let outcome = detectors[action]!.modifiersChanged(
                held: held, otherModifierHeld: otherHeld, at: timestamp)
            switch outcome {
            case .none:
                break
            case .armed(let gap):
                Log.modifierKeys.notice(
                    "chord for \(String(describing: action), privacy: .public): all keys down, gap \(Int(gap * 1000), privacy: .public) ms"
                )
            case .tooSlow(let gap):
                Log.modifierKeys.notice(
                    "chord for \(String(describing: action), privacy: .public): gap \(Int(gap * 1000), privacy: .public) ms is over the window, ignored"
                )
            case .fire:
                Log.modifierKeys.notice("chord for \(String(describing: action), privacy: .public) fired")
                onChord?(action)
            }
        }
        if let outcome = dictationGesture?.modifiersChanged(
            held: held, otherModifierHeld: otherHeld, at: timestamp)
        {
            handleDictation(outcome)
        }
    }

    private func handleKeyDown() {
        for action in Array(detectors.keys) { detectors[action]!.keyPressed() }
        if let outcome = dictationGesture?.keyPressed() { handleDictation(outcome) }
    }

    private func handleDictation(_ outcome: ModifierChordGesture.Outcome) {
        switch outcome {
        case .none:
            break
        case .armed(let gap, let attempt):
            Log.modifierKeys.notice(
                "dictation chord: all keys down, gap \(Int(gap * 1000), privacy: .public) ms")
            holdScheduler(holdDelay) { [weak self] in
                guard let self, let outcome = self.dictationGesture?.holdDelayElapsed(attempt: attempt) else { return }
                self.handleDictation(outcome)
            }
        case .tooSlow(let gap):
            Log.modifierKeys.notice(
                "dictation chord: gap \(Int(gap * 1000), privacy: .public) ms is over the window, ignored")
        case .tap:
            Log.modifierKeys.notice("dictation chord tapped")
            onDictationTap?()
        case .holdStart:
            Log.modifierKeys.notice("dictation chord held: push to talk starts")
            onDictationHoldStart?()
        case .holdEnd:
            Log.modifierKeys.notice("dictation chord hold ended")
            onDictationHoldEnd?()
        }
    }

    #if DEBUG
    private static let xctestMonitorToken = "xctest"
    /// Stands in for a missing Accessibility grant.
    static var debugForceInstallFailure = false

    func debugHandleFlagsChangedForTesting(held: Set<SidedModifier>, timestamp: TimeInterval) {
        let raw = held.reduce(UInt(0)) { $0 | $1.deviceFlag }
        handleFlagsChanged(rawFlags: raw, timestamp: timestamp)
    }

    func debugHandleKeyDownForTesting() {
        handleKeyDown()
    }
    #endif
}
