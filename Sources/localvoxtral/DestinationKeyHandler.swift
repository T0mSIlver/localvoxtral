import Carbon.HIToolbox
import Foundation
import os

/// Tab and ⇧Tab, → and ←, while an Overlay Buffer dictation runs (#840,
/// #880): they move the overlay to the next or previous destination and
/// never reach the focused app. Registered as Carbon hotkeys only for the
/// running overlay, the way `EscapeCancelHandler` registers Escape, so no
/// Input Monitoring is needed and Live Auto-Paste never takes the keys.
@MainActor
final class DestinationKeyHandler {
    /// The keys that move, each with its hotkey ID.
    enum Key: UInt32, CaseIterable {
        case tab = 1
        case shiftTab = 2
        case rightArrow = 3
        case leftArrow = 4

        var forward: Bool { self == .tab || self == .rightArrow }

        fileprivate var keyCode: UInt32 {
            switch self {
            case .tab, .shiftTab: UInt32(kVK_Tab)
            case .rightArrow: UInt32(kVK_RightArrow)
            case .leftArrow: UInt32(kVK_LeftArrow)
            }
        }

        fileprivate var modifiers: UInt32 { self == .shiftTab ? UInt32(shiftKey) : 0 }
    }

    /// `true` for Tab and →, `false` for ⇧Tab and ←.
    var onMove: ((_ forward: Bool) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandlerRef: EventHandlerRef?

    private static let hotKeySignature = OSType(0x4C564474) // LVDt
    private nonisolated(unsafe) static weak var hotKeyTarget: DestinationKeyHandler?

    #if DEBUG
    private(set) static var isRegisteredForTesting = false
    #endif

    var isRegistered: Bool { hotKeyHandlerRef != nil }

    func start() {
        guard !isRegistered else { return }
        #if DEBUG
        // Under XCTest no real hotkey is taken from the machine running the
        // suite; tests press the keys through `handle(_:)`.
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
                // dictation shortcut and Escape go dead while these keys are armed.
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
                guard let key = Key(rawValue: hotKeyID.id) else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async {
                    DestinationKeyHandler.hotKeyTarget?.handle(key)
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            nil,
            &hotKeyHandlerRef
        )
        guard installStatus == noErr else {
            Log.escape.error("Destination hotkey handler install failed with OSStatus \(installStatus, privacy: .public)")
            stop()
            return
        }
        Self.hotKeyTarget = self
        for key in Key.allCases {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                key.keyCode,
                key.modifiers,
                EventHotKeyID(signature: Self.hotKeySignature, id: key.rawValue),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                Log.escape.error(
                    "RegisterEventHotKey for destination key \(String(describing: key), privacy: .public) failed with OSStatus \(status, privacy: .public)"
                )
            }
        }
        Log.escape.notice("Destination hotkeys registered: \(self.hotKeyRefs.count, privacy: .public)")
    }

    /// One of the keys was pressed.
    func handle(_ key: Key) {
        onMove?(key.forward)
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
