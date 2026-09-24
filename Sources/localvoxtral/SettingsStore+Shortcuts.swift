import Foundation

extension SettingsStore {
    var dictationShortcut: DictationShortcut? {
        guard dictationShortcutEnabled else { return nil }

        let candidate = DictationShortcut(
            keyCode: dictationShortcutKeyCode,
            carbonModifierFlags: dictationShortcutCarbonModifierFlags
        ).normalized

        if DictationShortcutValidation.persistenceErrorMessage(for: candidate) != nil {
            return Self.defaultDictationShortcut
        }

        return candidate
    }

    func setDictationShortcut(_ shortcut: DictationShortcut?) {
        guard let shortcut else {
            dictationShortcutEnabled = false
            return
        }

        let normalizedShortcut = shortcut.normalized
        let resolvedShortcut: DictationShortcut
        if DictationShortcutValidation.persistenceErrorMessage(for: normalizedShortcut) == nil {
            resolvedShortcut = normalizedShortcut
        } else {
            resolvedShortcut = Self.defaultDictationShortcut
        }

        dictationShortcutKeyCode = resolvedShortcut.keyCode
        dictationShortcutCarbonModifierFlags = resolvedShortcut.carbonModifierFlags
        dictationShortcutEnabled = true
    }

    func resetDictationShortcutToDefault() {
        setDictationShortcut(Self.defaultDictationShortcut)
    }

    // MARK: - Dual Shortcuts (per output mode)

    var overlayBufferShortcut: DictationShortcut? {
        guard overlayBufferShortcutEnabled else { return nil }
        let candidate = DictationShortcut(
            keyCode: overlayBufferShortcutKeyCode,
            carbonModifierFlags: overlayBufferShortcutCarbonModifierFlags
        ).normalized
        if DictationShortcutValidation.persistenceErrorMessage(for: candidate) != nil {
            return nil
        }
        return candidate
    }

    /// True when a keyboard trigger can start an Overlay Buffer session: the
    /// single-modifier tap gesture, or a dedicated Overlay Buffer shortcut.
    /// LLM polishing runs only on Overlay Buffer commits, so when this is
    /// false Settings shows polishing as unavailable and managed polishd is
    /// kept stopped. The menu-bar Start Dictation button deliberately does
    /// not count (owner call, 2026-07-06): an overlay session started from
    /// the popover still polishes via the session-time ensureReady backstop,
    /// paying the polishd cold start.
    var isOverlayBufferSessionReachable: Bool {
        modifierOnlyHotKeyEnabled || overlayBufferShortcut != nil
    }

    var livePasteShortcut: DictationShortcut? {
        guard livePasteShortcutEnabled else { return nil }
        let candidate = DictationShortcut(
            keyCode: livePasteShortcutKeyCode,
            carbonModifierFlags: livePasteShortcutCarbonModifierFlags
        ).normalized
        if DictationShortcutValidation.persistenceErrorMessage(for: candidate) != nil {
            return nil
        }
        return candidate
    }

    /// Both shortcut slots exactly as stored, enabled flags included and a
    /// value the validator rejects kept verbatim.
    ///
    /// The getters cannot express this: they return nil both for a disabled
    /// slot and for a stored value that fails validation, and a caller that
    /// means to put things back the way they were would restore the default
    /// shortcut over the second case — installing a trigger the user never
    /// chose. Anything that writes a slot speculatively takes a snapshot
    /// first and restores it verbatim.
    struct ShortcutSlotSnapshot: Equatable {
        var overlayKeyCode: UInt32
        var overlayCarbonModifierFlags: UInt32
        var overlayEnabled: Bool
        var livePasteKeyCode: UInt32
        var livePasteCarbonModifierFlags: UInt32
        var livePasteEnabled: Bool
    }

    var shortcutSlotSnapshot: ShortcutSlotSnapshot {
        ShortcutSlotSnapshot(
            overlayKeyCode: overlayBufferShortcutKeyCode,
            overlayCarbonModifierFlags: overlayBufferShortcutCarbonModifierFlags,
            overlayEnabled: overlayBufferShortcutEnabled,
            livePasteKeyCode: livePasteShortcutKeyCode,
            livePasteCarbonModifierFlags: livePasteShortcutCarbonModifierFlags,
            livePasteEnabled: livePasteShortcutEnabled
        )
    }

    func restoreShortcutSlots(_ snapshot: ShortcutSlotSnapshot) {
        overlayBufferShortcutKeyCode = snapshot.overlayKeyCode
        overlayBufferShortcutCarbonModifierFlags = snapshot.overlayCarbonModifierFlags
        overlayBufferShortcutEnabled = snapshot.overlayEnabled
        livePasteShortcutKeyCode = snapshot.livePasteKeyCode
        livePasteShortcutCarbonModifierFlags = snapshot.livePasteCarbonModifierFlags
        livePasteShortcutEnabled = snapshot.livePasteEnabled
    }

    func setOverlayBufferShortcut(_ shortcut: DictationShortcut?) {
        guard let shortcut else {
            overlayBufferShortcutEnabled = false
            return
        }
        let normalizedShortcut = shortcut.normalized
        if DictationShortcutValidation.persistenceErrorMessage(for: normalizedShortcut) == nil {
            overlayBufferShortcutKeyCode = normalizedShortcut.keyCode
            overlayBufferShortcutCarbonModifierFlags = normalizedShortcut.carbonModifierFlags
        } else {
            overlayBufferShortcutKeyCode = Self.defaultDictationShortcut.keyCode
            overlayBufferShortcutCarbonModifierFlags = Self.defaultDictationShortcut.carbonModifierFlags
        }
        overlayBufferShortcutEnabled = true
    }

    func setLivePasteShortcut(_ shortcut: DictationShortcut?) {
        guard let shortcut else {
            livePasteShortcutEnabled = false
            return
        }
        let normalizedShortcut = shortcut.normalized
        if DictationShortcutValidation.persistenceErrorMessage(for: normalizedShortcut) == nil {
            livePasteShortcutKeyCode = normalizedShortcut.keyCode
            livePasteShortcutCarbonModifierFlags = normalizedShortcut.carbonModifierFlags
        } else {
            return
        }
        livePasteShortcutEnabled = true
    }

    // MARK: - Copy last dictation (#526)

    /// The global shortcut for "Copy last dictation", nil when none is set.
    var copyLastDictationShortcut: DictationShortcut? {
        guard copyLastDictationShortcutEnabled else { return nil }
        let candidate = DictationShortcut(
            keyCode: copyLastDictationShortcutKeyCode,
            carbonModifierFlags: copyLastDictationShortcutCarbonModifierFlags
        ).normalized
        if DictationShortcutValidation.persistenceErrorMessage(for: candidate) != nil {
            return nil
        }
        return candidate
    }

    /// A shortcut the validator rejects is not stored: the slot is optional,
    /// so it has no default to fall back to.
    func setCopyLastDictationShortcut(_ shortcut: DictationShortcut?) {
        guard let shortcut else {
            copyLastDictationShortcutEnabled = false
            return
        }
        let normalizedShortcut = shortcut.normalized
        guard DictationShortcutValidation.persistenceErrorMessage(for: normalizedShortcut) == nil else {
            return
        }
        copyLastDictationShortcutKeyCode = normalizedShortcut.keyCode
        copyLastDictationShortcutCarbonModifierFlags = normalizedShortcut.carbonModifierFlags
        copyLastDictationShortcutEnabled = true
    }
}
