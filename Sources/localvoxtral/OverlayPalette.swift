import AppKit
import SwiftUI

/// The Overlay Buffer panel's colors, one meaning each (#1074). Text and the
/// focused app stay neutral; a hue always says something:
///
/// - `live`: the mic is on. The menu bar mic's session-active orange, so the
///   panel and the menu bar say "recording" the same way.
/// - `session`: an agent session that needs you, as the menu bar's needs-you
///   marks draw it.
/// - `inbox`: a quick capture, saved rather than typed.
/// - `polish`: what the LLM did, the band while it polishes and the words
///   it changed. Its own hue: the system accent is the user's selection
///   color, and blue marks on words read as a text selection.
enum OverlayPalette {
    static let live = Color(nsColor: MenuBarStatusIcon.accentColor)
    static let session = Color.orange
    static let inbox = Color.purple
    nonisolated(unsafe) static var focusedApp = Color.secondary
    /// Teal, darker on a light panel and lighter on a dark one, so the
    /// changed words keep their contrast on both.
    nonisolated(unsafe) static var polish = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.35, green: 0.80, blue: 0.84, alpha: 1)
            : NSColor(srgbRed: 0.03, green: 0.46, blue: 0.51, alpha: 1)
    })
}
