import Foundation

/// Number and duration text shared by the widgets and the app's panes.
package enum WidgetFormat {
    /// Two decimals hide a month of light use; a cent's fraction is still
    /// money on the bill when all you do is dictate.
    package static func cost(_ eur: Double) -> String {
        if eur > 0, eur < 0.01 { return "< €0.01" }
        return String(format: "€%.2f", eur)
    }

    /// "45 s", "18 min", "2 h", "2 h 17 min".
    package static func duration(_ seconds: Double) -> String {
        let minutes = seconds / 60
        if minutes < 1 { return "\(Int(seconds.rounded())) s" }
        if minutes < 60 { return "\(Int(minutes.rounded())) min" }
        let hours = Int(minutes) / 60
        let rest = Int(minutes.rounded()) - hours * 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Memory in binary gigabytes, as Activity Monitor counts it: "4.2 GB".
    /// A Mac's RAM comes out whole ("32 GB").
    package static func memory(_ bytes: UInt64, locale: Locale) -> String {
        "\(memoryNumber(bytes, locale: locale)) GB"
    }

    /// The number alone, for "7.1 of 32 GB memory".
    package static func memoryNumber(_ bytes: UInt64, locale: Locale) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        let whole = gigabytes.rounded()
        if abs(gigabytes - whole) < 0.05 {
            return Int(whole).formatted(.number.locale(locale))
        }
        return gigabytes.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// Download sizes in decimal gigabytes, as the model pickers show them.
    package static func downloadNumber(_ bytes: Int64, locale: Locale) -> String {
        (Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    package static func count(_ value: Int, locale: Locale) -> String {
        value.formatted(.number.locale(locale))
    }

    package static func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }
}

/// What typing the words would have cost, the Insights pane's measure.
package enum TypingPace {
    /// The usual figure for an average typist.
    package static let wordsPerMinute = 40.0

    /// Never negative: a slow day is not a debt.
    package static func secondsSaved(words: Int, dictatingSeconds: Double) -> Double {
        max(0, Double(words) / wordsPerMinute * 60 - dictatingSeconds)
    }

    /// Nil under ten seconds of dictating, where the ratio is noise.
    package static func wordsPerMinute(words: Int, dictatingSeconds: Double) -> Double? {
        guard dictatingSeconds >= 10 else { return nil }
        return Double(words) / (dictatingSeconds / 60)
    }
}
