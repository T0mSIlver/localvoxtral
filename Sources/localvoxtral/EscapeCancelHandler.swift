import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.hid
import os

/// Intercepts Escape key presses during active dictation and consumes them
/// so they don't reach the focused application (e.g. Claude Code), then
/// cancels the active dictation session.
///
/// Escape is registered as a Carbon hotkey only for the active dictation
/// session. Carbon hotkeys do not require Input Monitoring, and because the
/// registration itself consumes the key system-wide, no extra "is dictating"
/// callback gate is needed.
@MainActor
final class EscapeCancelHandler {
    var onCancel: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var isRegistered = false

    private static let hotKeySignature = OSType(0x4C564563) // LVEc
    private static let hotKeyID = UInt32(1)
    private nonisolated(unsafe) static weak var hotKeyTarget: EscapeCancelHandler?

    #if DEBUG
    /// Test-only record of what the last `start()` did. Lets unit tests assert
    /// that registration failures are recorded deterministically rather than
    /// silently swallowed.
    static var lastStartOutcome: EscapeCancelStartOutcome = .none
    static var startCallCount = 0
    static var stopCallCount = 0
    static var registrationCallCount = 0
    static var unregistrationCallCount = 0
    private static var debugRegisterStatus: OSStatus?

    static func resetDebugState() {
        lastStartOutcome = .none
        startCallCount = 0
        stopCallCount = 0
        registrationCallCount = 0
        unregistrationCallCount = 0
        debugRegisterStatus = nil
    }

    static func debugConfigureRegistration(status: OSStatus?) {
        debugRegisterStatus = status
    }

    @inline(__always) private static func record(_ outcome: EscapeCancelStartOutcome) {
        lastStartOutcome = outcome
    }
    #else
    @inline(__always) private static func record(_: EscapeCancelStartOutcome) {}
    #endif

    private static func describeHIDAccess(_ access: IOHIDAccessType) -> String {
        switch access {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "unknown(\(access.rawValue))"
        }
    }

    /// Diagnostic-only probe of the host's live permission state. Pinned off
    /// under XCTest: the unit suite must never sample live TCC state (PR #188
    /// review finding — same invariant as the AccessibilityTrustManager and
    /// ModifierOnlyHotKeyManager pins). Registration below stays REAL either
    /// way: Carbon hotkeys are trust-independent, so pinning only the probe
    /// keeps the existing registration coverage.
    private func logLivePermissionState() {
        #if DEBUG
        if TerminalTargetDetector.isRunningUnderXCTest { return }
        #endif
        let trusted = AXIsProcessTrusted()
        let inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        Log.escape.notice(
            "permission state: AXIsProcessTrusted=\(trusted, privacy: .public) inputMonitoring=\(Self.describeHIDAccess(inputMonitoring), privacy: .public)"
        )
    }

    func start() {
        #if DEBUG
        Self.startCallCount += 1
        #endif

        logLivePermissionState()

        guard !isRegistered else {
            Self.record(.registered)
            Log.escape.notice("Escape Carbon hotkey already registered for this dictation session.")
            return
        }

        switch registerEscapeHotKey() {
        case .registered:
            isRegistered = true
            Self.hotKeyTarget = self
            Self.record(.registered)
            Log.escape.notice("Escape Carbon hotkey registered for active dictation session.")
        case .handlerInstallFailed(let status):
            Self.record(.handlerInstallFailed(status))
            cleanupCarbonHotKeyRegistration()
            Log.escape.error(
                "Escape Carbon hotkey handler install failed with OSStatus \(status, privacy: .public); Escape-cancel disabled for this session."
            )
        case .registrationFailed(let status):
            Self.record(.registrationFailed(status))
            cleanupCarbonHotKeyRegistration()
            Log.escape.error(
                "RegisterEventHotKey for Escape failed with OSStatus \(status, privacy: .public); Escape-cancel disabled for this session."
            )
        }
    }

    func stop() {
        #if DEBUG
        Self.stopCallCount += 1
        #endif

        guard isRegistered || hotKeyRef != nil || hotKeyHandlerRef != nil else {
            if Self.hotKeyTarget === self {
                Self.hotKeyTarget = nil
            }
            return
        }

        #if DEBUG
        Self.unregistrationCallCount += 1
        #endif

        cleanupCarbonHotKeyRegistration()
    }

    deinit {
        // MainActor deinit — teardown is driven by DictationViewModel via stop().
    }

    private func registerEscapeHotKey() -> CarbonRegistrationResult {
        #if DEBUG
        Self.registrationCallCount += 1
        if let debugRegisterStatus = Self.debugRegisterStatus {
            return debugRegisterStatus == noErr
                ? .registered
                : .registrationFailed(debugRegisterStatus)
        }
        #endif

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
        ]

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ in
                // Returning noErr marks a Carbon event as HANDLED and stops
                // propagation — HotKeyManager's handler shares this event
                // target, so any hotkey that is not ours must be passed on
                // with eventNotHandledErr or the dictation shortcut goes dead
                // while Escape-cancel is armed.
                guard let eventRef else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == EscapeCancelHandler.hotKeySignature,
                      hotKeyID.id == EscapeCancelHandler.hotKeyID
                else {
                    return OSStatus(eventNotHandledErr)
                }

                DispatchQueue.main.async {
                    EscapeCancelHandler.hotKeyTarget?.handleEscapePressed()
                }

                return noErr
            },
            eventTypes.count,
            &eventTypes,
            nil,
            &hotKeyHandlerRef
        )

        guard installStatus == noErr else {
            return .handlerInstallFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: Self.hotKeyID
        )
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            return .registrationFailed(registerStatus)
        }

        return .registered
    }

    private func cleanupCarbonHotKeyRegistration() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }

        isRegistered = false
        if Self.hotKeyTarget === self {
            Self.hotKeyTarget = nil
        }
    }

    private func handleEscapePressed() {
        Log.escape.notice("Escape consumed during active dictation; triggering cancel.")
        onCancel?()
    }
}

private enum CarbonRegistrationResult: Equatable {
    case registered
    case handlerInstallFailed(OSStatus)
    case registrationFailed(OSStatus)
}

/// What the last `EscapeCancelHandler.start()` call produced. Always defined
/// so `start()`'s `record(_:)` call sites type-check in release; only the
/// mutable record + `resetDebugState()` are DEBUG-gated.
enum EscapeCancelStartOutcome: Equatable, CustomStringConvertible {
    case none
    case registered
    case handlerInstallFailed(OSStatus)
    case registrationFailed(OSStatus)

    var description: String {
        switch self {
        case .none:
            return "none"
        case .registered:
            return "registered"
        case .handlerInstallFailed(let status):
            return "handlerInstallFailed(\(status))"
        case .registrationFailed(let status):
            return "registrationFailed(\(status))"
        }
    }
}
