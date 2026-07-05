import Carbon.HIToolbox
import Foundation

@MainActor
final class HotKeyManager {
    enum RegistrationFailure {
        case handlerInstallFailed
        case shortcutUnavailable
        case livePasteShortcutUnavailable
        case modifierOnlyHotKeyUnavailable
    }

    enum RegistrationResult {
        case success
        case failure(RegistrationFailure)
    }

    #if DEBUG
    enum DebugRegistrationKind: Equatable {
        case none
        case single
        case dual(overlay: Bool, livePaste: Bool)
        case modifierOnly
    }
    #endif

    static let handlerRegistrationErrorMessage = "Failed to register global hotkey handler."
    static let registrationErrorStatus = "Failed to register global hotkey."
    static let unavailableErrorMessage = "The selected keyboard shortcut is unavailable."
    static let livePasteUnavailableErrorMessage =
        "The selected Live Auto-Paste shortcut is unavailable."
    static let modifierOnlyUnavailableErrorMessage =
        "Unable to install the single-modifier hotkey monitors. Grant Accessibility permission, then try again."

    /// Legacy single-shortcut callback. Used by `register(shortcut:)`.
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    /// Mode-aware callback for dual shortcuts. Used by `registerDual(overlay:livePaste:)`.
    var onPressWithMode: ((DictationOutputMode) -> Void)?

    /// Fired when modifier-only hold gesture starts (past threshold).
    /// Signals push-to-talk semantics with liveAutoPaste mode.
    var onHoldStart: (() -> Void)?

    /// Fired for a modifier-only TAP. Distinct from onPress/onPressWithMode
    /// because taps carry no release event: the consumer must treat them as a
    /// toggle regardless of the configured shortcut behavior, or push-to-talk
    /// semantics latch dictation on.
    var onModifierOnlyTap: ((DictationOutputMode) -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var hotKeyHandlerRef: EventHandlerRef?
    private static let hotKeySignature = OSType(0x53565854) // SVXT
    private nonisolated(unsafe) static weak var hotKeyTarget: HotKeyManager?
    private var modifierOnlyManager = ModifierOnlyHotKeyManager()
    private var isUsingModifierOnly = false

    /// True while a modifier-only registration is installed. Lets the view
    /// model retry a launch-time registration that failed because
    /// Accessibility trust had not landed yet, without churning a live one.
    var isModifierOnlyRegistrationActive: Bool { isUsingModifierOnly }

    /// Maps hotkey IDs to output modes for dual-shortcut dispatch.
    private var hotKeyIDToMode: [UInt32: DictationOutputMode] = [:]

    private static let overlayHotKeyID: UInt32 = 1
    private static let livePasteHotKeyID: UInt32 = 2

    #if DEBUG
    private(set) var debugCurrentRegistrationKind: DebugRegistrationKind = .none
    private(set) static var debugForcedHandlerInstallResult: Bool?
    private(set) static var debugForcedRegisterStatusesByID: [UInt32: OSStatus] = [:]
    private(set) static var debugUnregisterCallCount = 0
    #endif

    init() {
        Self.hotKeyTarget = self
    }

    /// Register a modifier-only key (Fn, Right Command, etc.) as the hotkey.
    /// This bypasses the Carbon RegisterEventHotKey path entirely.
    /// Tap triggers overlay buffer (toggle), hold triggers live auto-paste (push-to-talk).
    @discardableResult
    func registerModifierOnly(
        _ modifier: ModifierOnlyHotKeyManager.ModifierKey,
        holdThreshold: Double = 0.35
    ) -> RegistrationResult {
        let candidateManager = ModifierOnlyHotKeyManager()
        candidateManager.holdThresholdSeconds = holdThreshold
        candidateManager.onTap = { [weak self] in
            guard let self else { return }
            if let onModifierOnlyTap = self.onModifierOnlyTap {
                onModifierOnlyTap(.overlayBuffer)
            } else if self.onPressWithMode != nil {
                self.onPressWithMode?(.overlayBuffer)
            } else {
                self.onPress?()
            }
        }
        candidateManager.onHoldStart = { [weak self] in self?.onHoldStart?() }
        candidateManager.onHoldRelease = { [weak self] in self?.onRelease?() }

        let startOutcome = candidateManager.start(modifier: modifier)
        guard startOutcome == .created else {
            candidateManager.stop()
            Log.modifierKeys.error(
                "Modifier-only hotkey registration failed with outcome \(startOutcome.rawValue, privacy: .public); preserving previous hotkey registration."
            )
            return .failure(.modifierOnlyHotKeyUnavailable)
        }

        unregister()
        modifierOnlyManager = candidateManager
        isUsingModifierOnly = true
        #if DEBUG
        debugCurrentRegistrationKind = .modifierOnly
        #endif
        return .success
    }

    /// Registers a single global hotkey for the given shortcut (legacy path).
    /// Returns `.success` when registration succeeds (including when shortcut is nil).
    @discardableResult
    func register(shortcut: DictationShortcut?) -> RegistrationResult {
        unregister()

        guard let shortcut else {
            #if DEBUG
            debugCurrentRegistrationKind = .none
            #endif
            return .success
        }

        if !installHandlerIfNeeded() {
            return .failure(.handlerInstallFailed)
        }

        hotKeyIDToMode.removeAll()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.overlayHotKeyID)
        let registerStatus = registerEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if registerStatus != noErr {
            unregister()
            return .failure(.shortcutUnavailable)
        }

        if let ref {
            hotKeyRefs[Self.overlayHotKeyID] = ref
        }
        #if DEBUG
        debugCurrentRegistrationKind = .single
        #endif

        return .success
    }

    /// Registers dual global hotkeys — one for overlay buffer mode, one for live auto-paste mode.
    /// Either shortcut can be nil (disabled). Returns `.success` if at least one registers
    /// successfully, or if both are nil. Returns `.failure` only if a non-nil shortcut fails to register.
    @discardableResult
    func registerDual(
        overlay: DictationShortcut?,
        livePaste: DictationShortcut?
    ) -> RegistrationResult {
        unregister()

        guard overlay != nil || livePaste != nil else {
            #if DEBUG
            debugCurrentRegistrationKind = .none
            #endif
            return .success
        }

        if !installHandlerIfNeeded() {
            return .failure(.handlerInstallFailed)
        }

        hotKeyIDToMode.removeAll()

        var overlayRegistered = false
        var livePasteRegistered = false

        if let overlay {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.overlayHotKeyID)
            let status = registerEventHotKey(
                overlay.keyCode,
                overlay.carbonModifierFlags,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status != noErr {
                unregister()
                return .failure(.shortcutUnavailable)
            }
            overlayRegistered = true
            if let ref {
                hotKeyRefs[Self.overlayHotKeyID] = ref
                hotKeyIDToMode[Self.overlayHotKeyID] = .overlayBuffer
            }
        }

        if let livePaste {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.livePasteHotKeyID)
            let status = registerEventHotKey(
                livePaste.keyCode,
                livePaste.carbonModifierFlags,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status != noErr {
                if !overlayRegistered {
                    unregister()
                    return .failure(.shortcutUnavailable)
                }
                Log.modifierKeys.error(
                    "Live Auto-Paste hotkey registration failed after Overlay Buffer hotkey registered; preserving overlay hotkey and surfacing failure."
                )
                return .failure(.livePasteShortcutUnavailable)
            }
            livePasteRegistered = true
            if let ref {
                hotKeyRefs[Self.livePasteHotKeyID] = ref
                hotKeyIDToMode[Self.livePasteHotKeyID] = .liveAutoPaste
            }
        }

        #if DEBUG
        debugCurrentRegistrationKind = .dual(
            overlay: overlayRegistered,
            livePaste: livePasteRegistered
        )
        #endif
        return .success
    }

    func unregister() {
        #if DEBUG
        Self.debugUnregisterCallCount += 1
        #endif
        if isUsingModifierOnly {
            modifierOnlyManager.stop()
            isUsingModifierOnly = false
        }

        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        hotKeyIDToMode.removeAll()

        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    // MARK: - Private

    /// Installs the Carbon event handler if not already installed. Returns true on success.
    private func installHandlerIfNeeded() -> Bool {
        guard hotKeyHandlerRef == nil else { return true }

        #if DEBUG
        if let forcedHandlerInstallResult = Self.debugForcedHandlerInstallResult {
            return forcedHandlerInstallResult
        }
        #endif

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ in
                // Returning noErr marks a Carbon event as HANDLED and stops
                // propagation — EscapeCancelHandler shares this event target,
                // so any hotkey that is not ours must be passed on with
                // eventNotHandledErr or Escape-cancel goes dead whenever this
                // handler ends up earlier in the chain (see #41 for the
                // mirror-image bug).
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
                      hotKeyID.signature == HotKeyManager.hotKeySignature
                else {
                    return OSStatus(eventNotHandledErr)
                }

                let eventKind = GetEventKind(eventRef)
                let capturedID = hotKeyID.id
                DispatchQueue.main.async {
                    HotKeyManager.hotKeyTarget?.handleHotKeyEvent(kind: eventKind, hotKeyID: capturedID)
                }

                return noErr
            },
            eventTypes.count,
            &eventTypes,
            nil,
            &hotKeyHandlerRef
        )

        return installStatus == noErr
    }

    private func registerEventHotKey(
        _ keyCode: UInt32,
        _ modifierFlags: UInt32,
        _ hotKeyID: EventHotKeyID,
        _ target: EventTargetRef?,
        _ options: UInt32,
        _ outRef: UnsafeMutablePointer<EventHotKeyRef?>
    ) -> OSStatus {
        #if DEBUG
        if let forcedStatus = Self.debugForcedRegisterStatusesByID.removeValue(forKey: hotKeyID.id) {
            outRef.pointee = nil
            return forcedStatus
        }
        #endif

        return RegisterEventHotKey(
            keyCode,
            modifierFlags,
            hotKeyID,
            target,
            options,
            outRef
        )
    }

    private func handleHotKeyEvent(kind: UInt32, hotKeyID: UInt32) {
        switch kind {
        case UInt32(kEventHotKeyPressed):
            if let mode = hotKeyIDToMode[hotKeyID] {
                onPressWithMode?(mode)
            } else {
                // Legacy single-shortcut path or fallback
                onPress?()
            }
        case UInt32(kEventHotKeyReleased):
            onRelease?()
        default:
            break
        }
    }
}

#if DEBUG
extension HotKeyManager {
    static func debugResetOverridesForTesting() {
        debugForcedHandlerInstallResult = nil
        debugForcedRegisterStatusesByID = [:]
        debugUnregisterCallCount = 0
    }

    static func debugForceHandlerInstallResultForTesting(_ result: Bool?) {
        debugForcedHandlerInstallResult = result
    }

    static func debugForceRegisterStatusForTesting(
        hotKeyID: DebugRegistrationKindHotKeyID,
        status: OSStatus
    ) {
        switch hotKeyID {
        case .overlay:
            debugForcedRegisterStatusesByID[overlayHotKeyID] = status
        case .livePaste:
            debugForcedRegisterStatusesByID[livePasteHotKeyID] = status
        }
    }
}

enum DebugRegistrationKindHotKeyID {
    case overlay
    case livePaste
}
#endif
