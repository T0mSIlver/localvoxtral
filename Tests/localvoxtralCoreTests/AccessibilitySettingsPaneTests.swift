import Foundation
import XCTest

@testable import localvoxtralCore

/// macOS 27 renamed the Accessibility pane; copy that sends the user there
/// names the one their macOS shows (#1206).
final class AccessibilitySettingsPaneTests: XCTestCase {
    func testEachMacOSGetsItsPaneName() {
        let expected = [
            15: "System Settings > Privacy & Security > Accessibility",
            26: "System Settings > Privacy & Security > Accessibility",
            27: "System Settings > Privacy & Security > Device Control and Data Access",
            28: "System Settings > Privacy & Security > Device Control and Data Access",
        ]
        for (version, path) in expected {
            XCTAssertEqual(AccessibilitySettingsPane(macOSMajorVersion: version).path, path, "macOS \(version)")
        }
    }

    func testDoctorNamesTheMacOS27Pane() throws {
        let facts = AgentCLIDoctorFacts(
            microphone: .granted, accessibilityTrusted: false,
            accessibilityPane: AccessibilitySettingsPane(macOSMajorVersion: 27),
            speech: .off, polish: .off, claudePlugin: nil, remoteHosts: [], recentJoins: [],
            now: Date(timeIntervalSince1970: 0)
        )
        for checks in [AgentCLIDoctorChecks.checks(facts), AgentCLIDoctorChecks.hostChecks(facts, hostIndex: nil)] {
            let check = try XCTUnwrap(checks.first { $0.id == "accessibility" })
            XCTAssertEqual(check.title, "Device Control and Data Access")
            XCTAssertEqual(
                check.fix?.hasPrefix("System Settings > Privacy & Security > Device Control and Data Access: "), true,
                check.fix ?? "no fix"
            )
        }
    }
}
