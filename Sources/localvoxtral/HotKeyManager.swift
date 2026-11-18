import Carbon.HIToolbox
import Foundation

@MainActor
final class HotKeyManager {
    enum RegistrationFailure {
        case handlerInstallFailed
        case shortcutUnavailable
        case livePasteShortcutUnavailable
        case modifierOnlyHotKeyUnavailable
        case copyLastDictationShortcutUnavailable
    }

    enum RegistrationResult {
        case success
        case failure(RegistrationFailure)
    }

    /// Which dictation trigger is installed. One at a time: each
    /// registration takes the previous one down first.
    enum Registration: Equatable {
        case none
        /// The legacy single Carbon shortcut.
        case single
        /// The two per-mode Carbon shortcuts; a nil slot registers nothing.
        case dual(overlay: Bool, livePaste: Bool)
        /// Fn / Globe, Right Command or Right Option, run by `ModifierOnlyHotKeyManager`.
        case modifierOnly
        /// A chord of modifiers (#863), run by `chordMonitor`.
        case dictationChord
    }

    static let handlerRegistrationErrorMessage = "Failed to register global hotkey handler."
    static let registrationErrorStatus = "Failed to register global hotkey."
    static let unavailableErrorMessage = "The selected keyboard shortcut is unavailable."
    static let livePasteUnavailableErrorMessage =
        "The selected Live Auto-Paste shortcut is unavailable."
    static let copyLastDictationUnavailableErrorMessage =
        "The selected Copy last dictation shortcut is unavailable."
    static let modifierOnlyUnavailableErrorMessage =
        "Unable to install the single-modifier hotkey monitors. Grant Accessibility permission, then try again."

    /// Legacy single-shortcut callback. Used by `register(shortcut:)`.
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    /// The dictation hot key whose press is being held. Only its release ends
    /// the hold: the other dictation key, pressed and released meanwhile,
    /// must not end a push-to-talk session it did not start (#1630).
    private var heldDictationHotKeyID: UInt32?

    /// Mode-aware callback for dual shortcuts. Used by `registerDual(overlay:livePaste:)`.
    var onPressWithMode: ((DictationOutputMode) -> Void)?

    /// Fired when modifier-only hold gesture starts (past threshold).
    /// Signals push-to-talk semantics; the output mode is the setting's.
    var onHoldStart: (() -> Void)?

    /// Fired for a modifier-only TAP. Distinct from onPress/onPressWithMode
    /// because taps carry no release event: the consumer must treat them as a
    /// toggle regardless of the configured shortcut behavior, or push-to-talk
    /// semantics latch dictation on.
    var onModifierOnlyTap: ((DictationOutputMode) -> Void)?

    /// Fired when the "Copy last dictation" shortcut is pressed. Its release
    /// is swallowed: it must never read as the end of a push-to-talk hold.
    var onCopyLastDictation: (() -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var hotKeyHandlerRef: EventHandlerRef?
    private static let hotKeySignature = OSType(0x53565854) // SVXT
    private nonisolated(unsafe) static weak var hotKeyTarget: HotKeyManager?
    private var modifierOnlyManager = ModifierOnlyHotKeyManager()
    private(set) var registration: Registration = .none

    /// True while a modifier-only registration is installed, a chord
    /// included. Lets the view model retry a launch-time registration that
    /// failed because Accessibility trust had not landed yet, without
    /// churning a live one.
    var isModifierOnlyRegistrationActive: Bool {
        registration == .modifierOnly || registration == .dictationChord
    }

    /// Maps hotkey IDs to output modes for dual-shortcut dispatch.
    private var hotKeyIDToMode: [UInt32: DictationOutputMode] = [:]

    private static let overlayHotKeyID: UInt32 = 1
    private static let livePasteHotKeyID: UInt32 = 2
    private static let copyLastDictationHotKeyID = ActionHotKey.copyLastDictation.rawValue

    /// A hotkey that fires one action on press. These live apart from the
    /// dictation triggers: re-registering or switching the triggers, the
    /// single-modifier gesture included, leaves them alone.
    /// The raw value is the Carbon hotkey ID.
    enum ActionHotKey: UInt32, CaseIterable, Sendable {
        case copyLastDictation = 3

        fileprivate var id: UInt32 { rawValue }

        fileprivate var failure: RegistrationFailure {
            switch self {
            case .copyLastDictation: .copyLastDictationShortcutUnavailable
            }
        }
    }

    private var actionHotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var registeredActionHotKeyIDs: Set<UInt32> = []
    /// Action shortcuts set to a modifier-only chord (#831) fire from here,
    /// not from Carbon.
    let chordMonitor = ModifierChordHotKeyMonitor()

    #if DEBUG
    private(set) static var debugForcedHandlerInstallResult: Bool?
    private(set) static var debugForcedRegisterStatusesByID: [UInt32: OSStatus] = [:]
    private(set) static var debugUnregisterCallCount = 0
    #endif

    init() {
        Self.hotKeyTarget = self
        chordMonitor.onChord = { [weak self] action in
            self?.handleHotKeyEvent(kind: UInt32(kEventHotKeyPressed), hotKeyID: action.id)
        }
        chordMonitor.onDictationTap = { [weak self] in self?.handleModifierTap() }
        chordMonitor.onDictationHoldStart = { [weak self] in self?.onHoldStart?() }
        chordMonitor.onDictationHoldEnd = { [weak self] in self?.onRelease?() }
    }

    /// A tap of the modifier key or chord: an Overlay Buffer toggle.
    private func handleModifierTap() {
        if let onModifierOnlyTap {
            onModifierOnlyTap(.overlayBuffer)
        } else if onPressWithMode != nil {
            onPressWithMode?(.overlayBuffer)
        } else {
            onPress?()
        }
    }

    /// Register a modifier-only key (Fn, Right Command, etc.) as the hotkey.
    /// This bypasses the Carbon RegisterEventHotKey path entirely.
    /// Tap triggers overlay buffer (toggle), hold is push to talk.
    /// `.chord` registers `chord` the same way (#863); with no chord it
    /// leaves no dictation trigger.
    @discardableResult
    func registerModifierOnly(
        _ modifier: ModifierOnlyHotKeyManager.ModifierKey,
        holdThreshold: Double = 0.35,
        chord: ModifierChord? = nil
    ) -> RegistrationResult {
        if modifier == .chord {
            return registerDictationChord(chord, holdDelay: holdThreshold)
        }
        let candidateManager = ModifierOnlyHotKeyManager()
        candidateManager.holdThresholdSeconds = holdThreshold
        candidateManager.onTap = { [weak self] in self?.handleModifierTap() }
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
        registration = .modifierOnly
        return .success
    }

    private func registerDictationChord(_ chord: ModifierChord?, holdDelay: Double) -> RegistrationResult {
        guard let chord else {
            unregister()
            return .success
        }
        guard chordMonitor.setDictationChord(chord, holdDelay: holdDelay) else {
            // The monitor dropped the chord it had, if any.
            if registration == .dictationChord { registration = .none }
            Log.modifierKeys.error(
                "Dictation chord registration failed; preserving any previous non-chord registration.")
            return .failure(.modifierOnlyHotKeyUnavailable)
        }
        // `unregister` must take the previous trigger, not this chord.
        if registration == .dictationChord { registration = .none }
        unregister()
        registration = .dictationChord
        return .success
    }

    /// Registers a single global hotkey for the given shortcut (legacy path).
    /// Returns `.success` when registration succeeds (including when shortcut is nil).
    @discardableResult
    func register(shortcut: DictationShortcut?) -> RegistrationResult {
        unregister()

        guard let shortcut else { return .success }

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
        registration = .single

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

        guard overlay != nil || livePaste != nil else { return .success }

        if !installHandlerIfNeeded() {
            return .failure(.handlerInstallFailed)
        }

        hotKeyIDToMode.removeAll()

        var overlayRegistered = false
        var livePasteRegistered = false
        var overlayFailed = false

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
            if status == noErr {
                overlayRegistered = true
                if let ref {
                    hotKeyRefs[Self.overlayHotKeyID] = ref
                    hotKeyIDToMode[Self.overlayHotKeyID] = .overlayBuffer
                }
            } else {
                overlayFailed = true
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
                registration = .dual(overlay: true, livePaste: false)
                return .failure(.livePasteShortcutUnavailable)
            }
            livePasteRegistered = true
            if let ref {
                hotKeyRefs[Self.livePasteHotKeyID] = ref
                hotKeyIDToMode[Self.livePasteHotKeyID] = .liveAutoPaste
            }
        }

        if overlayFailed {
            if !livePasteRegistered {
                unregister()
                return .failure(.shortcutUnavailable)
            }
            Log.modifierKeys.error(
                "Overlay Buffer hotkey registration failed; preserving the Live Auto-Paste hotkey and surfacing failure."
            )
            registration = .dual(overlay: false, livePaste: true)
            return .failure(.shortcutUnavailable)
        }

        registration = .dual(overlay: overlayRegistered, livePaste: livePasteRegistered)
        return .success
    }

    /// Unregisters the dictation triggers. The "Copy last dictation" hotkey
    /// stays; `registerCopyLastDictation(nil)` removes it.
    func unregister() {
        #if DEBUG
        Self.debugUnregisterCallCount += 1
        #endif
        heldDictationHotKeyID = nil
        switch registration {
        case .modifierOnly:
            modifierOnlyManager.stop()
        case .dictationChord:
            _ = chordMonitor.setDictationChord(nil, holdDelay: 0)
        case .none, .single, .dual:
            break
        }
        registration = .none

        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        hotKeyIDToMode.removeAll()

        removeHandlerIfUnused()
    }

    /// Registers the "Copy last dictation" hotkey in place of the one before,
    /// or only removes that one for nil. A failure leaves no copy hotkey; the
    /// caller puts the previous one back.
    @discardableResult
    func registerCopyLastDictation(_ shortcut: DictationShortcut?) -> RegistrationResult {
        registerAction(.copyLastDictation, shortcut)
    }

    private func registerAction(_ action: ActionHotKey, _ shortcut: DictationShortcut?) -> RegistrationResult {
        if let existing = actionHotKeyRefs.removeValue(forKey: action.id) {
            UnregisterEventHotKey(existing)
        }
        registeredActionHotKeyIDs.remove(action.id)
        _ = chordMonitor.setChord(nil, for: action)

        guard let shortcut else {
            removeHandlerIfUnused()
            return .success
        }
        if let chord = shortcut.modifierChord {
            removeHandlerIfUnused()
            guard chordMonitor.setChord(chord, for: action) else { return .failure(action.failure) }
            return .success
        }
        if !installHandlerIfNeeded() {
            return .failure(.handlerInstallFailed)
        }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: action.id)
        let status = registerEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else {
            Log.modifierKeys.error(
                "\(String(describing: action), privacy: .public) hotkey registration failed with status \(status, privacy: .public)"
            )
            removeHandlerIfUnused()
            return .failure(action.failure)
        }
        actionHotKeyRefs[action.id] = ref
        registeredActionHotKeyIDs.insert(action.id)
        return .success
    }

    var isCopyLastDictationShortcutRegistered: Bool {
        registeredActionHotKeyIDs.contains(Self.copyLastDictationHotKeyID) || chordMonitor.chords[.copyLastDictation] != nil
    }

    /// The Carbon handler serves every hotkey here, so it goes only with the
    /// last of them.
    private func removeHandlerIfUnused() {
        guard hotKeyRefs.isEmpty, registeredActionHotKeyIDs.isEmpty, let hotKeyHandlerRef else { return }
        RemoveEventHandler(hotKeyHandlerRef)
        self.hotKeyHandlerRef = nil
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
        if hotKeyID == Self.copyLastDictationHotKeyID {
            if kind == UInt32(kEventHotKeyPressed) { onCopyLastDictation?() }
            return
        }
        switch kind {
        case UInt32(kEventHotKeyPressed):
            if heldDictationHotKeyID == nil { heldDictationHotKeyID = hotKeyID }
            if let mode = hotKeyIDToMode[hotKeyID] {
                onPressWithMode?(mode)
            } else {
                // Legacy single-shortcut path or fallback
                onPress?()
            }
        case UInt32(kEventHotKeyReleased):
            if let held = heldDictationHotKeyID, held != hotKeyID { return }
            heldDictationHotKeyID = nil
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
        case .copyLastDictation:
            debugForcedRegisterStatusesByID[copyLastDictationHotKeyID] = status
        }
    }

    /// Delivers a hotkey event as the Carbon handler would.
    func debugDeliverHotKeyEventForTesting(pressed: Bool, hotKeyID: DebugRegistrationKindHotKeyID) {
        let id: UInt32
        switch hotKeyID {
        case .overlay: id = Self.overlayHotKeyID
        case .livePaste: id = Self.livePasteHotKeyID
        case .copyLastDictation: id = Self.copyLastDictationHotKeyID
        }
        handleHotKeyEvent(
            kind: UInt32(pressed ? kEventHotKeyPressed : kEventHotKeyReleased), hotKeyID: id)
    }
}

enum DebugRegistrationKindHotKeyID {
    case overlay
    case livePaste
    case copyLastDictation
}
#endif
