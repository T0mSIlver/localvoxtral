import AppKit

/// Layout values shared between `DictationOverlayView` (SwiftUI content) and
/// `DictationOverlayController` (AppKit panel sizing). The controller measures
/// text with `NSString.boundingRect` to size the panel, so every font size and
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

    // Fonts (11pt title/error at the base 13pt body).
    var titleFontSize: CGFloat { 11 * scale }
    var errorFontSize: CGFloat { 11 * scale }

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
    func bodyTextHeight(for text: String) -> CGFloat {
        min(unclampedBodyTextHeight(for: text), maxScrollableBodyHeight)
    }

    /// Uncapped variant — the view compares this against
    /// `maxScrollableBodyHeight` to decide whether scrolling is needed.
    func unclampedBodyTextHeight(for text: String) -> CGFloat {
        guard !text.isEmpty else { return bodyLineHeight }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: textMeasurementWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: bodyFontSize)]
        )
        return max(ceil(rect.height), bodyLineHeight)
    }

    /// Full panel content height: header + spacing + body + optional error +
    /// padding. Mirrors `DictationOverlayView.body` exactly.
    ///
    /// Measures text with `NSString.boundingRect` rather than the hosting
    /// view's `fittingSize` / `sizeThatFits`, which both try to minimise the
    /// overall size and can widen the view to avoid a line wrap, returning a
    /// height that is one line too short.
    func contentHeight(text: String, errorMessage: String?) -> CGFloat {
        let displayText = text.trimmed.isEmpty ? "" : text

        var total = Self.contentPadding * 2
            + headerHeight
            + Self.stackSpacing
            + bodyTextHeight(for: displayText)

        if let errorMessage, !errorMessage.trimmed.isEmpty {
            let errorFont = NSFont.systemFont(ofSize: errorFontSize)
            let errorRect = (errorMessage as NSString).boundingRect(
                with: CGSize(width: textMeasurementWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: errorFont]
            )
            total += Self.stackSpacing + ceil(errorRect.height)
        }

        return total
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
