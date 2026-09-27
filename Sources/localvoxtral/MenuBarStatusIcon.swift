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
/// colored pixels are drawn on top unchanged.
///
/// The colors live in the PNGs. They sit inside the mic head, so they must
/// read against both a black and a white mic: the session-active orange
/// (#FF8204, Mistral brand) is 8.4:1 and 2.5:1; yellow was 1.5:1 on white.
enum MenuBarStatusIcon {
    static func appearanceAdaptive(template: NSImage, colored: NSImage) -> NSImage {
        let size = template.size
        let accent = accentOnly(colored: colored, template: template, size: size)
        let image = NSImage(size: size, flipped: false) { rect in
            template.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            accent.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The session-active orange, which the colored PNGs carry.
    static let accentColor = NSColor(srgbRed: 255 / 255, green: 130 / 255, blue: 4 / 255, alpha: 1)

    /// The mic in the menu bar's text color with an orange mark right of its
    /// head: an agent needs you (#717). Drawn per appearance, like the others.
    ///
    /// The mark's cells sit on the mic's pixel grid: 1 pt each, which the
    /// @2x art offsets by half a point.
    static func withAttentionMark(template: NSImage, mark: AgentAttentionMark) -> NSImage {
        let size = template.size
        let image = NSImage(size: size, flipped: false) { rect in
            template.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            let cell = rect.width / 22
            accentColor.setFill()
            for (x, y) in mark.cells {
                NSRect(
                    x: rect.minX + (0.5 + CGFloat(x)) * cell,
                    y: rect.maxY - (1.5 + CGFloat(y)) * cell,
                    width: cell, height: cell
                ).fill()
            }
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
}
