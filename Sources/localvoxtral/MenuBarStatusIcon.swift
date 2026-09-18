import AppKit

/// Builds the colored menu bar icons (session active, failure) so their mic
/// follows the menu bar like the idle template icon does.
///
/// The colored PNGs are the template mic with colored pixels added where the
/// template is transparent, and the mic itself baked in black. Drawn as-is,
/// that mic stays black on a dark menu bar. The menu bar's light/dark state
/// is not the system appearance either: a transparent menu bar follows the
/// wallpaper. So the icon is drawn on demand: AppKit re-runs the drawing
/// handler under the menu bar's own appearance, which tints the mic, and the
/// colored pixels are drawn on top.
///
/// The colored pixels sit inside the mic head, so on a dark menu bar they are
/// surrounded by a light mic. Yellow on that reads poorly (1.5:1), hence
/// `darkMenuBarAccent`: a replacement color for those pixels there only.
enum MenuBarStatusIcon {
    /// Mistral brand orange: 2.5:1 against the light mic, and still clearly
    /// apart from the red failure accent (the brand's redder orange,
    /// #FA500F, is nearly indistinguishable from it at icon size).
    static let sessionActiveDarkMenuBarAccent = NSColor(
        srgbRed: 0xFF / 255.0, green: 0x82 / 255.0, blue: 0x04 / 255.0, alpha: 1
    )

    static func appearanceAdaptive(
        template: NSImage,
        colored: NSImage,
        darkMenuBarAccent: NSColor? = nil
    ) -> NSImage {
        let size = template.size
        let accent = accentOnly(colored: colored, template: template, size: size)
        let darkAccent = darkMenuBarAccent.map { recolored(accent, with: $0) } ?? accent
        let image = NSImage(size: size, flipped: false) { rect in
            template.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            (isDarkDrawingAppearance() ? darkAccent : accent).draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The colored pixels alone: the colored icon with the template's mic cut
    /// out of it.
    private static func accentOnly(colored: NSImage, template: NSImage, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            colored.draw(in: rect)
            template.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
            return true
        }
    }

    private static func recolored(_ image: NSImage, with color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func isDarkDrawingAppearance() -> Bool {
        let dark: [NSAppearance.Name] = [
            .darkAqua, .vibrantDark,
            .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark,
        ]
        let light: [NSAppearance.Name] = [
            .aqua, .vibrantLight,
            .accessibilityHighContrastAqua, .accessibilityHighContrastVibrantLight,
        ]
        guard let match = NSAppearance.currentDrawing().bestMatch(from: dark + light) else {
            return false
        }
        return dark.contains(match)
    }
}
