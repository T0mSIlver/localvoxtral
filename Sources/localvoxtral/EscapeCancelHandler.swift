import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Intercepts Escape key presses during active dictation and consumes them
/// so they don't reach the focused application (e.g., Claude Code).
///
/// Uses `.defaultTap` (NOT `.listenOnly`) because only `.defaultTap` can
/// consume events by returning nil from the callback.
@MainActor
final class EscapeCancelHandler {
    var onCancel: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Shared flag set by DictationViewModel. The CGEventTap callback
    /// runs on a different thread, so this must be nonisolated(unsafe).
    nonisolated(unsafe) static var isDictatingRef = false
    fileprivate nonisolated(unsafe) static var shared: EscapeCancelHandler?

    func start() {
        stop()
        Self.shared = self

        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: escapeTapCallback,
            userInfo: nil
        ) else {
            return
        }

        eventTap = tap
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
        runLoopSource = nil
        if Self.shared === self {
            Self.shared = nil
        }
    }

    deinit {
        // MainActor deinit — safe to access instance state
    }
}

private func escapeTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type == .keyDown else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard keyCode == Int64(kVK_Escape) else {
        return Unmanaged.passRetained(event)
    }

    guard EscapeCancelHandler.isDictatingRef else {
        // Not dictating — let Escape pass through normally
        return Unmanaged.passRetained(event)
    }

    // Dictating — consume Escape and trigger cancel
    DispatchQueue.main.async {
        EscapeCancelHandler.shared?.onCancel?()
    }
    return nil // Consumed — event never reaches focused app
}
