import XCTest

@testable import localvoxtral

/// The sidebar is data-driven: a tab that is in `allCases` but in neither
/// sidebar array is unreachable in the UI, and a tab in both would render twice.
/// The AX identifiers are a contract with `scripts/ui-smoke.sh` and
/// `scripts/capture-readme-assets.sh`, which press and scope by literal string.
final class SettingsTabTests: XCTestCase {
    private var sidebarItems: [SettingsTab] {
        SettingsTab.primarySidebarItems + SettingsTab.metaSidebarItems
    }

    func testSidebarArraysCoverEveryTabExactlyOnce() {
        XCTAssertEqual(
            Set(sidebarItems), Set(SettingsTab.allCases),
            "every SettingsTab must appear in the sidebar"
        )
        XCTAssertEqual(
            sidebarItems.count, SettingsTab.allCases.count,
            "sidebar arrays must not list a tab twice"
        )
    }

    func testSidebarArraysDoNotOverlap() {
        let primary = Set(SettingsTab.primarySidebarItems)
        let meta = Set(SettingsTab.metaSidebarItems)
        XCTAssertTrue(
            primary.isDisjoint(with: meta),
            "a tab pinned to the bottom must not also be in the primary group"
        )
        XCTAssertEqual(
            SettingsTab.primarySidebarItems.count, primary.count,
            "primary sidebar items must be unique"
        )
        XCTAssertEqual(
            SettingsTab.metaSidebarItems.count, meta.count,
            "meta sidebar items must be unique"
        )
    }

    func testEveryTabHasCompleteChrome() {
        for tab in SettingsTab.allCases {
            XCTAssertFalse(tab.title.isEmpty, "\(tab.rawValue) has no title")
            XCTAssertFalse(tab.subtitle.isEmpty, "\(tab.rawValue) has no subtitle")
            XCTAssertFalse(tab.systemImage.isEmpty, "\(tab.rawValue) has no SF Symbol")
            XCTAssertFalse(
                tab.accessibilityIdentifier.isEmpty,
                "\(tab.rawValue) has no accessibility identifier"
            )
            XCTAssertFalse(
                tab.paneAccessibilityIdentifier.isEmpty,
                "\(tab.rawValue) has no pane accessibility identifier"
            )
        }
    }

    func testSubtitlesAreOneLineSentences() {
        for tab in SettingsTab.allCases {
            XCTAssertFalse(
                tab.subtitle.contains("\n"),
                "\(tab.rawValue) subtitle must be a single line"
            )
            XCTAssertTrue(
                tab.subtitle.hasSuffix("."),
                "\(tab.rawValue) subtitle must read as a sentence"
            )
        }
    }

    func testAccessibilityIdentifiersUseTheDrillScheme() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(tab.accessibilityIdentifier, "settings.tab.\(tab.rawValue)")
            XCTAssertEqual(tab.paneAccessibilityIdentifier, "settings.pane.\(tab.rawValue)")
        }
    }

    /// The Context pane's drill ids, spelled out: `scripts/ui-smoke.sh` and
    /// `scripts/capture-readme-assets.sh` press and scope by these literals.
    func testContextTabUsesTheDrillIdentifiersTheScriptsHardcode() {
        XCTAssertEqual(SettingsTab.context.accessibilityIdentifier, "settings.tab.context")
        XCTAssertEqual(SettingsTab.context.paneAccessibilityIdentifier, "settings.pane.context")
    }

    /// The scripts hardcode these strings; renaming a case silently breaks the
    /// AX drills, which is exactly the failure this pins.
    func testRawValuesAreStable() {
        XCTAssertEqual(
            Set(SettingsTab.allCases.map(\.rawValue)),
            ["general", "endpoints", "dictation", "textProcessing", "context", "about"]
        )
    }
}
