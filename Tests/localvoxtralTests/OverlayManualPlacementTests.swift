import CoreGraphics
import Foundation
import XCTest

@testable import localvoxtral

/// Covers the position the user drags the overlay to: what gets stored, and
/// what comes back when the displays have changed underneath it.
final class OverlayManualPlacementTests: XCTestCase {
    // MARK: - Anchored placement

    /// A display unplugged mid-dictation takes the panel's locked position
    /// with it: the next render puts the panel back on a display that is
    /// still attached. The displays sit far from any real one, so a panel
    /// placed from `NSScreen` instead of the provider fails here too.
    @MainActor
    func testAnchoredPanelReturnsOnscreenAfterDisplayRemoval() {
        let left = OverlayScreenSnapshot(
            id: "left",
            frame: CGRect(x: 20_000, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 20_000, y: 0, width: 1920, height: 1055))
        let right = OverlayScreenSnapshot(
            id: "right",
            frame: CGRect(x: 21_920, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 21_920, y: 0, width: 1440, height: 900))
        var screens = [left, right]
        let controller = DictationOverlayController(screensProvider: { screens })
        defer { controller.hide() }
        let snapshot = OverlayBufferStateMachine.Snapshot(
            phase: .buffering,
            bufferText: "dictated words",
            errorMessage: nil,
            secureInputActive: false,
            polished: false,
            claudeJoin: .hidden,
            destinations: nil,
            anchor: OverlayAnchor(
                targetRect: CGRect(x: 22_600, y: 800, width: 10, height: 10), source: .mouseLocation))

        controller.render(snapshot: snapshot)
        XCTAssertTrue(
            right.visibleFrame.contains(controller.panelFrameForTesting),
            "\(controller.panelFrameForTesting) opens on the anchor's display")

        screens = [left]
        controller.render(snapshot: snapshot)

        XCTAssertTrue(
            left.visibleFrame.contains(controller.panelFrameForTesting),
            "\(controller.panelFrameForTesting) is back inside \(left.visibleFrame)")
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
