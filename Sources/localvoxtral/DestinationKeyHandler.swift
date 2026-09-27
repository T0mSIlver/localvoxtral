import Carbon.HIToolbox
import Foundation
import os

/// Tab and ⇧Tab while an Overlay Buffer dictation runs (#840): they move the
/// overlay to the next or previous destination and never reach the focused
/// app. Registered as Carbon hotkeys only for the running overlay, the way
/// `EscapeCancelHandler` registers Escape, so no Input Monitoring is needed
/// and Live Auto-Paste never takes the keys.
@MainActor
final class DestinationKeyHandler {
    /// `true` for Tab, `false` for ⇧Tab.
    var onMove: ((_ forward: Bool) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandlerRef: EventHandlerRef?

    private static let hotKeySignature = OSType(0x4C564474) // LVDt
    private static let forwardID = UInt32(1)
    private static let backwardID = UInt32(2)
    private nonisolated(unsafe) static weak var hotKeyTarget: DestinationKeyHandler?

    #if DEBUG
    private(set) static var isRegisteredForTesting = false
    #endif

    var isRegistered: Bool { hotKeyHandlerRef != nil }

    func start() {
        guard !isRegistered else { return }
        #if DEBUG
        // Under XCTest no real hotkey is taken from the machine running the
        // suite; tests drive `onMove` through the controller directly.
        if TerminalTargetDetector.isRunningUnderXCTest {
            Self.isRegisteredForTesting = true
            return
        }
        #endif
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        ]
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ in
                // Another hotkey on this shared target is passed on, or the
                // dictation shortcut and Escape go dead while Tab is armed.
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
                guard status == noErr, hotKeyID.signature == DestinationKeyHandler.hotKeySignature else {
                    return OSStatus(eventNotHandledErr)
                }
                let forward = hotKeyID.id == DestinationKeyHandler.forwardID
                DispatchQueue.main.async {
                    DestinationKeyHandler.hotKeyTarget?.onMove?(forward)
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            nil,
            &hotKeyHandlerRef
        )
        guard installStatus == noErr else {
            Log.escape.error("Tab destination hotkey handler install failed with OSStatus \(installStatus, privacy: .public)")
            stop()
            return
        }
        Self.hotKeyTarget = self
        for (id, modifiers) in [(Self.forwardID, UInt32(0)), (Self.backwardID, UInt32(shiftKey))] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(kVK_Tab),
                modifiers,
                EventHotKeyID(signature: Self.hotKeySignature, id: id),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                Log.escape.error("RegisterEventHotKey for Tab failed with OSStatus \(status, privacy: .public)")
            }
        }
        Log.escape.notice("Tab destination hotkeys registered: \(self.hotKeyRefs.count, privacy: .public)")
    }

    func stop() {
        #if DEBUG
        Self.isRegisteredForTesting = false
        #endif
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
        if Self.hotKeyTarget === self {
            Self.hotKeyTarget = nil
        }
    }
}
