import AppKit
import XCTest

@testable import localvoxtral

/// Each harness and terminal row shows its product's real mark in black and
/// white; the app's own panes keep colored tiles. The marks are hand-reduced
/// SVGs (gradients dropped, cutouts via evenodd, one flattened transform), so
/// "the file exists" is not enough — these tests draw every mark through
/// AppKit's own SVG renderer and require visible, non-solid pixels.
@MainActor
final class SettingsSidebarIconTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        SettingsBrandMarks.resetCachesForTesting()
    }

    override func tearDown() async throws {
        SettingsBrandMarks.resetCachesForTesting()
        try await super.tearDown()
    }

    private var markedPanes: [SettingsTab] {
        [.integrationsClaude, .integrationsOpencode, .integrationsHerdr]
            + TerminalAppCatalog.builtIn.map(SettingsTab.terminal)
    }

    func testHarnessAndTerminalRowsShowMarksAndAppPanesKeepTiles() {
        for tab in markedPanes {
            switch tab.sidebarIcon {
            case .brandMark, .symbolMark:
                break
            default:
                XCTFail("\(tab.rawValue) must show its product's mark, got \(tab.sidebarIcon)")
            }
        }
        let tiled = SettingsTab.allKnownPanes.filter { !markedPanes.contains($0) }
        XCTAssertFalse(tiled.isEmpty)
        for tab in tiled {
            guard case .tile(let systemImage, _) = tab.sidebarIcon else {
                XCTFail("\(tab.rawValue) is an app pane and keeps its colored tile")
                continue
            }
            XCTAssertNotNil(
                NSImage(systemSymbolName: systemImage, accessibilityDescription: nil),
                "\(tab.rawValue): SF Symbol \(systemImage) does not exist"
            )
        }
    }

    func testEveryMarkMakesTheRowItsOwnIcon() {
        var seen: [SettingsSidebarIcon: String] = [:]
        for tab in markedPanes {
            if let other = seen[tab.sidebarIcon] {
                XCTFail("\(tab.rawValue) and \(other) share one icon")
            }
            seen[tab.sidebarIcon] = tab.rawValue
        }
    }

    func testEveryBrandMarkRendersAVisibleTemplateGlyph() throws {
        for tab in markedPanes {
            switch tab.sidebarIcon {
            case .brandMark(let resourceName):
                let image = try XCTUnwrap(
                    SettingsBrandMarks.image(resourceName: resourceName),
                    "\(resourceName).svg is missing from the resource bundle or did not parse"
                )
                XCTAssertTrue(image.isTemplate, "\(resourceName) must tint with the row")
                let coverage = Self.alphaCoverage(of: image, side: 32)
                XCTAssertGreaterThan(
                    coverage, 0.08, "\(resourceName) draws (almost) nothing at sidebar size"
                )
                XCTAssertLessThan(
                    coverage, 0.95, "\(resourceName) draws a solid block; its cutouts were lost"
                )
            case .symbolMark(let systemName):
                XCTAssertNotNil(
                    NSImage(systemSymbolName: systemName, accessibilityDescription: nil),
                    "\(tab.rawValue): SF Symbol \(systemName) does not exist"
                )
            default:
                XCTFail("\(tab.rawValue) has no mark")
            }
        }
    }

    func testMissingMarkStaysMissingAcrossRenders() {
        XCTAssertNil(SettingsBrandMarks.image(resourceName: "BrandIcon-not-bundled"))
        XCTAssertNil(
            SettingsBrandMarks.image(resourceName: "BrandIcon-not-bundled"),
            "a remembered miss still answers nil, not a stale or placeholder image"
        )
    }

    /// A mark nobody shows is dead weight in the bundle, and a mark a row
    /// names but the bundle lacks falls back to a placeholder silently.
    func testBundledMarksAreExactlyTheOnesTheSidebarNames() {
        let named = Set(
            markedPanes.compactMap { tab -> String? in
                if case .brandMark(let resourceName) = tab.sidebarIcon { return resourceName }
                return nil
            }
        )
        let bundled = Set(
            (Bundle.localvoxtralResources.urls(forResourcesWithExtension: "svg", subdirectory: nil)
                ?? [])
                .map { $0.deletingPathExtension().lastPathComponent }
                .filter { $0.hasPrefix("BrandIcon-") }
        )
        XCTAssertEqual(named, bundled)
    }

    func testUserAddedTerminalShowsItsOwnAppIcon() {
        let app = TerminalAppsSettingsModel.descriptor(
            for: UserTerminalApp(bundleID: "dev.some.Editor", displayName: "Editor")
        )
        XCTAssertEqual(
            SettingsTab.terminal(app).sidebarIcon, .appIcon(bundleIDs: ["dev.some.Editor"])
        )
    }

    /// A row for a removed app re-renders on every hover; LaunchServices is
    /// asked once per installed sweep, not once per render.
    func testAppIconMissIsRememberedUntilTheInstalledSweep() {
        var lookups: [String] = []
        SettingsBrandMarks.applicationURLLookup = { bundleID in
            lookups.append(bundleID)
            return nil
        }

        XCTAssertNil(SettingsBrandMarks.appIcon(bundleIDs: ["dev.gone.App"]))
        XCTAssertNil(SettingsBrandMarks.appIcon(bundleIDs: ["dev.gone.App"]))
        XCTAssertEqual(lookups, ["dev.gone.App"])

        let suiteName = "localvoxtral.SettingsSidebarIconTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let model = TerminalAppsSettingsModel(
            settings: SettingsStore(defaults: UserDefaults(suiteName: suiteName)!, environment: [:]),
            applicationURLForBundleID: { _ in nil }
        )
        model.refreshInstalledState()

        XCTAssertNil(SettingsBrandMarks.appIcon(bundleIDs: ["dev.gone.App"]))
        XCTAssertEqual(
            lookups, ["dev.gone.App", "dev.gone.App"],
            "the installed sweep (each Settings open, add, remove) lets a newly installed app show its icon"
        )
    }

    /// Fraction of a `side`×`side` square the image covers with ink.
    private static func alphaCoverage(of image: NSImage, side: Int) -> Double {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: side,
                pixelsHigh: side,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        context.cgContext.clear(rect)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        var inked = 0
        for y in 0..<side {
            for x in 0..<side where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                inked += 1
            }
        }
        return Double(inked) / Double(side * side)
    }
}
