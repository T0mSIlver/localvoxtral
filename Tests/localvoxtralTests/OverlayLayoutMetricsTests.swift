import XCTest

@testable import localvoxtral

final class OverlayLayoutMetricsTests: XCTestCase {
    /// Scale 1.0 — the layout the fixed-size overlay historically rendered.
    private let baseMetrics = OverlayLayoutMetrics(
        bodyFontSize: Double(OverlayLayoutMetrics.baseBodyFontSize))

    // MARK: - Clamping

    func testInitClampsFontSizeToSupportedRange() {
        XCTAssertEqual(
            OverlayLayoutMetrics(bodyFontSize: 99).bodyFontSize,
            OverlayLayoutMetrics.maximumBodyFontSize)
        XCTAssertEqual(
            OverlayLayoutMetrics(bodyFontSize: 4).bodyFontSize,
            OverlayLayoutMetrics.minimumBodyFontSize)
        XCTAssertEqual(OverlayLayoutMetrics(bodyFontSize: 16).bodyFontSize, 16)
    }

    // MARK: - Base size preserves the legacy fixed layout

    func testBaseFontSizeReproducesLegacyLayoutConstants() {
        XCTAssertEqual(baseMetrics.scale, 1.0)
        XCTAssertEqual(baseMetrics.bodyFontSize, 13)
        XCTAssertEqual(baseMetrics.titleFontSize, 11)
        XCTAssertEqual(baseMetrics.errorFontSize, 11)
        XCTAssertEqual(baseMetrics.headerHeight, 16)
        XCTAssertEqual(baseMetrics.panelMinWidth, 400)
        XCTAssertEqual(baseMetrics.panelWidth, 420)
        XCTAssertEqual(baseMetrics.panelMaxWidth, 540)
        XCTAssertEqual(baseMetrics.maximumPanelHeight, 420)
        XCTAssertEqual(baseMetrics.textMeasurementWidth, 400)
    }

    func testBaseEmptyTextContentHeightMatchesLegacyFormula() {
        // Legacy measureContentHeight: padding(20) + header(16) + spacing(8)
        // + one body line.
        let expected = 20 + 16 + 8 + baseMetrics.bodyLineHeight
        XCTAssertEqual(baseMetrics.contentHeight(text: "", errorMessage: nil), expected)
        // Whitespace-only buffers render as empty.
        XCTAssertEqual(baseMetrics.contentHeight(text: "  \n ", errorMessage: nil), expected)
    }

    func testDefaultFontSizeIs14AndWithinSupportedRange() {
        XCTAssertEqual(OverlayLayoutMetrics.defaultBodyFontSize, 14)
        let metrics = OverlayLayoutMetrics(bodyFontSize: OverlayLayoutMetrics.defaultBodyFontSize)
        // Must survive clamping unchanged, or fresh installs wouldn't get it.
        XCTAssertEqual(metrics.bodyFontSize, 14)
    }

    // MARK: - Scaling behavior

    func testLargerFontProducesTallerAndWiderPanel() {
        let large = OverlayLayoutMetrics(bodyFontSize: 24)
        let text = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 6)

        XCTAssertGreaterThan(large.panelWidth, baseMetrics.panelWidth)
        XCTAssertGreaterThan(large.bodyLineHeight, baseMetrics.bodyLineHeight)
        XCTAssertGreaterThan(
            large.contentHeight(text: text, errorMessage: nil),
            baseMetrics.contentHeight(text: text, errorMessage: nil))
    }

    func testBodyHeightCapsAtFourLinesRegardlessOfFontSize() {
        for size in [OverlayLayoutMetrics.minimumBodyFontSize, 13, 18, 24] {
            let metrics = OverlayLayoutMetrics(bodyFontSize: size)
            let longText = String(repeating: "scrolling buffer text keeps growing ", count: 60)
            XCTAssertEqual(
                metrics.bodyTextHeight(for: longText),
                metrics.maxScrollableBodyHeight,
                "font size \(size)")
            XCTAssertGreaterThan(
                metrics.unclampedBodyTextHeight(for: longText),
                metrics.maxScrollableBodyHeight,
                "font size \(size)")
        }
    }

    // MARK: - Session lock (opencode review finding, PR #104)

    /// The controller locks the panel's X origin for a session assuming a
    /// constant width, so a mid-session slider change must NOT change the
    /// metrics until the overlay hides — otherwise the panel widens past its
    /// locked origin and can run off-screen.
    func testSessionLockFreezesFontSizeUntilUnlocked() {
        var lock = OverlaySessionMetricsLock()
        let first = lock.metrics(currentFontSize: 14)
        XCTAssertEqual(first.bodyFontSize, 14)

        // Mid-session setting change: locked metrics keep the session's size.
        let midSession = lock.metrics(currentFontSize: 24)
        XCTAssertEqual(midSession, first)
        XCTAssertEqual(midSession.panelWidth, first.panelWidth)

        // After the session ends the new size applies.
        lock.unlock()
        let nextSession = lock.metrics(currentFontSize: 24)
        XCTAssertEqual(nextSession.bodyFontSize, 24)
        XCTAssertGreaterThan(nextSession.panelWidth, first.panelWidth)
    }

    func testErrorMessageAddsHeight() {
        let without = baseMetrics.contentHeight(text: "hello", errorMessage: nil)
        let with = baseMetrics.contentHeight(text: "hello", errorMessage: "Insert failed")
        XCTAssertGreaterThan(with, without)
        // Blank errors are not rendered, so they must not add height.
        XCTAssertEqual(baseMetrics.contentHeight(text: "hello", errorMessage: "   "), without)
    }
}
