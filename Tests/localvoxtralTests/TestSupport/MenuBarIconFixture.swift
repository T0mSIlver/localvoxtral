import AppKit
import XCTest

/// The menu bar icon assets, and a 44 px render of an icon under a given
/// appearance, as the menu bar would draw it.
enum MenuBarIconFixture {
    static let iconDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../assets/icons/menubar")
        .standardizedFileURL

    static func template() throws -> NSImage {
        let template = try XCTUnwrap(
            NSImage(contentsOf: iconDirectory.appendingPathComponent("MicIconTemplate@2x.png"))
        )
        template.isTemplate = true
        return template
    }

    static func render(_ image: NSImage, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 44,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        )
        rep.size = image.size
        let appearance = try XCTUnwrap(NSAppearance(named: appearance))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: image.size))
        }
        NSGraphicsContext.current?.flushGraphics()
        return rep
    }
}
