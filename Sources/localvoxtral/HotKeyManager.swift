import Carbon.HIToolbox
import Foundation

@MainActor
final class HotKeyManager {
    enum RegistrationFailure {
        case handlerInstallFailed
        case shortcutUnavailable
    }

    enum RegistrationResult {
        case success
        case failure(RegistrationFailure)
    }

    static let handlerRegistrationErrorMessage = "Failed to register global hotkey handler."
    static let registrationErrorStatus = "Failed to register global hotkey."
    static let unavailableErrorMessage = "The selected keyboard shortcut is unavailable."

    /// Legacy single-shortcut callback. Used by `register(shortcut:)`.
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    /// Mode-aware callback for dual shortcuts. Used by `registerDual(overlay:livePaste:)`.
    var onPressWithMode: ((DictationOutputMode) -> Void)?

    /// Fired when modifier-only hold gesture starts (past threshold).
    /// Signals push-to-talk semantics with liveAutoPaste mode.
    var onHoldStart: (() -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var hotKeyHandlerRef: EventHandlerRef?
    private static let hotKeySignature = OSType(0x53565854) // SVXT
    private nonisolated(unsafe) static weak var hotKeyTarget: HotKeyManager?
    private let modifierOnlyManager = ModifierOnlyHotKeyManager()
    private var isUsingModifierOnly = false

    /// Maps hotkey IDs to output modes for dual-shortcut dispatch.
    private var hotKeyIDToMode: [UInt32: DictationOutputMode] = [:]

    private static let overlayHotKeyID: UInt32 = 1
    private static let livePasteHotKeyID: UInt32 = 2

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
        unregister()
        isUsingModifierOnly = true
        modifierOnlyManager.holdThresholdSeconds = holdThreshold
        modifierOnlyManager.onTap = { [weak self] in
            guard let self else { return }
            if self.onPressWithMode != nil {
                self.onPressWithMode?(.overlayBuffer)
            } else {
                self.onPress?()
            }
        }
        modifierOnlyManager.onHoldStart = { [weak self] in self?.onHoldStart?() }
        modifierOnlyManager.onHoldRelease = { [weak self] in self?.onRelease?() }
        modifierOnlyManager.start(modifier: modifier)
        return .success
    }

    /// Registers a single global hotkey for the given shortcut (legacy path).
    /// Returns `.success` when registration succeeds (including when shortcut is nil).
    @discardableResult
    func register(shortcut: DictationShortcut?) -> RegistrationResult {
        unregister()

        guard let shortcut else {
            return .success
        }

        if !installHandlerIfNeeded() {
            return .failure(.handlerInstallFailed)
        }

        hotKeyIDToMode.removeAll()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.overlayHotKeyID)
        let registerStatus = RegisterEventHotKey(
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
            return .success
        }

        if !installHandlerIfNeeded() {
            return .failure(.handlerInstallFailed)
        }

        hotKeyIDToMode.removeAll()

        if let overlay {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.overlayHotKeyID)
            let status = RegisterEventHotKey(
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
            if let ref {
                hotKeyRefs[Self.overlayHotKeyID] = ref
                hotKeyIDToMode[Self.overlayHotKeyID] = .overlayBuffer
            }
        }

        if let livePaste {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.livePasteHotKeyID)
            let status = RegisterEventHotKey(
                livePaste.keyCode,
                livePaste.carbonModifierFlags,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status != noErr {
                // Only fail if overlay also wasn't registered.
                // If overlay succeeded, keep it and just skip live paste.
                if hotKeyRefs.isEmpty {
                    unregister()
                    return .failure(.shortcutUnavailable)
                }
                // Overlay is registered — live paste failed. Still report as success
                // so the app remains functional with the overlay shortcut.
                return .success
            }
            if let ref {
                hotKeyRefs[Self.livePasteHotKeyID] = ref
                hotKeyIDToMode[Self.livePasteHotKeyID] = .liveAutoPaste
            }
        }

        return .success
    }

    func unregister() {
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
                guard let eventRef else { return noErr }

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
                    return noErr
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
