import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Intercepts Escape key presses during active dictation and consumes them
/// so they don't reach the focused application (e.g. Claude Code), then
/// cancels the active dictation session.
///
/// Uses `.defaultTap` (NOT `.listenOnly`) because only `.defaultTap` can
/// consume events by returning nil from the callback.
///
/// CGEventTap gotchas this handler defends against (all of which silently
/// produce "Escape does nothing, dictation continues"):
/// 1. `CGEvent.tapCreate` returns nil when the process is not
///    Accessibility-trusted *at call time* (e.g. the first session of a
///    freshly launched app, or after a TCC change that needs a relaunch).
///    We gate on `AXIsProcessTrusted()` first so the failure is logged with
///    an actionable message instead of a silent no-op.
/// 2. The tap is added to `CFRunLoopGetMain()` explicitly, so it always lands
///    on the running main run loop regardless of which thread calls `start()`.
/// 3. The system periodically disables an active tap
///    (`tapDisabledByTimeout` / `tapDisabledByUserInput`); we re-enable it from
///    the callback, otherwise Escape interception dies mid-session.
@MainActor
final class EscapeCancelHandler {
    var onCancel: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Shared flag set by DictationViewModel. The CGEventTap callback
    /// runs on the tap's run-loop thread, so this must be nonisolated(unsafe).
    nonisolated(unsafe) static var isDictatingRef = false
    fileprivate nonisolated(unsafe) static var shared: EscapeCancelHandler?

    /// The active tap port, exposed nonisolated so the C callback can
    /// re-enable the tap after the system disables it for timeout/user input.
    /// Cleared by `stop()`.
    fileprivate nonisolated(unsafe) static var activeTap: CFMachPort?

    #if DEBUG
    /// Test-only record of what the last `start()` did. Lets unit tests assert
    /// that a creation failure is recorded deterministically rather than
    /// silently swallowed (the original Escape-cancel bug).
    static var lastStartOutcome: EscapeCancelStartOutcome = .none
    static var startCallCount = 0
    static var stopCallCount = 0

    static func resetDebugState() {
        lastStartOutcome = .none
        startCallCount = 0
        stopCallCount = 0
    }

    @inline(__always) private static func record(_ outcome: EscapeCancelStartOutcome) {
        lastStartOutcome = outcome
    }
    #else
    @inline(__always) private static func record(_: EscapeCancelStartOutcome) {}
    #endif

    func start() {
        #if DEBUG
        Self.startCallCount += 1
        #endif

        stop()
        Self.shared = self

        // (1) Accessibility trust is mandatory for an *active* (consuming)
        // event tap. Checking it here (no prompt) yields a clear, actionable
        // log line instead of a silent nil from tapCreate.
        let trusted = AXIsProcessTrusted()
        guard trusted else {
            Self.record(.notTrusted)
            Log.escape.error(
                "CGEventTap NOT created: process is not Accessibility-trusted. Grant Accessibility in System Settings > Privacy & Security > Accessibility and relaunch localvoxtral. Escape will not cancel dictation until then."
            )
            return
        }

        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        // (2) tapCreate still can return nil right after trust is granted if
        // the process hasn't been relaunched (macOS caches TCC state for the
        // event-tap path). Surface that explicitly.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: escapeTapCallback,
            userInfo: nil
        ) else {
            Self.record(.creationFailedNil)
            Log.escape.error(
                "CGEvent.tapCreate returned nil although AXIsProcessTrusted()==true. This usually means Accessibility was granted while localvoxtral was running; relaunch the app so the event tap can be created. Escape-cancel disabled for this session."
            )
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault, tap, 0
        ) else {
            Self.record(.noRunLoopSource)
            Log.escape.error(
                "CFMachPortCreateRunLoopSource returned nil; Escape events cannot be delivered. Escape-cancel disabled for this session."
            )
            // Nothing was wired to the run loop; drop the orphaned tap.
            CGEvent.tapEnable(tap: tap, enable: false)
            return
        }

        // (3) Pin to the main run loop explicitly: the tap callback is
        // delivered on whichever loop the source is attached to, and only the
        // main loop is guaranteed to be spinning.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        Self.activeTap = tap
        runLoopSource = source
        Self.record(.created)
        Log.escape.info(
            "Escape CGEventTap created and enabled on the main run loop (trusted=\(trusted, privacy: .public))."
        )
    }

    func stop() {
        #if DEBUG
        Self.stopCallCount += 1
        #endif

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        Self.activeTap = nil
        if Self.shared === self {
            Self.shared = nil
        }
    }

    deinit {
        // MainActor deinit — teardown is driven by DictationViewModel via stop().
    }
}

/// What the last `EscapeCancelHandler.start()` call produced. Always defined
/// so `start()`'s `record(_:)` call sites type-check in release; only the
/// mutable record + `resetDebugState()` are DEBUG-gated.
enum EscapeCancelStartOutcome: String, Equatable {
    case none
    case notTrusted
    case creationFailedNil
    case noRunLoopSource
    case created
}

private func escapeTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // The system disables an active tap when it decides the callback was too
    // slow or after certain user-input sequences, then delivers exactly one of
    // these sentinel event types. We MUST re-enable it here, otherwise Escape
    // interception silently stops for the rest of the session.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = EscapeCancelHandler.activeTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            Log.escape.notice(
                "Escape CGEventTap disabled by system (type=\(type.rawValue)); re-enabled."
            )
        } else {
            Log.escape.error(
                "Escape CGEventTap disabled by system (type=\(type.rawValue)) but no active tap is available to re-enable; Escape-cancel inactive until next session."
            )
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard keyCode == Int64(kVK_Escape) else {
        return Unmanaged.passRetained(event)
    }

    guard EscapeCancelHandler.isDictatingRef else {
        // Not dictating — let Escape pass through normally.
        return Unmanaged.passRetained(event)
    }

    // Dictating — consume Escape and trigger cancel on the main actor.
    Log.escape.notice("Escape consumed during active dictation; triggering cancel.")
    DispatchQueue.main.async {
        EscapeCancelHandler.shared?.onCancel?()
    }
    return nil // Consumed — event never reaches focused app.
}
