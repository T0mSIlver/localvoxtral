import AppKit
import Carbon.HIToolbox
import Foundation

extension EditSignal {
    /// The ONLY mapping from a key event to a signal. Pure and total: anything
    /// that is not one of the two gestures returns nil and is forgotten
    /// immediately — the monitor never retains, forwards, or counts it.
    ///
    /// ⌘A only with Command held and no other command-class modifier: ⌥⌘A /
    /// ⌃⌘A / ⇧⌘A are app shortcuts, not select-all, and counting them would
    /// inflate the signal with ordinary navigation.
    static func from(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> EditSignal? {
        let relevant = modifiers.intersection(.deviceIndependentFlagsMask)
        switch Int(keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            // A modifier'd delete (⌥⌫ deletes a word, ⌘⌫ a line) is still the
            // user erasing what we inserted, so no modifier condition here.
            return .backspace
        case kVK_ANSI_A where relevant.contains(.command)
            && !relevant.contains(.option)
            && !relevant.contains(.control)
            && !relevant.contains(.shift):
            return .selectAll
        default:
            return nil
        }
    }
}

/// The production observer: one GLOBAL `NSEvent` keyDown monitor, installed when
/// a watch window opens and removed the moment it closes.
///
/// Design decisions worth keeping:
///
/// * **Global only, never local.** A local monitor sees keys typed into
///   localvoxtral's OWN windows (Settings, the shortcut recorder), which is not
///   the user reacting to an insertion. The insertion lands in another app, so
///   the reaction does too.
/// * **A new monitor rather than a tap on `ModifierOnlyHotKeyManager`'s.** That
///   manager already holds a keyDown monitor, but only while the modifier-only
///   hotkey mode is active, and its handler deliberately discards the event
///   (it needs "a key happened", not which). Widening its callback would fork a
///   production signature for a capture that shipped builds do not compile —
///   the same trade `DiagnosticCaptureTap` documents, decided the same way.
/// * **No new permission.** Global `NSEvent` monitors need the Accessibility
///   trust the app already holds for insertion; without it, this reports
///   `false` and the dictation gets NO behavior block at all — see
///   `EditSignalWatcher.arm`.
@MainActor
final class EditKeyNSEventMonitor: EditKeyMonitoring {
    private var monitor: Any?

    func start(_ handler: @escaping @MainActor (EditSignal) -> Void) -> Bool {
        stop()

        #if DEBUG
        // Never install a real monitor under XCTest. Same rule (and the same
        // 2026-07-24 incident) as `ModifierOnlyHotKeyManager.start`: a live
        // monitor here would read the HOST's keyboard while the suite runs, and
        // an unattended CI machine is not a test fixture. The watcher's own
        // tests inject a fake monitor.
        if TerminalTargetDetector.isRunningUnderXCTest { return false }
        #endif

        guard AXIsProcessTrusted() else {
            // Loud, per the repo's rule about silent failure paths: a watcher
            // that quietly never observes an edit would read as "the user
            // never edits".
            Log.diagnostics.notice(
                "Edit signal: Accessibility not trusted; no watch installed"
            )
            return false
        }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // Nothing about the event survives this closure except the verdict:
            // an unrecognized key is not retained, forwarded, or counted.
            let keyCode = event.keyCode
            let rawFlags = event.modifierFlags.rawValue
            guard let signal = EditSignal.from(
                keyCode: keyCode,
                modifiers: NSEvent.ModifierFlags(rawValue: rawFlags)
            ) else { return }
            Task { @MainActor in handler(signal) }
        }

        guard monitor != nil else {
            Log.diagnostics.notice(
                "Edit signal: keyDown monitor installation failed; no watch"
            )
            return false
        }
        return true
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
