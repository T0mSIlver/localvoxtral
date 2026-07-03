import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.hid
import Synchronization

/// Captures modifier-only key presses (Fn/Globe, Right Command, Right Option)
/// with a listen-only CGEventTap. A quick tap starts/stops overlay-buffer
/// dictation; holding past the configured threshold starts live auto-paste
/// push-to-talk dictation until the modifier is released.
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

    typealias HoldScheduler =
        @Sendable (_ delay: Double, _ fire: @escaping @Sendable () -> Void) -> Void

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
    private let holdScheduler: HoldScheduler
    private let state = Mutex(ModifierGestureState())

    init(holdScheduler: @escaping HoldScheduler = ModifierOnlyHotKeyManager.defaultHoldScheduler) {
        self.holdScheduler = holdScheduler
    }

    @discardableResult
    func start(modifier: ModifierKey) -> ModifierOnlyHotKeyStartOutcome {
        #if DEBUG
        Self.startCallCount += 1
        if let forcedStartOutcome = Self.forcedStartOutcome {
            stop()
            configureGestureState(modifier: modifier)
            if forcedStartOutcome != .created {
                resetGestureState()
            }
            Self.record(forcedStartOutcome)
            return forcedStartOutcome
        }
        #endif

        stop()
        configureGestureState(modifier: modifier)

        let trusted = AXIsProcessTrusted()
        let inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        Log.modifierHotKey.notice(
            "permission state: AXIsProcessTrusted=\(trusted, privacy: .public) inputMonitoring=\(Self.describeHIDAccess(inputMonitoring), privacy: .public)"
        )

        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: modifierEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            resetGestureState()
            Self.record(.creationFailedNil)
            Log.modifierHotKey.error(
                "Modifier-only CGEvent.tapCreate returned nil (trusted=\(trusted, privacy: .public), inputMonitoring=\(Self.describeHIDAccess(inputMonitoring), privacy: .public)). Modifier-only hotkey disabled; Carbon modifier+key shortcuts are unaffected."
            )
            return .creationFailedNil
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            resetGestureState()
            Self.record(.noRunLoopSource)
            Log.modifierHotKey.error(
                "CFMachPortCreateRunLoopSource returned nil; modifier-only hotkey disabled. Carbon modifier+key shortcuts are unaffected."
            )
            CGEvent.tapEnable(tap: tap, enable: false)
            return .noRunLoopSource
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        state.withLock {
            $0.activeTapAddress = UInt(bitPattern: Unmanaged.passUnretained(tap).toOpaque())
        }
        Self.record(.created)
        Log.modifierHotKey.notice(
            "Modifier-only CGEventTap created and enabled on the main run loop for \(modifier.rawValue, privacy: .public)."
        )
        return .created
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
        resetGestureState()
    }

    deinit {
        // MainActor deinit — teardown is driven by HotKeyManager via stop().
    }

    nonisolated func handleEvent(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableTapAfterSystemDisable(type: type)
            return
        }

        switch type {
        case .keyDown:
            handleKeyDown()
        case .flagsChanged:
            handleFlagsChanged(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                flags: event.flags
            )
        default:
            break
        }
    }

    private nonisolated static func defaultHoldScheduler(
        delay: Double,
        fire: @escaping @Sendable () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: fire)
    }

    private static func describeHIDAccess(_ access: IOHIDAccessType) -> String {
        switch access {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "unknown(\(access.rawValue))"
        }
    }

    private func configureGestureState(modifier: ModifierKey) {
        state.withLock {
            $0.targetModifier = modifier
            $0.holdThresholdSeconds = holdThresholdSeconds
            $0.activeTapAddress = nil
            $0.resetGesture()
        }
    }

    private func resetGestureState() {
        state.withLock { $0.resetAll() }
    }

    private nonisolated func reenableTapAfterSystemDisable(type: CGEventType) {
        let tapAddress = state.withLock { $0.activeTapAddress }
        if let tapAddress,
           let tapPointer = UnsafeMutableRawPointer(bitPattern: tapAddress)
        {
            let tap = Unmanaged<CFMachPort>.fromOpaque(tapPointer).takeUnretainedValue()
            CGEvent.tapEnable(tap: tap, enable: true)
            Log.modifierHotKey.notice(
                "Modifier-only CGEventTap disabled by system (type=\(type.rawValue)); re-enabled."
            )
        } else {
            Log.modifierHotKey.error(
                "Modifier-only CGEventTap disabled by system (type=\(type.rawValue)) but no active tap is available to re-enable."
            )
        }
    }

    private nonisolated func handleKeyDown() {
        state.withLock { state in
            guard state.targetModifier != nil, state.isModifierDown else { return }
            state.wasInterruptedByKey = true
            state.generation &+= 1
        }
    }

    private nonisolated func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) {
        let effect = state.withLock { state -> GestureEffect in
            guard let target = state.targetModifier else { return .none }

            let isTargetDown = Self.isTargetModifierDown(
                target,
                keyCode: keyCode,
                flags: flags
            )

            if isTargetDown && !state.isModifierDown {
                state.isModifierDown = true
                state.wasInterruptedByKey = false
                state.isInHoldState = false
                state.generation &+= 1
                return .scheduleHold(
                    generation: state.generation,
                    delay: state.holdThresholdSeconds
                )
            }

            if !isTargetDown && state.isModifierDown {
                state.isModifierDown = false
                state.generation &+= 1

                if state.wasInterruptedByKey {
                    state.wasInterruptedByKey = false
                    state.isInHoldState = false
                    return .none
                }

                if state.isInHoldState {
                    state.isInHoldState = false
                    return .fire(.holdRelease)
                }

                return .fire(.tap)
            }

            return .none
        }

        perform(effect)
    }

    private nonisolated func handleHoldThresholdElapsed(generation: UInt64) {
        let shouldFire = state.withLock { state -> Bool in
            guard state.targetModifier != nil,
                  state.generation == generation,
                  state.isModifierDown,
                  !state.wasInterruptedByKey,
                  !state.isInHoldState
            else {
                return false
            }
            state.isInHoldState = true
            return true
        }

        guard shouldFire else { return }
        fire(.holdStart)
    }

    private nonisolated func perform(_ effect: GestureEffect) {
        switch effect {
        case .none:
            break
        case .fire(let callback):
            fire(callback)
        case .scheduleHold(let generation, let delay):
            holdScheduler(delay) { [weak self] in
                self?.handleHoldThresholdElapsed(generation: generation)
            }
        }
    }

    private nonisolated func fire(_ callback: GestureCallback) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch callback {
            case .tap:
                self.onTap?()
            case .holdStart:
                self.onHoldStart?()
            case .holdRelease:
                self.onHoldRelease?()
            }
        }
    }

    private nonisolated static func isTargetModifierDown(
        _ target: ModifierKey,
        keyCode: Int64,
        flags: CGEventFlags
    ) -> Bool {
        switch target {
        case .fn:
            return flags.contains(.maskSecondaryFn)
        case .rightCommand:
            return keyCode == Int64(kVK_RightCommand) && flags.contains(.maskCommand)
        case .rightOption:
            return keyCode == Int64(kVK_RightOption) && flags.contains(.maskAlternate)
        }
    }

    #if DEBUG
    static var lastStartOutcome: ModifierOnlyHotKeyStartOutcome = .none
    static var startCallCount = 0
    static var stopCallCount = 0
    static var forcedStartOutcome: ModifierOnlyHotKeyStartOutcome?

    static func resetDebugState() {
        lastStartOutcome = .none
        startCallCount = 0
        stopCallCount = 0
        forcedStartOutcome = nil
    }

    func debugStartGestureForTesting(modifier: ModifierKey) {
        configureGestureState(modifier: modifier)
        Self.record(.created)
    }

    func debugHandleKeyDownForTesting() {
        handleKeyDown()
    }

    func debugHandleFlagsChangedForTesting(keyCode: Int64, flags: CGEventFlags) {
        handleFlagsChanged(keyCode: keyCode, flags: flags)
    }

    func debugGestureSnapshotForTesting() -> ModifierOnlyHotKeyDebugSnapshot {
        state.withLock {
            ModifierOnlyHotKeyDebugSnapshot(
                targetModifier: $0.targetModifier,
                isModifierDown: $0.isModifierDown,
                wasInterruptedByKey: $0.wasInterruptedByKey,
                isInHoldState: $0.isInHoldState,
                generation: $0.generation
            )
        }
    }

    @inline(__always) private static func record(_ outcome: ModifierOnlyHotKeyStartOutcome) {
        lastStartOutcome = outcome
    }
    #else
    @inline(__always) private static func record(_: ModifierOnlyHotKeyStartOutcome) {}
    #endif
}

private struct ModifierGestureState {
    var targetModifier: ModifierOnlyHotKeyManager.ModifierKey?
    var holdThresholdSeconds = 0.35
    var activeTapAddress: UInt?
    var isModifierDown = false
    var wasInterruptedByKey = false
    var isInHoldState = false
    var generation: UInt64 = 0

    mutating func resetGesture() {
        isModifierDown = false
        wasInterruptedByKey = false
        isInHoldState = false
        generation &+= 1
    }

    mutating func resetAll() {
        targetModifier = nil
        holdThresholdSeconds = 0.35
        activeTapAddress = nil
        resetGesture()
    }
}

private enum GestureEffect {
    case none
    case scheduleHold(generation: UInt64, delay: Double)
    case fire(GestureCallback)
}

private enum GestureCallback {
    case tap
    case holdStart
    case holdRelease
}

enum ModifierOnlyHotKeyStartOutcome: String, Equatable {
    case none
    case creationFailedNil
    case noRunLoopSource
    case created
}

#if DEBUG
struct ModifierOnlyHotKeyDebugSnapshot: Equatable {
    var targetModifier: ModifierOnlyHotKeyManager.ModifierKey?
    var isModifierDown: Bool
    var wasInterruptedByKey: Bool
    var isInHoldState: Bool
    var generation: UInt64
}
#endif

private func modifierEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passRetained(event)
    }

    let manager = Unmanaged<ModifierOnlyHotKeyManager>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    manager.handleEvent(type, event)
    return Unmanaged.passRetained(event)
}
