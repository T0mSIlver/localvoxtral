import CoreGraphics
import Foundation
import XCTest

@testable import localvoxtral

/// Covers the position the user drags the overlay to: what gets stored, and
/// what comes back when the displays have changed underneath it.
final class OverlayManualPlacementTests: XCTestCase {
    /// 1920×1080 primary, menu bar taking 25pt off the top.
    private let primary = OverlayScreenSnapshot(
        id: "primary",
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
    )
    /// 1440×900 external, to the right of the primary.
    private let external = OverlayScreenSnapshot(
        id: "external",
        frame: CGRect(x: 1920, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 1920, y: 0, width: 1440, height: 900)
    )
    private let panelSize = CGSize(width: 420, height: 140)

    private var margin: CGFloat { OverlayManualPlacementResolver.edgeMargin }

    // MARK: - Capture

    func testCaptureStoresTheTopLeftCornerRelativeToItsScreen() {
        let frame = CGRect(x: 300, y: 700, width: 420, height: 140)
        let placement = OverlayManualPlacementResolver.capture(
            panelFrame: frame, screens: [primary, external])

        XCTAssertEqual(placement?.screenID, "primary")
        // 1080 (screen top) - 840 (panel top) = 240 down from the top edge.
        XCTAssertEqual(placement?.topLeftOffset, CGPoint(x: 300, y: 240))
    }

    func testCaptureStoresTheOffsetWithinTheSecondScreenNotAGlobalPoint() {
        let frame = CGRect(x: 2100, y: 600, width: 420, height: 140)
        let placement = OverlayManualPlacementResolver.capture(
            panelFrame: frame, screens: [primary, external])

        XCTAssertEqual(placement?.screenID, "external")
        XCTAssertEqual(placement?.topLeftOffset, CGPoint(x: 180, y: 160))
    }

    func testCaptureNamesTheScreenThePanelMostlyCovers() {
        // 320 of 420 points wide on the external screen.
        let straddling = CGRect(x: 1820, y: 600, width: 420, height: 140)
        let placement = OverlayManualPlacementResolver.capture(
            panelFrame: straddling, screens: [primary, external])

        XCTAssertEqual(placement?.screenID, "external")
    }

    func testCaptureWithNoScreensStoresNothing() {
        let frame = CGRect(x: 300, y: 700, width: 420, height: 140)
        XCTAssertNil(OverlayManualPlacementResolver.capture(panelFrame: frame, screens: []))
    }

    // MARK: - Restore

    func testRestoreRoundTripsWhenNothingAboutTheDisplaysChanged() throws {
        let frame = CGRect(x: 300, y: 700, width: 420, height: 140)
        let placement = try XCTUnwrap(
            OverlayManualPlacementResolver.capture(panelFrame: frame, screens: [primary, external]))

        let origin = OverlayManualPlacementResolver.resolveOrigin(
            placement, panelSize: frame.size, screens: [primary, external])

        XCTAssertEqual(origin, frame.origin)
    }

    func testRestoreOntoAMissingScreenFallsBackInsteadOfGoingOffscreen() {
        let placement = OverlayManualPlacement(
            screenID: "external", topLeftOffset: CGPoint(x: 180, y: 160))

        // The external display was unplugged between sessions.
        XCTAssertNil(
            OverlayManualPlacementResolver.resolveOrigin(
                placement, panelSize: panelSize, screens: [primary]))
    }

    func testRestoreOntoAResizedScreenClampsBackInsideIt() throws {
        // Stored near the bottom-right of the 1920×1080 primary.
        let placement = OverlayManualPlacement(
            screenID: "primary", topLeftOffset: CGPoint(x: 1400, y: 1000))
        let shrunk = OverlayScreenSnapshot(
            id: "primary",
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 775)
        )

        let origin = try XCTUnwrap(
            OverlayManualPlacementResolver.resolveOrigin(
                placement, panelSize: panelSize, screens: [shrunk]))

        XCTAssertEqual(origin.x, 1280 - 420 - margin)
        XCTAssertEqual(origin.y, margin)
        XCTAssertTrue(
            shrunk.visibleFrame.contains(CGRect(origin: origin, size: panelSize)),
            "restored panel must sit entirely inside the resized screen")
    }

    func testRestoreKeepsThePanelOutFromUnderTheMenuBar() throws {
        // Stored flush with the top of the screen frame, which the menu bar owns.
        let placement = OverlayManualPlacement(
            screenID: "primary", topLeftOffset: .zero)

        let origin = try XCTUnwrap(
            OverlayManualPlacementResolver.resolveOrigin(
                placement, panelSize: panelSize, screens: [primary]))

        XCTAssertEqual(origin.y, primary.visibleFrame.maxY - margin - panelSize.height)
    }

    func testRestoreOfAPanelTallerThanTheScreenPinsItsTopEdge() throws {
        let placement = OverlayManualPlacement(
            screenID: "primary", topLeftOffset: CGPoint(x: 100, y: 400))
        // Narrower AND shorter than the 420×140 panel.
        let tiny = OverlayScreenSnapshot(
            id: "primary",
            frame: CGRect(x: 0, y: 0, width: 300, height: 120),
            visibleFrame: CGRect(x: 0, y: 0, width: 300, height: 120)
        )

        let origin = try XCTUnwrap(
            OverlayManualPlacementResolver.resolveOrigin(
                placement, panelSize: panelSize, screens: [tiny]))

        // Left edge pinned, top edge pinned: the clamp never inverts.
        XCTAssertEqual(origin.x, margin)
        XCTAssertEqual(origin.y + panelSize.height, tiny.visibleFrame.maxY - margin)
    }

    func testMalformedPlacementsAreRefused() {
        let empty = OverlayManualPlacement(screenID: "", topLeftOffset: .zero)
        let notANumber = OverlayManualPlacement(
            screenID: "primary", topLeftOffset: CGPoint(x: CGFloat.nan, y: 0))

        XCTAssertFalse(empty.isWellFormed)
        XCTAssertFalse(notANumber.isWellFormed)
        XCTAssertNil(
            OverlayManualPlacementResolver.resolveOrigin(
                notANumber, panelSize: panelSize, screens: [primary]))
    }

    // MARK: - Dragging

    func testADragDroppedPastTheScreenEdgeSettlesBackOnScreen() throws {
        let dragged = CGRect(x: 1850, y: -300, width: 420, height: 140)

        let settled = try XCTUnwrap(
            OverlayManualPlacementResolver.settle(draggedFrame: dragged, screens: [primary]))

        XCTAssertEqual(settled.frame.origin.x, 1920 - 420 - margin)
        XCTAssertEqual(settled.frame.origin.y, margin)
        XCTAssertEqual(settled.placement.screenID, "primary")
    }

    func testSettledPlacementRestoresToExactlyWhereTheDragLeftIt() throws {
        let dragged = CGRect(x: 1850, y: -300, width: 420, height: 140)
        let settled = try XCTUnwrap(
            OverlayManualPlacementResolver.settle(draggedFrame: dragged, screens: [primary]))

        let origin = OverlayManualPlacementResolver.resolveOrigin(
            settled.placement, panelSize: dragged.size, screens: [primary])

        XCTAssertEqual(origin, settled.frame.origin)
    }

    func testADragOntoTheSecondScreenIsRememberedAgainstThatScreen() throws {
        let dragged = CGRect(x: 2400, y: 500, width: 420, height: 140)

        let settled = try XCTUnwrap(
            OverlayManualPlacementResolver.settle(
                draggedFrame: dragged, screens: [primary, external]))

        XCTAssertEqual(settled.placement.screenID, "external")
        XCTAssertEqual(settled.frame, dragged)
    }

    // MARK: - Persistence

    @MainActor
    func testFirstRunHasNoStoredPosition() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))

        XCTAssertNil(SettingsStore.loadOverlayBufferPlacement(defaults: defaults))
    }

    @MainActor
    func testStoredPositionSurvivesAReload() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())

        store.overlayBufferPlacement = OverlayManualPlacement(
            screenID: "display-uuid", topLeftOffset: CGPoint(x: 120.5, y: 240.25))

        XCTAssertEqual(
            SettingsStore.loadOverlayBufferPlacement(defaults: defaults),
            OverlayManualPlacement(
                screenID: "display-uuid", topLeftOffset: CGPoint(x: 120.5, y: 240.25)))
    }

    @MainActor
    func testReanchoringForgetsTheStoredPosition() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        store.overlayBufferPlacement = OverlayManualPlacement(
            screenID: "display-uuid", topLeftOffset: CGPoint(x: 120, y: 240))

        store.overlayBufferPlacement = nil

        XCTAssertNil(SettingsStore.loadOverlayBufferPlacement(defaults: defaults))
        XCTAssertNil(defaults.object(forKey: "settings.overlay_buffer_position_screen_id"))
        XCTAssertNil(defaults.object(forKey: "settings.overlay_buffer_position_offset_x"))
        XCTAssertNil(defaults.object(forKey: "settings.overlay_buffer_position_offset_y"))
    }

    @MainActor
    func testAHalfWrittenPositionIsIgnored() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("display-uuid", forKey: "settings.overlay_buffer_position_screen_id")
        defaults.set(120.0, forKey: "settings.overlay_buffer_position_offset_x")

        XCTAssertNil(SettingsStore.loadOverlayBufferPlacement(defaults: defaults))
    }

    @MainActor
    func testStoredPositionLoadsIntoTheSettingsStore() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("display-uuid", forKey: "settings.overlay_buffer_position_screen_id")
        defaults.set(120.0, forKey: "settings.overlay_buffer_position_offset_x")
        defaults.set(240.0, forKey: "settings.overlay_buffer_position_offset_y")

        let store = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())

        XCTAssertEqual(
            store.overlayBufferPlacement,
            OverlayManualPlacement(
                screenID: "display-uuid", topLeftOffset: CGPoint(x: 120, y: 240)))
    }
}
