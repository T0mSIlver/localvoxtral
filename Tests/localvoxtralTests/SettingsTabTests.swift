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

    /// The automation scripts press and scope by literal `settings.tab.<raw>`
    /// strings. Reading the scripts here turns a divergence into a unit-test
    /// failure on every push, instead of an AX drill failure that only surfaces
    /// in the evening ui-smoke slot on the Mac.
    func testAutomationScriptsDrillExactlyTheTabsTheEnumDefines() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SettingsTabTests.swift
            .deletingLastPathComponent()  // localvoxtralTests
            .deletingLastPathComponent()  // Tests
        let uiSmoke = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/ui-smoke.sh"),
            encoding: .utf8
        )
        let capture = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/capture-readme-assets.sh"),
            encoding: .utf8
        )
        let rawValues = Set(SettingsTab.allCases.map(\.rawValue))

        XCTAssertEqual(
            Self.firstQuotedArguments(ofCalls: "assert_tab ", in: uiSmoke),
            rawValues,
            "ui-smoke.sh must drill exactly the tabs the enum defines"
        )

        // About is deliberately not captured for the README; every other pane
        // must be, and nothing the enum does not define may appear.
        XCTAssertEqual(
            try Self.shellArrayEntries(named: "TAB_IDS", in: capture),
            rawValues.subtracting(["about"]),
            "capture-readme-assets.sh TAB_IDS must list every captured pane by raw value"
        )
    }

    /// First double-quoted argument of every top-level `<call> "<arg>" ...`
    /// line. Skips the function's own definition line (`<call>() {`).
    private static func firstQuotedArguments(ofCalls call: String, in script: String) -> Set<String> {
        Set(
            script.components(separatedBy: "\n")
                .filter { $0.hasPrefix(call) }
                .compactMap { line in
                    let parts = line.components(separatedBy: "\"")
                    return parts.count > 1 ? parts[1] : nil
                }
        )
    }

    /// Entries of a one-line bash array literal: `NAME=("a" "b" ...)`.
    private static func shellArrayEntries(named name: String, in script: String) throws -> Set<String> {
        let assignment = try XCTUnwrap(
            script.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("\(name)=(") }),
            "\(name)=( … ) assignment not found"
        )
        let entries = assignment.components(separatedBy: "\"")
            .enumerated()
            .filter { $0.offset.isMultiple(of: 2) == false }
            .map(\.element)
        XCTAssertFalse(entries.isEmpty, "\(name) parsed as empty")
        return Set(entries)
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
