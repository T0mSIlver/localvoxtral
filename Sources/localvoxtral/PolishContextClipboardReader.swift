import AppKit
import Foundation

/// Minimal seam over the system pasteboard so the polish-context reader can be
/// unit-tested without touching `NSPasteboard.general`. `@MainActor` because the
/// only production caller is the main-actor stop-commit path.
@MainActor
protocol PasteboardReading {
    /// The pasteboard's declared types, used to detect concealed/transient data.
    func types() -> [NSPasteboard.PasteboardType]?
    /// The plain-string contents, or nil when the pasteboard holds no string.
    func string() -> String?
}

extension NSPasteboard.PasteboardType {
    /// nspasteboard.org convention: the source declared this payload sensitive
    /// (password managers, etc.) and asked clipboard tools not to read it.
    static let nsPasteboardConcealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// nspasteboard.org convention: transient payload the source asked tools not
    /// to read or retain (e.g. one-shot data a manager will immediately replace).
    static let nsPasteboardTransient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
}

/// Write seam mirroring `PasteboardReading`: the system pasteboard is host
/// state a unit test must never touch (clobbering the host clipboard is
/// antisocial, and the CI runner has no pasteboard server anyway).
/// `NSPasteboard` already has exactly these members.
@MainActor
protocol PasteboardWriting {
    @discardableResult
    func clearContents() -> Int
    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: PasteboardWriting {}

/// Writes credential-bearing text to a pasteboard with
/// `org.nspasteboard.ConcealedType` declared alongside, so clipboard managers
/// — and our own clipboard-context harvester, which refuses concealed payloads
/// in `readableSanitizedString` — never read or retain it. Used by the
/// enrollment-token / remote-command Copy actions in Settings; a plain
/// `.string` write there would paste the token straight into the next polish
/// prompt's clipboard context.
@MainActor
enum ConcealedPasteboardWriter {
    static func write(_ text: String, to pasteboard: any PasteboardWriting = NSPasteboard.general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: .nsPasteboardConcealed)
    }
}

/// The real pasteboard, reading plain strings from `NSPasteboard.general`.
@MainActor
struct SystemPasteboardReader: PasteboardReading {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func types() -> [NSPasteboard.PasteboardType]? {
        pasteboard.types
    }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }
}

/// The pasteboard half of the reader; the rest is in localvoxtralCore.
extension PolishContextClipboardReader {
    /// The pasteboard's plain string with the sensitive-type and empty-content
    /// rules applied and NUL/control scalars stripped (newline/tab kept), or nil
    /// when the source marked the payload concealed/transient or there is
    /// nothing usable. Shared "is this clipboard readable" decision for both the
    /// polish-context excerpt (below) and the spoken clipboard-paste macro
    /// (`ClipboardPayloadMacro`), so the two features honor identical rules.
    @MainActor
    static func readableSanitizedString(
        from pasteboard: any PasteboardReading
    ) -> String? {
        // Never surface password-manager or transient payloads: a concealed or
        // transient type is the source explicitly asking clipboard tools not to
        // read/retain the contents (nspasteboard.org conventions).
        if let types = pasteboard.types(),
           types.contains(.nsPasteboardConcealed) || types.contains(.nsPasteboardTransient)
        {
            return nil
        }

        guard let raw = pasteboard.string(), !raw.isEmpty else { return nil }

        let sanitized = sanitizeControlCharacters(raw)
        guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return sanitized
    }

    /// Returns the complete sanitized pasteboard string (up to
    /// `retentionCharacterCap`), or nil when there is nothing usable or the
    /// source marked it sensitive.
    ///
    /// Capture retains; it does not select. What the model SEES is chosen later
    /// by `PolishContextBudget` + `PolishContextExcerptSelector`, against the
    /// actual transcript — which capture has not heard yet. Truncating here (as
    /// the original head-of-clipboard `prefix(2000)` did) threw away exactly
    /// the lines a transcript-aware selector needs, and blinded vocabulary
    /// matching to every term past the cut.
    @MainActor
    static func readClipboardContext(
        from pasteboard: any PasteboardReading
    ) -> PolishClipboardContext? {
        guard let sanitized = readableSanitizedString(from: pasteboard) else { return nil }

        let originalCharacterCount = sanitized.count
        let retained = originalCharacterCount > retentionCharacterCap
            ? String(sanitized.prefix(retentionCharacterCap))
            : sanitized
        return PolishClipboardContext(
            retainedText: retained,
            originalCharacterCount: originalCharacterCount
        )
    }
}
