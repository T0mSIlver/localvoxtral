import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Captures modifier-only key presses (Fn/Globe, Right Command) using
/// a CGEventTap on flagsChanged events.
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

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    nonisolated(unsafe) private static var _targetModifier: ModifierKey?
    private nonisolated(unsafe) static var shared: ModifierOnlyHotKeyManager?
    private nonisolated(unsafe) static var isModifierDown = false
    private nonisolated(unsafe) static var wasInterruptedByKey = false
    nonisolated(unsafe) static var _eventTap: CFMachPort?

    func start(modifier: ModifierKey) {
        stop()
        Self._targetModifier = modifier
        Self.shared = self
        Self.isModifierDown = false
        Self.wasInterruptedByKey = false

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
    }

    nonisolated static func handleEvent(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = _eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        guard Self.shared != nil, let target = Self._targetModifier else { return }

        if type == .keyDown {
            if isModifierDown {
                wasInterruptedByKey = true
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
            isTargetDown = keyCode == 54 && flags.contains(.maskCommand)
        case .rightOption:
            isTargetDown = keyCode == 61 && flags.contains(.maskAlternate)
        }

        if isTargetDown && !isModifierDown {
            isModifierDown = true
            wasInterruptedByKey = false
            DispatchQueue.main.async {
                Self.shared?.onPress?()
            }
        } else if !isTargetDown && isModifierDown {
            isModifierDown = false
            if wasInterruptedByKey {
                wasInterruptedByKey = false
            } else {
                DispatchQueue.main.async {
                    Self.shared?.onRelease?()
                }
            }
        }
    }
}

private func modifierEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    ModifierOnlyHotKeyManager.handleEvent(proxy, type, event)
    return Unmanaged.passRetained(event)
}
