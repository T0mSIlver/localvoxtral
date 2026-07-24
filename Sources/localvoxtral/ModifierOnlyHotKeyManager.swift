import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.hid

/// Captures modifier-only key presses (Fn/Globe, Right Command, Right Option)
/// with NSEvent monitors. A quick tap starts/stops overlay-buffer dictation;
/// holding past the configured threshold starts live auto-paste push-to-talk
/// dictation until the modifier is released.
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
        @MainActor (_ delay: Double, _ fire: @escaping @MainActor @Sendable () -> Void) -> Void

    /// Fired when the modifier key is tapped (pressed and released before hold threshold).
    var onTap: (() -> Void)?
    /// Fired when the modifier key is held past the hold threshold.
    var onHoldStart: (() -> Void)?
    /// Fired when the modifier key is released after a hold.
    var onHoldRelease: (() -> Void)?

    /// Seconds the modifier must be held before it counts as a hold gesture.
    var holdThresholdSeconds: Double = 0.35

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    private let holdScheduler: HoldScheduler
    private var state = ModifierGestureState()
    private var loggedFlagsDelivery = false
    private var loggedKeyDownDelivery = false

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
        // Unpinned, the live path below samples the HOST's Accessibility
        // grant to the test runner — a runner auto-update swaps its bundled
        // node binary and silently invalidates that grant, which turned the
        // whole unit suite red (2026-07-24; same class as the locked-screen
        // seams pinned in TerminalTargetDetector, PR #122). Under XCTest the
        // registration resolves to a fixed success without installing real
        // NSEvent monitors; tests exercising failure outcomes pin
        // `forcedStartOutcome` above, and gesture logic drives the
        // debug*ForTesting entry points directly.
        if TerminalTargetDetector.isRunningUnderXCTest {
            stop()
            configureGestureState(modifier: modifier)
            Self.record(.created)
            return .created
        }
        #endif

        stop()
        configureGestureState(modifier: modifier)

        let trusted = AXIsProcessTrusted()
        let inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        Log.modifierKeys.notice(
            "permission state: AXIsProcessTrusted=\(trusted, privacy: .public) inputMonitoring=\(Self.describeHIDAccess(inputMonitoring), privacy: .public)"
        )

        guard trusted else {
            resetGestureState()
            Self.record(.monitorInstallationFailed)
            Log.modifierKeys.error(
                "Accessibility trust is required for modifier-only global NSEvent monitors; modifier-only hotkey disabled. Carbon modifier+key shortcuts are unaffected."
            )
            return .monitorInstallationFailed
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            let keyCode = event.keyCode
            let rawFlags = event.modifierFlags.rawValue
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(
                    keyCode: keyCode,
                    flags: NSEvent.ModifierFlags(rawValue: rawFlags),
                    source: .global
                )
            }
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            let keyCode = event.keyCode
            let rawFlags = event.modifierFlags.rawValue
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(
                    keyCode: keyCode,
                    flags: NSEvent.ModifierFlags(rawValue: rawFlags),
                    source: .local
                )
            }
            return event
        }

        guard globalFlagsMonitor != nil, localFlagsMonitor != nil else {
            removeEventMonitors()
            resetGestureState()
            Self.record(.monitorInstallationFailed)
            Log.modifierKeys.error(
                "Unable to install required modifier-only flagsChanged NSEvent monitors; modifier-only hotkey disabled. Carbon modifier+key shortcuts are unaffected."
            )
            return .monitorInstallationFailed
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleKeyDown(source: .global)
            }
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyDown(source: .local)
            }
            return event
        }

        Log.modifierKeys.notice(
            "Installed modifier-only NSEvent monitors for \(modifier.rawValue, privacy: .public): flagsChanged global=\(self.globalFlagsMonitor != nil, privacy: .public) local=\(self.localFlagsMonitor != nil, privacy: .public), keyDown global=\(self.globalKeyDownMonitor != nil, privacy: .public) local=\(self.localKeyDownMonitor != nil, privacy: .public)."
        )
        if globalKeyDownMonitor == nil || localKeyDownMonitor == nil {
            Log.modifierKeys.notice(
                "Modifier-only keyDown monitor installation incomplete; modifier-used-as-real-modifier cancellation will degrade to flagsChanged-only inference."
            )
        }

        Self.record(.created)
        return .created
    }

    func stop() {
        #if DEBUG
        Self.stopCallCount += 1
        #endif

        removeEventMonitors()
        resetGestureState()
    }

    deinit {
        // MainActor deinit - teardown is driven by HotKeyManager via stop().
    }

    private static func defaultHoldScheduler(
        delay: Double,
        fire: @escaping @MainActor @Sendable () -> Void
    ) {
        let nanoseconds = UInt64(max(delay, 0) * 1_000_000_000)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanoseconds)
            fire()
        }
    }

    private static func describeHIDAccess(_ access: IOHIDAccessType) -> String {
        switch access {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "unknown(\(access.rawValue))"
        }
    }

    private func configureGestureState(modifier: ModifierKey) {
        state.targetModifier = modifier
        state.holdThresholdSeconds = holdThresholdSeconds
        state.resetGesture()
        loggedFlagsDelivery = false
        loggedKeyDownDelivery = false
    }

    private func resetGestureState() {
        state.resetAll()
        loggedFlagsDelivery = false
        loggedKeyDownDelivery = false
    }

    private func removeEventMonitors() {
        let monitors = [
            globalFlagsMonitor,
            localFlagsMonitor,
            globalKeyDownMonitor,
            localKeyDownMonitor,
        ]
        for monitor in monitors.compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyDownMonitor = nil
        localKeyDownMonitor = nil
    }

    private func handleKeyDown(source: ModifierEventSource) {
        if !loggedKeyDownDelivery {
            loggedKeyDownDelivery = true
            Log.modifierKeys.notice(
                "Modifier-only keyDown NSEvent monitor delivered first event from \(source.rawValue, privacy: .public)."
            )
        }

        guard state.targetModifier != nil, state.isModifierDown else { return }
        state.wasInterruptedByKey = true
        state.generation &+= 1

        if state.isInHoldState {
            state.isInHoldState = false
            fire(.holdRelease)
        }
    }

    private func handleFlagsChanged(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        source: ModifierEventSource
    ) {
        if !loggedFlagsDelivery {
            loggedFlagsDelivery = true
            Log.modifierKeys.notice(
                "Modifier-only flagsChanged NSEvent monitor delivered first event from \(source.rawValue, privacy: .public)."
            )
        }

        guard let target = state.targetModifier else { return }

        let targetFlagPresent = Self.targetFlagPresent(target, flags: flags)
        let isTargetKeyEvent = Self.isTargetModifierKeyEvent(target, keyCode: keyCode)
        let effect: GestureEffect

        if state.isModifierDown {
            if isTargetKeyEvent || !targetFlagPresent {
                effect = handleTargetModifierReleaseIfNeeded(targetFlagPresent: targetFlagPresent)
            } else {
                effect = handleModifierInterruptedByFlagsTimeline()
            }
        } else if targetFlagPresent && isTargetKeyEvent {
            effect = handleTargetModifierPress()
        } else {
            effect = .none
        }

        perform(effect)
    }

    private func handleTargetModifierPress() -> GestureEffect {
        state.isModifierDown = true
        state.wasInterruptedByKey = false
        state.isInHoldState = false
        state.generation &+= 1
        return .scheduleHold(generation: state.generation, delay: state.holdThresholdSeconds)
    }

    private func handleTargetModifierReleaseIfNeeded(targetFlagPresent: Bool) -> GestureEffect {
        guard !targetFlagPresent, state.isModifierDown else { return .none }

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

    private func handleModifierInterruptedByFlagsTimeline() -> GestureEffect {
        state.wasInterruptedByKey = true
        state.generation &+= 1

        if state.isInHoldState {
            state.isInHoldState = false
            return .fire(.holdRelease)
        }

        return .none
    }

    private func handleHoldThresholdElapsed(generation: UInt64) {
        guard state.targetModifier != nil,
              state.generation == generation,
              state.isModifierDown,
              !state.wasInterruptedByKey,
              !state.isInHoldState
        else {
            return
        }

        state.isInHoldState = true
        fire(.holdStart)
    }

    private func perform(_ effect: GestureEffect) {
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

    private func fire(_ callback: GestureCallback) {
        switch callback {
        case .tap:
            onTap?()
        case .holdStart:
            onHoldStart?()
        case .holdRelease:
            onHoldRelease?()
        }
    }

    private static func targetFlagPresent(
        _ target: ModifierKey,
        flags: NSEvent.ModifierFlags
    ) -> Bool {
        switch target {
        case .fn:
            return flags.contains(.function)
        case .rightCommand:
            return flags.contains(.command)
        case .rightOption:
            return flags.contains(.option)
        }
    }

    private static func isTargetModifierKeyEvent(
        _ target: ModifierKey,
        keyCode: UInt16
    ) -> Bool {
        switch target {
        case .fn:
            return keyCode == UInt16(kVK_Function) || keyCode == 0
        case .rightCommand:
            return keyCode == UInt16(kVK_RightCommand)
        case .rightOption:
            return keyCode == UInt16(kVK_RightOption)
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

    /// Number of live NSEvent monitors currently installed. Lets tests prove
    /// the XCTest-pinned `start()` never touched the real monitor APIs.
    var debugInstalledMonitorCount: Int {
        [globalFlagsMonitor, localFlagsMonitor, globalKeyDownMonitor, localKeyDownMonitor]
            .compactMap { $0 }.count
    }

    func debugStartGestureForTesting(modifier: ModifierKey) {
        configureGestureState(modifier: modifier)
        Self.record(.created)
    }

    func debugHandleKeyDownForTesting() {
        handleKeyDown(source: .synthetic)
    }

    func debugHandleFlagsChangedForTesting(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) {
        handleFlagsChanged(keyCode: keyCode, flags: flags, source: .synthetic)
    }

    func debugGestureSnapshotForTesting() -> ModifierOnlyHotKeyDebugSnapshot {
        ModifierOnlyHotKeyDebugSnapshot(
            targetModifier: state.targetModifier,
            isModifierDown: state.isModifierDown,
            wasInterruptedByKey: state.wasInterruptedByKey,
            isInHoldState: state.isInHoldState,
            generation: state.generation
        )
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
        resetGesture()
    }
}

private enum ModifierEventSource: String {
    case global
    case local
    case synthetic
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
    case monitorInstallationFailed
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
