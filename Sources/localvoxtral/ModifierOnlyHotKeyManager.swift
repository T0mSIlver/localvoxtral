import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Captures modifier-only key presses (Fn/Globe, Right Command) using
/// a CGEventTap on flagsChanged events. Differentiates tap (quick press+release)
/// from hold (press beyond threshold) to support dual dictation modes.
@MainActor
final class ModifierOnlyHotKeyManager {
    enum ModifierKey: String, CaseIterable, Identifiable, Codable {
        case fn = "fn"
        case rightCommand = "right_command"
        case rightOption = "right_option"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .fn: return "Fn / Globe"
            case .rightCommand: return "Right Command"
            case .rightOption: return "Right Option"
            }
        }
    }

    /// Fired when the modifier key is tapped (pressed and released before hold threshold).
    var onTap: (() -> Void)?
    /// Fired when the modifier key is held past the hold threshold.
    var onHoldStart: (() -> Void)?
    /// Fired when the modifier key is released after a hold.
    var onHoldRelease: (() -> Void)?

    /// Seconds the modifier must be held before it counts as a hold gesture.
    var holdThresholdSeconds: Double = 0.35

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // nonisolated(unsafe) because these are accessed from the CGEventTap callback
    // which runs on a different thread. Access is guarded by the sequential
    // nature of the event tap (one event at a time).
    nonisolated(unsafe) private static var _targetModifier: ModifierKey?
    private nonisolated(unsafe) static var shared: ModifierOnlyHotKeyManager?
    private nonisolated(unsafe) static var isModifierDown = false
    private nonisolated(unsafe) static var wasInterruptedByKey = false
    nonisolated(unsafe) static var _eventTap: CFMachPort?
    private nonisolated(unsafe) static var isInHoldState = false
    private nonisolated(unsafe) static var holdTimerWorkItem: DispatchWorkItem?
    private nonisolated(unsafe) static var _holdThresholdSeconds: Double = 0.35

    func start(modifier: ModifierKey) {
        stop()
        Self._targetModifier = modifier
        Self.shared = self
        Self.isModifierDown = false
        Self.wasInterruptedByKey = false
        Self.isInHoldState = false
        Self._holdThresholdSeconds = holdThresholdSeconds

        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: modifierEventCallback,
            userInfo: nil
        ) else {
            return
        }

        eventTap = tap
        Self._eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        Self.holdTimerWorkItem?.cancel()
        Self.holdTimerWorkItem = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        Self._eventTap = nil
        runLoopSource = nil
        Self._targetModifier = nil
        Self.shared = nil
        Self.isModifierDown = false
        Self.wasInterruptedByKey = false
        Self.isInHoldState = false
    }

    // Called from the CGEventTap callback (not on main thread)
    nonisolated static func handleEvent(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) {
        // macOS disables listen-only taps after focus loss or timeout — re-enable
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = _eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        guard Self.shared != nil, let target = Self._targetModifier else { return }

        if type == .keyDown {
            // A non-modifier key was pressed while our modifier is held.
            // This means it's being used AS a modifier, not tapped alone.
            if isModifierDown {
                wasInterruptedByKey = true
                holdTimerWorkItem?.cancel()
                holdTimerWorkItem = nil
            }
            return
        }

        guard type == .flagsChanged else { return }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        let isTargetDown: Bool
        switch target {
        case .fn:
            isTargetDown = flags.contains(.maskSecondaryFn)
        case .rightCommand:
            // Right Command keycode is 54
            isTargetDown = keyCode == 54 && flags.contains(.maskCommand)
        case .rightOption:
            // Right Option keycode is 61
            isTargetDown = keyCode == 61 && flags.contains(.maskAlternate)
        }

        if isTargetDown && !isModifierDown {
            // Modifier just pressed — start hold timer
            isModifierDown = true
            wasInterruptedByKey = false
            isInHoldState = false

            holdTimerWorkItem?.cancel()
            let workItem = DispatchWorkItem {
                guard Self.isModifierDown, !Self.wasInterruptedByKey else { return }
                Self.isInHoldState = true
                DispatchQueue.main.async {
                    Self.shared?.onHoldStart?()
                }
            }
            holdTimerWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + _holdThresholdSeconds,
                execute: workItem
            )
        } else if !isTargetDown && isModifierDown {
            // Modifier just released
            isModifierDown = false
            holdTimerWorkItem?.cancel()
            holdTimerWorkItem = nil

            if wasInterruptedByKey {
                // Used as a modifier combo — no gesture
                wasInterruptedByKey = false
            } else if isInHoldState {
                // Was holding — fire hold release
                isInHoldState = false
                DispatchQueue.main.async {
                    Self.shared?.onHoldRelease?()
                }
            } else {
                // Released before threshold — tap
                DispatchQueue.main.async {
                    Self.shared?.onTap?()
                }
            }
        }
    }
}

// CGEventTap C callback — forwards to the static handler
private func modifierEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    ModifierOnlyHotKeyManager.handleEvent(proxy, type, event)
    return Unmanaged.passRetained(event)
}
