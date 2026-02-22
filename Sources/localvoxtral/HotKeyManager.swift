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

    var onToggle: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private static let hotKeySignature = OSType(0x53565854) // SVXT
    private nonisolated(unsafe) static weak var hotKeyTarget: HotKeyManager?

    init() {
        Self.hotKeyTarget = self
    }

    /// Registers a global hotkey for the given shortcut.
    /// Returns `.success` when registration succeeds (including when shortcut is nil).
    @discardableResult
    func register(shortcut: DictationShortcut?) -> RegistrationResult {
        unregister()

        guard let shortcut else {
            return .success
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

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
                      hotKeyID.signature == HotKeyManager.hotKeySignature,
                      hotKeyID.id == 1
                else {
                    return noErr
                }

                DispatchQueue.main.async {
                    HotKeyManager.hotKeyTarget?.onToggle?()
                }

                return noErr
            },
            1,
            &eventType,
            nil,
            &hotKeyHandlerRef
        )

        guard installStatus == noErr else {
            return .failure(.handlerInstallFailed)
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            unregister()
            return .failure(.shortcutUnavailable)
        }

        return .success
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }
}
