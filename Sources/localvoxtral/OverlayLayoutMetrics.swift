import AppKit
import SwiftUI

/// Layout values shared between `DictationOverlayView` (SwiftUI content) and
/// `DictationOverlayController` (AppKit panel sizing). The controller measures
/// text with `OverlayTextMeasurer` to size the panel, so every font size and
/// width here MUST match what the view renders — deriving both sides from this
/// one struct is what keeps them in lockstep (a mismatch clips the last line).
///
/// The whole overlay scales from a single user setting: the body font size
/// (`SettingsStore.overlayBufferFontSize`). All other fonts and the panel
/// width scale proportionally so the buffer keeps its shape at any size.
struct OverlayLayoutMetrics: Equatable {
    /// The body font size the fixed-size overlay historically used; scale 1.0.
    static let baseBodyFontSize: CGFloat = 13
    static let defaultBodyFontSize: Double = 14
    static let minimumBodyFontSize: Double = 10
    static let maximumBodyFontSize: Double = 24

    let bodyFontSize: CGFloat

    init(bodyFontSize: Double) {
        self.bodyFontSize = CGFloat(Self.clampedBodyFontSize(bodyFontSize))
    }

    static func clampedBodyFontSize(_ size: Double) -> Double {
        min(max(size, minimumBodyFontSize), maximumBodyFontSize)
    }

    var scale: CGFloat { bodyFontSize / Self.baseBodyFontSize }

    // Fonts (11pt title/error, 10pt badge at the base 13pt body).
    var titleFontSize: CGFloat { 11 * scale }
    var errorFontSize: CGFloat { 11 * scale }
    /// The header's trailing pills ("Polished", the Claude join badge). Scaled
    /// like every other font here: a fixed 10pt overflowed `headerHeight` at
    /// the smallest body size (which is `ceil(16 * scale)`, so it shrinks while
    /// an unscaled pill did not) and shrank to a speck at the largest.
    var badgeFontSize: CGFloat { 10 * scale }
    /// Pill chrome, scaled with the pill's own text — unlike `contentPadding`,
    /// which is deliberately fixed because it frames the panel rather than a
    /// piece of scaling text.
    var badgeHorizontalPadding: CGFloat { 6 * scale }
    var badgeVerticalPadding: CGFloat { 1 * scale }

    // Panel geometry (400/420/540 at scale 1.0).
    var panelMinWidth: CGFloat { 400 * scale }
    var panelWidth: CGFloat { 420 * scale }
    var panelMaxWidth: CGFloat { 540 * scale }
    var maximumPanelHeight: CGFloat { 420 * scale }
    var headerHeight: CGFloat { ceil(16 * scale) }

    // Fixed chrome — intentionally unscaled so the panel keeps its visual
    // weight; only referenced here because the height math needs them.
    static let contentPadding: CGFloat = 10
    static let stackSpacing: CGFloat = 8
    /// Slack added to the 4-line scroll cap. Same value as `stackSpacing`
    /// today, but a distinct knob: tuning the VStack gap must not silently
    /// change when scrolling kicks in.
    static let bodyScrollSlack: CGFloat = 8

    /// Width available to text: panel width minus horizontal padding.
    var textMeasurementWidth: CGFloat { panelWidth - Self.contentPadding * 2 }

    var bodyLineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: bodyFontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// Maximum height the body text area can grow to before scrolling kicks
    /// in: ~4 lines of body text plus some line spacing.
    var maxScrollableBodyHeight: CGFloat {
        bodyLineHeight * 4 + Self.bodyScrollSlack
    }

    /// Height of the body text as rendered at `textMeasurementWidth`, floored
    /// to one line and capped at `maxScrollableBodyHeight`.
    @MainActor
    func bodyTextHeight(for text: String) -> CGFloat {
        min(unclampedBodyTextHeight(for: text), maxScrollableBodyHeight)
    }

    /// Uncapped variant — the view compares this against
    /// `maxScrollableBodyHeight` to decide whether scrolling is needed.
    @MainActor
    func unclampedBodyTextHeight(for text: String) -> CGFloat {
        guard !text.isEmpty else { return bodyLineHeight }
        return max(
            OverlayTextMeasurer.height(of: text, fontSize: bodyFontSize, width: textMeasurementWidth),
            bodyLineHeight)
    }

    /// Full panel content height: header + spacing + body + optional error +
    /// padding. Mirrors `DictationOverlayView.body` exactly.
    @MainActor
    func contentHeight(text: String, errorMessage: String?) -> CGFloat {
        let displayText = text.trimmed.isEmpty ? "" : text

        var total = Self.contentPadding * 2
            + headerHeight
            + Self.stackSpacing
            + bodyTextHeight(for: displayText)

        if let errorMessage, !errorMessage.trimmed.isEmpty {
            total += Self.stackSpacing
                + OverlayTextMeasurer.height(
                    of: errorMessage, fontSize: errorFontSize, width: textMeasurementWidth)
        }

        return total
    }
}

/// Measures wrapped overlay text with SwiftUI, the engine that draws it.
///
/// `NSString.boundingRect` disagrees with SwiftUI's line heights at many font
/// sizes (3 lines of 16pt: 54pt measured, 57pt drawn), and the panel sized
/// from it clipped the last line's descenders. The hosting view's own
/// `fittingSize` / `sizeThatFits` is no substitute either: both minimise the
/// overall size and can widen the view to avoid a wrap. A lone `Text` at a
/// fixed width has no such freedom, so its height is what the row renders.
@MainActor
private enum OverlayTextMeasurer {
    private static let host = NSHostingController(rootView: AnyView(EmptyView()))

    static func height(of text: String, fontSize: CGFloat, width: CGFloat) -> CGFloat {
        // Same font and wrapping modifiers as the body and error rows in
        // `DictationOverlayView`.
        host.rootView = AnyView(
            Text(text)
                .font(.system(size: fontSize))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .topLeading)
        )
        return ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}

/// Locks the overlay's metrics for the duration of one overlay session.
///
/// `DictationOverlayController` locks the panel's X origin and top edge on the
/// first render of a session (so the panel grows downward from a stable
/// position) — that lock assumes the panel WIDTH is constant for the session.
/// A font-size change mid-dictation would violate it: the next render would
/// keep the stale locked X while the panel widens, pushing the right edge
/// off-screen. So the metrics are locked alongside: the first render of a
/// session snapshots the font size, and a settings change applies to the next
/// session (`unlock()` on hide).
struct OverlaySessionMetricsLock {
    private var locked: OverlayLayoutMetrics?

    /// The session's metrics, locking `currentFontSize` on first call.
    mutating func metrics(currentFontSize: Double) -> OverlayLayoutMetrics {
        if let locked { return locked }
        let metrics = OverlayLayoutMetrics(bodyFontSize: currentFontSize)
        locked = metrics
        return metrics
    }

    /// Ends the session: the next `metrics(currentFontSize:)` re-reads the size.
    mutating func unlock() {
        locked = nil
    }
}
