import XCTest

@testable import localvoxtral

final class OverlayLayoutMetricsTests: XCTestCase {
    private let defaultMetrics = OverlayLayoutMetrics(
        bodyFontSize: OverlayLayoutMetrics.defaultBodyFontSize)

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

    // MARK: - Default size preserves the legacy fixed layout

    func testDefaultFontSizeReproducesLegacyLayoutConstants() {
        XCTAssertEqual(defaultMetrics.scale, 1.0)
        XCTAssertEqual(defaultMetrics.bodyFontSize, 13)
        XCTAssertEqual(defaultMetrics.titleFontSize, 11)
        XCTAssertEqual(defaultMetrics.errorFontSize, 11)
        XCTAssertEqual(defaultMetrics.headerHeight, 16)
        XCTAssertEqual(defaultMetrics.panelMinWidth, 400)
        XCTAssertEqual(defaultMetrics.panelWidth, 420)
        XCTAssertEqual(defaultMetrics.panelMaxWidth, 540)
        XCTAssertEqual(defaultMetrics.maximumPanelHeight, 420)
        XCTAssertEqual(defaultMetrics.textMeasurementWidth, 400)
    }

    func testDefaultEmptyTextContentHeightMatchesLegacyFormula() {
        // Legacy measureContentHeight: padding(20) + header(16) + spacing(8)
        // + one body line.
        let expected = 20 + 16 + 8 + defaultMetrics.bodyLineHeight
        XCTAssertEqual(defaultMetrics.contentHeight(text: "", errorMessage: nil), expected)
        // Whitespace-only buffers render as empty.
        XCTAssertEqual(defaultMetrics.contentHeight(text: "  \n ", errorMessage: nil), expected)
    }

    // MARK: - Scaling behavior

    func testLargerFontProducesTallerAndWiderPanel() {
        let large = OverlayLayoutMetrics(bodyFontSize: 24)
        let text = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 6)

        XCTAssertGreaterThan(large.panelWidth, defaultMetrics.panelWidth)
        XCTAssertGreaterThan(large.bodyLineHeight, defaultMetrics.bodyLineHeight)
        XCTAssertGreaterThan(
            large.contentHeight(text: text, errorMessage: nil),
            defaultMetrics.contentHeight(text: text, errorMessage: nil))
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

    func testErrorMessageAddsHeight() {
        let without = defaultMetrics.contentHeight(text: "hello", errorMessage: nil)
        let with = defaultMetrics.contentHeight(text: "hello", errorMessage: "Insert failed")
        XCTAssertGreaterThan(with, without)
        // Blank errors are not rendered, so they must not add height.
        XCTAssertEqual(defaultMetrics.contentHeight(text: "hello", errorMessage: "   "), without)
    }
}
