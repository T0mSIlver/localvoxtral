import AppKit
import XCTest
@testable import localvoxtral

/// The colored menu bar icons baked a black mic, which vanished on a dark
/// menu bar while the idle template icon turned white. The mic must follow
/// the appearance it is drawn under; the colored pixels must not.
final class MenuBarStatusIconTests: XCTestCase {
    private static let iconDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../assets/icons/menubar")
        .standardizedFileURL

    // In the 44 px @2x assets, from the top-left: a mic-body pixel, and one
    // of the colored pixels inside the mic head.
    private let micPixel = (x: 20, y: 5)
    private let accentPixel = (x: 19, y: 11)

    func testMicIsDarkOnLightMenuBarAndLightOnDarkMenuBar() throws {
        let icon = try makeIcon(colored: "MicIconTemplate@2x_connected.png")

        let light = try XCTUnwrap(render(icon, appearance: .aqua).colorAt(x: micPixel.x, y: micPixel.y))
        let dark = try XCTUnwrap(render(icon, appearance: .darkAqua).colorAt(x: micPixel.x, y: micPixel.y))

        XCTAssertGreaterThan(light.alphaComponent, 0.5)
        XCTAssertGreaterThan(dark.alphaComponent, 0.5)
        XCTAssertLessThan(brightness(light), 0.2, "mic on a light menu bar: \(light)")
        XCTAssertGreaterThan(brightness(dark), 0.8, "mic on a dark menu bar: \(dark)")
    }

    func testAccentsKeepTheirColorInEveryAppearance() throws {
        for (file, expected) in [
            ("MicIconTemplate@2x_connected.png", (r: 255.0, g: 130.0, b: 4.0)),
            ("MicIconTemplate@2x_failure.png", (r: 225.0, g: 5.0, b: 0.0)),
        ] {
            let icon = try makeIcon(colored: file)
            for appearance in [NSAppearance.Name.aqua, .vibrantLight, .darkAqua, .vibrantDark] {
                let color = try XCTUnwrap(
                    render(icon, appearance: appearance).colorAt(x: accentPixel.x, y: accentPixel.y)
                )
                let context = "\(file) \(appearance.rawValue)"
                XCTAssertEqual(color.redComponent * 255, expected.r, accuracy: 3, context)
                XCTAssertEqual(color.greenComponent * 255, expected.g, accuracy: 3, context)
                XCTAssertEqual(color.blueComponent * 255, expected.b, accuracy: 3, context)
            }
        }
    }

    private func makeIcon(colored file: String) throws -> NSImage {
        let template = try XCTUnwrap(
            NSImage(contentsOf: Self.iconDirectory.appendingPathComponent("MicIconTemplate@2x.png"))
        )
        template.isTemplate = true
        let colored = try XCTUnwrap(NSImage(contentsOf: Self.iconDirectory.appendingPathComponent(file)))
        colored.size = template.size
        return MenuBarStatusIcon.appearanceAdaptive(template: template, colored: colored)
    }

    private func render(_ image: NSImage, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
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

    private func brightness(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
    }
}
