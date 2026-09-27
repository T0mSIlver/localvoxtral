import AppKit
import ApplicationServices
import Foundation
import ShortcutRecorder

/// Fires the action shortcuts set to a modifier-only chord, such as left
/// Shift + right Shift (#831). No Carbon hotkey can express one, so like
/// `ModifierOnlyHotKeyManager` this watches NSEvent flagsChanged and keyDown
/// monitors, which need Accessibility trust. `ModifierChordDetector` decides
/// when a chord fires; this feeds it each event with the event's timestamp.
@MainActor
final class ModifierChordHotKeyMonitor {
    typealias Action = HotKeyManager.ActionHotKey

    var onChord: ((Action) -> Void)?

    private var detectors: [Action: ModifierChordDetector] = [:]
    private var monitors: [Any] = []

    var chords: [Action: ModifierChord] { detectors.mapValues(\.chord) }

    /// Sets the chord for one action, nil to remove it. Installs the event
    /// monitors with the first chord and removes them with the last. False
    /// when the monitors can't be installed; the action then has no chord.
    func setChord(_ chord: ModifierChord?, for action: Action) -> Bool {
        if let chord {
            detectors[action] = ModifierChordDetector(chord: chord)
        } else {
            detectors[action] = nil
        }
        guard !detectors.isEmpty else {
            removeMonitors()
            return true
        }
        guard installMonitorsIfNeeded() else {
            detectors[action] = nil
            if detectors.isEmpty { removeMonitors() }
            return false
        }
        if let chord {
            Log.modifierKeys.notice(
                "\(String(describing: action), privacy: .public) set to the \(chord.storageValue, privacy: .public) chord"
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
    }

    private func handleFlagsChanged(rawFlags: UInt, timestamp: TimeInterval) {
        // Recording a chord in Settings must not also fire the one it replaces.
        if let recorder = NSApp?.keyWindow?.firstResponder as? RecorderControl, recorder.isRecording {
            for action in Array(detectors.keys) { detectors[action]!.reset() }
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
    }

    private func handleKeyDown() {
        for action in Array(detectors.keys) { detectors[action]!.keyPressed() }
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
