import AppKit
import SwiftUI
import XCTest

@testable import localvoxtral

@MainActor
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
        let first = lock.metrics { OverlayLayoutMetrics(bodyFontSize: 14) }
        XCTAssertEqual(first.bodyFontSize, 14)

        // Mid-session setting change: locked metrics keep the session's size.
        let midSession = lock.metrics { OverlayLayoutMetrics(bodyFontSize: 24, visibleLines: 8) }
        XCTAssertEqual(midSession, first)
        XCTAssertEqual(midSession.panelWidth, first.panelWidth)

        // After the session ends the new settings apply.
        lock.unlock()
        let nextSession = lock.metrics { OverlayLayoutMetrics(bodyFontSize: 24, visibleLines: 8) }
        XCTAssertEqual(nextSession.bodyFontSize, 24)
        XCTAssertEqual(nextSession.visibleLines, 8)
        XCTAssertGreaterThan(nextSession.panelWidth, first.panelWidth)
    }

    // MARK: - Visible lines setting

    func testInitClampsVisibleLinesToSupportedRange() {
        XCTAssertEqual(OverlayLayoutMetrics(bodyFontSize: 14).visibleLines, 4)
        XCTAssertEqual(
            OverlayLayoutMetrics(bodyFontSize: 14, visibleLines: 99).visibleLines,
            OverlayLayoutMetrics.maximumVisibleLines)
        XCTAssertEqual(
            OverlayLayoutMetrics(bodyFontSize: 14, visibleLines: 0).visibleLines,
            OverlayLayoutMetrics.minimumVisibleLines)
    }

    /// The setting is a count of whole lines: N lines of text fit without
    /// scrolling, N+1 scroll, and a scrolled buffer's viewport is exactly N
    /// rendered lines plus the scroll-to-bottom anchor — no sliver of the line
    /// above (the old cap was 4 lines + 8pt, which showed about 4.5).
    func testScrollCapHoldsExactlyTheChosenNumberOfLines() {
        for size in [
            OverlayLayoutMetrics.minimumBodyFontSize,
            OverlayLayoutMetrics.defaultBodyFontSize,
            OverlayLayoutMetrics.maximumBodyFontSize,
        ] {
            for lines in OverlayLayoutMetrics.minimumVisibleLines
                ... OverlayLayoutMetrics.maximumVisibleLines
            {
                let metrics = OverlayLayoutMetrics(bodyFontSize: size, visibleLines: lines)
                let fits = Array(repeating: "dictated line", count: lines)
                    .joined(separator: "\n")
                let overflows = fits + "\none more"
                let context = "font size \(size), \(lines) lines"

                XCTAssertLessThanOrEqual(
                    metrics.unclampedBodyTextHeight(for: fits),
                    metrics.maxScrollableBodyHeight, "\(context): N lines scroll")
                XCTAssertGreaterThan(
                    metrics.unclampedBodyTextHeight(for: overflows),
                    metrics.maxScrollableBodyHeight, "\(context): N+1 lines don't scroll")
                XCTAssertEqual(
                    metrics.maxScrollableBodyHeight,
                    swiftUIRenderedHeight(
                        fits, fontSize: metrics.bodyFontSize, width: metrics.textMeasurementWidth)
                        + OverlayBodyScrollContent.bottomAnchorHeight,
                    accuracy: 1, "\(context): viewport isn't N whole lines")
            }
        }
    }

    // The header's pills ("Polished", the Claude join badge) used a hardcoded
    // 10pt while `headerHeight` scaled with the body-size setting — so the pill
    // overflowed the header it sits in at the smallest size and shrank to a
    // speck at the largest. Every font here scales from the one setting; these
    // are not exceptions.
    func testBadgeFontScalesWithTheBodyFontSetting() {
        let smallest = OverlayLayoutMetrics(bodyFontSize: OverlayLayoutMetrics.minimumBodyFontSize)
        let base = OverlayLayoutMetrics(bodyFontSize: Double(OverlayLayoutMetrics.baseBodyFontSize))
        let largest = OverlayLayoutMetrics(bodyFontSize: OverlayLayoutMetrics.maximumBodyFontSize)

        XCTAssertEqual(base.badgeFontSize, 10, "10pt at the base 13pt body, as before")
        XCTAssertLessThan(smallest.badgeFontSize, base.badgeFontSize)
        XCTAssertGreaterThan(largest.badgeFontSize, base.badgeFontSize)
        XCTAssertEqual(smallest.badgeFontSize / smallest.titleFontSize,
                       largest.badgeFontSize / largest.titleFontSize,
                       accuracy: 0.0001,
                       "the pill keeps its proportion to the title at every size")
    }

    // The pill must fit the header row it is framed by, at BOTH ends of the
    // setting's range — that containment is what the unscaled font broke.
    func testBadgePillFitsTheHeaderAtEverySize() {
        for size in [
            OverlayLayoutMetrics.minimumBodyFontSize,
            OverlayLayoutMetrics.defaultBodyFontSize,
            OverlayLayoutMetrics.maximumBodyFontSize,
        ] {
            let metrics = OverlayLayoutMetrics(bodyFontSize: size)
            let font = NSFont.systemFont(ofSize: metrics.badgeFontSize)
            let pillHeight = ceil(font.ascender - font.descender + font.leading)
                + metrics.badgeVerticalPadding * 2
            XCTAssertLessThanOrEqual(
                pillHeight, metrics.headerHeight,
                "badge pill overflows the header at body size \(size)"
            )
        }
    }

    func testErrorMessageAddsHeight() {
        let without = baseMetrics.contentHeight(text: "hello", errorMessage: nil)
        let with = baseMetrics.contentHeight(text: "hello", errorMessage: "Insert failed")
        XCTAssertGreaterThan(with, without)
        // Blank errors are not rendered, so they must not add height.
        XCTAssertEqual(baseMetrics.contentHeight(text: "hello", errorMessage: "   "), without)
    }

    // MARK: - Measurement matches what SwiftUI draws (field report 2026-09-16)

    /// Height SwiftUI gives a wrapped `Text` at a fixed width, measured apart
    /// from `OverlayLayoutMetrics`: the same font and wrapping modifiers the
    /// overlay's body and error rows use.
    private func swiftUIRenderedHeight(_ text: String, fontSize: CGFloat, width: CGFloat) -> CGFloat {
        let view = Text(text)
            .font(.system(size: fontSize))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .topLeading)
        return NSHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            .height
    }

    private var fontSizeRange: StrideThrough<Double> {
        stride(
            from: OverlayLayoutMetrics.minimumBodyFontSize,
            through: OverlayLayoutMetrics.maximumBodyFontSize,
            by: 1)
    }

    private let wrappingTexts = [
        // The dictation from the field screenshot: 3 lines, the last clipped at 16pt.
        "And now I'm noticing that the bottom of the thing is cut off. And I'm gonna have to talk even more. Before I can take the screenshot of the real thing being cut off. Appearing like the bottom row is cut off.",
        "hello",
        String(repeating: "the quick brown fox jumps over the lazy dog ", count: 2),
    ]

    /// `NSString.boundingRect` put 3 lines of 16pt text at 54pt while SwiftUI
    /// drew them at 57pt, so the panel came out 3pt short and the last line
    /// lost its descenders. The body row the panel is sized for must hold
    /// what SwiftUI actually renders, at every size of the setting.
    func testBodyHeightHoldsTheSwiftUIRenderedTextAtEveryFontSize() {
        for size in fontSizeRange {
            let metrics = OverlayLayoutMetrics(bodyFontSize: size)
            for text in wrappingTexts {
                let rendered = swiftUIRenderedHeight(
                    text, fontSize: metrics.bodyFontSize, width: metrics.textMeasurementWidth)
                guard rendered <= metrics.maxScrollableBodyHeight else { continue }
                XCTAssertGreaterThanOrEqual(
                    metrics.bodyTextHeight(for: text), rendered,
                    "body row clips its last line at font size \(size): \(text.prefix(24))")
            }
        }
    }

    func testErrorRowHeightHoldsTheSwiftUIRenderedTextAtEveryFontSize() {
        let error = "Couldn't insert the text into the focused app. It is on the clipboard instead, paste it with Command-V."
        for size in fontSizeRange {
            let metrics = OverlayLayoutMetrics(bodyFontSize: size)
            let rendered = swiftUIRenderedHeight(
                error, fontSize: metrics.errorFontSize, width: metrics.textMeasurementWidth)
            let added = metrics.contentHeight(text: "hello", errorMessage: error)
                - metrics.contentHeight(text: "hello", errorMessage: nil)
            XCTAssertGreaterThanOrEqual(
                added, OverlayLayoutMetrics.stackSpacing + rendered,
                "error row clips its last line at font size \(size)")
        }
    }

    // MARK: - Keeping words on their line (#640)

    /// Off, the default, leaves wrapping to SwiftUI at the full width: the
    /// overlay writes no line breaks of its own, so no room is held back.
    func testWordHoldOffBuildsNoLineWrapper() {
        XCTAssertEqual(baseMetrics.wordHold, .off)
        XCTAssertNil(baseMetrics.makeStableLineWrapper())
    }

    /// The chosen length sets how much room a line keeps for the word being
    /// dictated. A line with room for a 6-letter word but not a 14-letter
    /// one keeps the new word at 6 and moves it down at 14.
    func testWordHoldLengthSetsRoomKeptAtLineEnd() throws {
        let metrics = OverlayLayoutMetrics(
            bodyFontSize: OverlayLayoutMetrics.defaultBodyFontSize)
        let lineWidth = metrics.bodyTextWrapWidth - 4  // the wrapper's safety margin
        let room6 = metrics.liveWordReserveWidth(letters: 6)
        let room14 = metrics.liveWordReserveWidth(letters: 14)

        var prefix = "a"
        while lineWidth - metrics.bodyTextWidth(of: prefix + " ") >= room14 {
            prefix += " a"
        }
        let roomLeft = lineWidth - metrics.bodyTextWidth(of: prefix + " ")
        XCTAssertLessThan(roomLeft, room14)
        XCTAssertGreaterThan(roomLeft, room6)

        // "b" is a word still being streamed: the text ends inside it.
        let streamed = prefix + " b"
        var hold6 = try XCTUnwrap(
            OverlayLayoutMetrics(bodyFontSize: OverlayLayoutMetrics.defaultBodyFontSize, wordHold: .upTo6Letters)
                .makeStableLineWrapper())
        var hold14 = try XCTUnwrap(
            OverlayLayoutMetrics(bodyFontSize: OverlayLayoutMetrics.defaultBodyFontSize, wordHold: .upTo14Letters)
                .makeStableLineWrapper())
        XCTAssertEqual(hold6.wrapped(streamed), streamed)
        XCTAssertEqual(hold14.wrapped(streamed), prefix + "\nb")
    }

    // MARK: - Self-wrapped lines must survive the text engine

    /// `OverlayStableLineWrapper` sums word widths measured by AppKit, while
    /// SwiftUI draws the result. If a line it built came out wider than SwiftUI
    /// allows, SwiftUI would wrap it again and move the word this whole
    /// mechanism exists to hold still — so every line it emits must render as
    /// exactly one line, at every supported font size.
    func testSelfWrappedLinesRenderAsOneLineEach() throws {
        let transcript = String(
            repeating:
                "the overlay buffer holds a wrapped transcript of whatever was just dictated ",
            count: 3)

        for fontSize in [
            OverlayLayoutMetrics.minimumBodyFontSize,
            OverlayLayoutMetrics.defaultBodyFontSize,
            OverlayLayoutMetrics.maximumBodyFontSize,
        ] {
            let metrics = OverlayLayoutMetrics(bodyFontSize: fontSize, wordHold: .upTo10Letters)
            var wrapper = try XCTUnwrap(metrics.makeStableLineWrapper())
            let wrapped = wrapper.wrapped(transcript)
            let lineCount = wrapped.split(separator: "\n").count
            XCTAssertGreaterThan(lineCount, 1, "the sample must actually wrap at \(fontSize)pt")

            let placeholder = Array(repeating: "Xg", count: lineCount).joined(separator: "\n")
            XCTAssertEqual(
                metrics.unclampedBodyTextHeight(for: wrapped),
                metrics.unclampedBodyTextHeight(for: placeholder),
                "SwiftUI re-wrapped a line at \(fontSize)pt: \(wrapped)"
            )
        }
    }

    /// Field report 2026-09-24: once the buffer scrolled, lines came out with
    /// their last two words alone on the next line. The body's `ScrollView`
    /// takes a scroller's width off its content while scrolling, so a line
    /// broken for the full width got wrapped again. The same wrapped text must
    /// render one line per line inside the real overlay while it scrolls.
    func testSelfWrappedLinesRenderAsOneLineEachWhileScrolling() throws {
        let transcript = String(
            repeating:
                "censé marcher, ouais, en vrai, l'avantage, c'est que c'est super rapide, quoi ça apparaît vraiment instantanément, ça apparaît douze mots à la fois carrément ",
            count: 3)

        for fontSize in [
            OverlayLayoutMetrics.minimumBodyFontSize,
            OverlayLayoutMetrics.defaultBodyFontSize,
            16,  // the reported screenshot's size
            OverlayLayoutMetrics.maximumBodyFontSize,
        ] {
            let metrics = OverlayLayoutMetrics(bodyFontSize: fontSize, wordHold: .upTo10Letters)
            var wrapper = try XCTUnwrap(metrics.makeStableLineWrapper())
            let wrapped = wrapper.wrapped(transcript)
            let lineCount = wrapped.split(separator: "\n").count
            XCTAssertGreaterThan(
                lineCount, metrics.visibleLines, "the sample must scroll at \(fontSize)pt")

            let placeholder = Array(repeating: "Xg", count: lineCount).joined(separator: "\n")
            XCTAssertEqual(
                scrollDocumentHeight(rendering: wrapped, metrics: metrics),
                scrollDocumentHeight(rendering: placeholder, metrics: metrics),
                "SwiftUI re-wrapped a line in the scrolling overlay at \(fontSize)pt: \(wrapped)"
            )
        }
    }

    /// Height of the body's scroll document when the whole overlay renders
    /// `text` at the panel width the controller gives it.
    private func scrollDocumentHeight(rendering text: String, metrics: OverlayLayoutMetrics) -> CGFloat {
        let hosting = NSHostingView(
            rootView: DictationOverlayView(
                phase: .buffering, text: text, errorMessage: nil, secureInputActive: false,
                metrics: metrics))
        hosting.frame = NSRect(x: 0, y: 0, width: metrics.panelWidth, height: metrics.maximumPanelHeight)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // The scroller takes its width from the content on the next run-loop
        // turn, not in the first layout pass. `.distantPast` handles what is
        // already pending and returns; nothing waits on the clock.
        RunLoop.main.run(mode: .default, before: .distantPast)
        hosting.layoutSubtreeIfNeeded()
        guard let scrollView = Self.firstScrollView(in: hosting),
            let document = scrollView.documentView
        else {
            XCTFail("the overlay body has no NSScrollView")
            return 0
        }
        return document.frame.height
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - Scroll-to-bottom reaches the real bottom (field report 2026-09-18)

@MainActor
final class OverlayBodyScrollContentTests: XCTestCase {
    /// Auto-scroll puts the bottom anchor at the viewport's bottom edge. A
    /// 12pt padding under the anchor left that much scroll range unreached:
    /// the scroller stopped short of the bottom, and scrolling by hand
    /// revealed the padding and lifted the last line. The document must end
    /// where the anchor ends.
    func testScrollDocumentEndsAtTheBottomAnchor() {
        let text = String(repeating: "scrolling buffer text keeps growing ", count: 60)
        for size in [
            OverlayLayoutMetrics.minimumBodyFontSize,
            OverlayLayoutMetrics.defaultBodyFontSize,
            OverlayLayoutMetrics.maximumBodyFontSize,
        ] {
            let metrics = OverlayLayoutMetrics(bodyFontSize: size)
            let width = metrics.textMeasurementWidth
            let proposal = CGSize(width: width, height: .greatestFiniteMagnitude)
            let textHeight = NSHostingController(
                rootView: Text(text)
                    .font(.system(size: metrics.bodyFontSize))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width, alignment: .topLeading)
            ).sizeThatFits(in: proposal).height
            let documentHeight = NSHostingController(
                rootView: OverlayBodyScrollContent(text: text, metrics: metrics)
                    .frame(width: width)
            ).sizeThatFits(in: proposal).height

            XCTAssertEqual(
                documentHeight, textHeight + OverlayBodyScrollContent.bottomAnchorHeight,
                accuracy: 0.5,
                "scroll range extends past the bottom anchor at font size \(size)")
        }
    }
}
