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

    /// The pane header is the title only (owner review, 2026-09-07): every
    /// pane subtitle ("What the polisher and your coding agents may see." and
    /// siblings) was narration and was deleted so the first group starts
    /// higher. Pins the deletion at the source, the same way the script-pinning
    /// tests below hold the AX drills, so a future "helpful" subtitle cannot
    /// silently return.
    func testPaneHeaderIsTitleOnly() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SettingsTabTests.swift
            .deletingLastPathComponent()  // localvoxtralTests
            .deletingLastPathComponent()  // Tests
        let headerSource = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Sources/localvoxtral/Settings/SettingsPaneHeader.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(
            headerSource.contains("tab.subtitle"),
            "pane subtitles were deleted by owner review; put new explanations in the docs, not the header"
        )
        XCTAssertFalse(
            headerSource.contains(".subheadline"),
            "the header renders exactly one line: the tab title"
        )
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
        let captureIDs = try Self.shellArrayEntries(named: "TAB_IDS", in: capture)
        XCTAssertEqual(
            Set(captureIDs),
            rawValues.subtracting(["about"]),
            "capture-readme-assets.sh TAB_IDS must list every captured pane by raw value"
        )

        // The script iterates the three arrays in lockstep under `set -u`, so
        // a TAB_IDS entry without its TAB_NAMES/TAB_FILES sibling only fails
        // at README-regen time on the Mac. Pin the alignment here instead.
        let captureNames = try Self.shellArrayEntries(named: "TAB_NAMES", in: capture)
        let captureFiles = try Self.shellArrayEntries(named: "TAB_FILES", in: capture)
        XCTAssertEqual(
            captureNames.count, captureIDs.count,
            "TAB_NAMES and TAB_IDS must stay index-aligned"
        )
        XCTAssertEqual(
            captureFiles.count, captureIDs.count,
            "TAB_FILES and TAB_IDS must stay index-aligned"
        )
    }

    /// `SettingsView.swift` source, for the copy/layout pins above. Read from
    /// the repo rather than inlined constants so the assertion runs against
    /// what actually ships.
    private static func settingsViewSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SettingsTabTests.swift
            .deletingLastPathComponent()  // localvoxtralTests
            .deletingLastPathComponent()  // Tests
        return try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/localvoxtral/SettingsView.swift"),
            encoding: .utf8
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
    private static func shellArrayEntries(named name: String, in script: String) throws -> [String] {
        let assignment = try XCTUnwrap(
            script.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("\(name)=(") }),
            "\(name)=( … ) assignment not found"
        )
        let entries = assignment.components(separatedBy: "\"")
            .enumerated()
            .filter { $0.offset.isMultiple(of: 2) == false }
            .map(\.element)
        XCTAssertFalse(
            entries.isEmpty,
            "\(name) parsed as empty — this parser expects the whole array on one line; "
                + "if the script was reformatted, teach the parser the new shape"
        )
        return entries
    }

    /// The clipboard toggle's help must name the real payload: a capped,
    /// sanitized EXCERPT of the clipboard attached to the polish prompt
    /// (`PolishContextClipboardReader`). "Technical terms" understated what
    /// leaves the machine (an independent review of PR #282 caught it), so
    /// the line is pinned here the same way the header source is pinned
    /// above — against the understatement returning.
    func testClipboardHelpNamesTheExcerptNotTechnicalTerms() throws {
        let source = try Self.settingsViewSource()

        let title = try XCTUnwrap(
            source.range(of: "title: \"Clipboard\""),
            "the Clipboard toggle row is gone from SettingsView.swift"
        )
        // The row's `help:` argument is the next one after its title.
        let afterTitle = source[title.upperBound...]
        let helpOpening = try XCTUnwrap(
            afterTitle.range(of: "help: \""),
            "the Clipboard toggle has no help line"
        )
        let helpLine = afterTitle[helpOpening.upperBound...].prefix(while: { $0 != "\n" })

        XCTAssertTrue(
            helpLine.contains("excerpt"),
            "clipboard help must say an excerpt of the clipboard is sent, was: \(helpLine)"
        )
        XCTAssertFalse(
            helpLine.contains("technical terms"),
            "\"technical terms\" understates the payload — a capped excerpt of the whole "
                + "clipboard goes to the polisher, not just terms; was: \(helpLine)"
        )
    }

    /// Layout rules for the Integrations remote rows (PR #282 review), pinned
    /// at the source because no render seam exists for them (no `#Preview`,
    /// no view-inspector dependency):
    ///
    /// - the plain-SSH setup status is an INSTRUCTION ("Open a new terminal
    ///   window for it to take effect.") and must wrap to a second line
    ///   (`lineLimit(2)` + `fixedSize(horizontal: false, vertical: true)`),
    ///   never truncate;
    /// - a host label (up to the registry's 64-character cap) must not squeeze
    ///   "Last context: …" off its line: the label truncates from the middle
    ///   at a layout priority below the status's.
    func testRemoteRowsWrapInstructionsAndCapHostLabels() throws {
        let source = try Self.settingsViewSource()

        let shellSetup = try XCTUnwrap(
            source.range(of: "private var shellSetup: some View {"),
            "the plain-SSH setup row (shellSetup) moved — update this test's anchor"
        )
        // Up to the next member (hostList) = the shellSetup body.
        let nextMember = try XCTUnwrap(
            source.range(
                of: "private var hostList",
                range: shellSetup.upperBound..<source.endIndex
            ),
            "hostList no longer follows shellSetup — update this test's anchor"
        )
        let row = source[shellSetup.lowerBound..<nextMember.lowerBound]
        XCTAssertTrue(
            row.contains(".lineLimit(2)"),
            "the shell-setup status may wrap to a second line instead of truncating"
        )
        XCTAssertTrue(
            row.contains(".fixedSize(horizontal: false, vertical: true)"),
            "the shell-setup status needs fixedSize to actually take its second line"
        )

        let label = try XCTUnwrap(
            source.range(of: "Text(host.label)"),
            "the host-row label (Text(host.label)) moved — update this test's anchor"
        )
        let labelModifiers = source[label.upperBound...].prefix(300)
        XCTAssertTrue(
            labelModifiers.contains(".lineLimit(1)"),
            "a 64-char host label must be one line, not an unbounded wrap"
        )
        XCTAssertTrue(
            labelModifiers.contains(".truncationMode(.middle)"),
            "a long host label should truncate from the middle (head and tail stay readable)"
        )
        let status = try XCTUnwrap(
            source.range(of: "Text(host.statusText)"),
            "the host-row status (Text(host.statusText)) moved — update this test's anchor"
        )
        let statusModifiers = source[status.upperBound...].prefix(300)
        XCTAssertTrue(
            statusModifiers.contains(".lineLimit(1)"),
            "the \"Last context\" status keeps one full line"
        )
        XCTAssertTrue(
            statusModifiers.contains(".layoutPriority(1)"),
            "the status outranks the label when width runs out"
        )
    }

    /// The Context → Integrations rename (this tab never shipped, so the raw
    /// value moved with it). Pins the owner decision: one row per harness.
    func testIntegrationsTabChrome() {
        XCTAssertEqual(SettingsTab.integrations.title, "Integrations")
        XCTAssertEqual(SettingsTab.integrations.rawValue, "integrations")
    }

    func testEndpointsTabKeepsRawValueWhileDisplayingEngines() {
        XCTAssertEqual(SettingsTab.endpoints.title, "Engines")
        XCTAssertEqual(SettingsTab.endpoints.rawValue, "endpoints")
    }

    /// Presentation order is a UX contract of its own: the coverage tests
    /// above compare Sets, so an accidental reorder (an alphabetical sort, a
    /// careless merge) would pass every other test while moving rows the user
    /// has already built muscle memory for.
    func testSidebarOrderIsThePresentationContract() {
        XCTAssertEqual(
            SettingsTab.primarySidebarItems,
            [.general, .dictation, .endpoints, .textProcessing, .integrations]
        )
        XCTAssertEqual(SettingsTab.metaSidebarItems, [.about])
    }

    /// The scripts hardcode these strings; renaming a case silently breaks the
    /// AX drills, which is exactly the failure this pins.
    func testRawValuesAreStable() {
        XCTAssertEqual(
            Set(SettingsTab.allCases.map(\.rawValue)),
            ["general", "endpoints", "dictation", "textProcessing", "integrations", "about"]
        )
    }
}
