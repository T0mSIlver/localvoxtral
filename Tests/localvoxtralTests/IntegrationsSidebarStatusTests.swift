import XCTest

@testable import localvoxtral

/// The Integrations section's status dots (owner decision, 2026-09-07):
/// green = detected and set up, yellow = detected with a setup step pending,
/// grey = not installed / not detected. Each derivation is pinned per input
/// state so a future reshuffle of the enum cannot silently repaint a row.
final class IntegrationsSidebarStatusTests: XCTestCase {
    func testContextDotIsGreenWhenAnyConsentIsOn() {
        XCTAssertEqual(IntegrationsSidebarStatus.contextDot(anyConsentEnabled: true), .green)
        XCTAssertEqual(IntegrationsSidebarStatus.contextDot(anyConsentEnabled: false), .grey)
    }

    func testClaudeDotFollowsThePluginStatus() {
        XCTAssertEqual(
            IntegrationsSidebarStatus.claudeDot(pluginStatus: .installed(version: "1.4.0")),
            .green
        )
        XCTAssertEqual(
            IntegrationsSidebarStatus.claudeDot(
                pluginStatus: .updateAvailable(installed: "1.3.0", bundled: "1.4.0")
            ),
            .green,
            "an installed plugin with an optional update still joins fine"
        )
        XCTAssertEqual(
            IntegrationsSidebarStatus.claudeDot(pluginStatus: .notInstalled),
            .yellow,
            "the CLI answered the listing, so Claude Code is detected and only setup is pending"
        )
        XCTAssertEqual(
            IntegrationsSidebarStatus.claudeDot(pluginStatus: .unknown),
            .grey,
            "a failed probe detected nothing"
        )
    }

    func testOpencodeDotFollowsThePluginStatus() {
        XCTAssertEqual(
            IntegrationsSidebarStatus.opencodeDot(status: .installed), .green
        )
        XCTAssertEqual(
            IntegrationsSidebarStatus.opencodeDot(status: .updateAvailable), .green
        )
        XCTAssertEqual(
            IntegrationsSidebarStatus.opencodeDot(status: .notInstalled), .yellow
        )
        XCTAssertEqual(
            IntegrationsSidebarStatus.opencodeDot(status: .installedUnlisted),
            .yellow,
            "the file is there but tui.json does not list it: detected, setup pending"
        )
        XCTAssertEqual(
            IntegrationsSidebarStatus.opencodeDot(status: .unknown),
            .grey,
            "no readable opencode config covers not-installed; it is grey, never yellow"
        )
    }

    func testHerdrDotIsGreenWhenDetectedAndNeverYellow() {
        XCTAssertEqual(IntegrationsSidebarStatus.herdrDot(isDetected: true), .green)
        XCTAssertEqual(IntegrationsSidebarStatus.herdrDot(isDetected: false), .grey)
        // The owner decision pins that herdr "found but no host reported a
        // pane yet" is NOT yellow — herdr needs no setup. The derivation has
        // no yellow output at all, which is the pin.
    }
}
