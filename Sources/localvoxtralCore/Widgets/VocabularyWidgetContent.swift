import Foundation

/// What the Vocabulary widget draws (#630).
package struct VocabularyWidgetContent: Equatable, Sendable {
    package struct Trend: Equatable, Sendable {
        /// The latest measured week: "93%".
        package var share: String
        package var shareCaption: String
        /// The last `weeks` weeks, oldest first; nil where a week had too few
        /// dictations to say.
        package var weeklyShares: [Double?]
        package var firstShare: String
        /// "412 terms · +18 this week".
        package var countLine: String
        /// "412 total".
        package var total: String
        package var newTerms: [String]
        /// "+12 more", nil when every new term shows.
        package var moreTerms: String?

        package init(
            share: String,
            shareCaption: String,
            weeklyShares: [Double?],
            firstShare: String,
            countLine: String,
            total: String,
            newTerms: [String],
            moreTerms: String?
        ) {
            self.share = share
            self.shareCaption = shareCaption
            self.weeklyShares = weeklyShares
            self.firstShare = firstShare
            self.countLine = countLine
            self.total = total
            self.newTerms = newTerms
            self.moreTerms = moreTerms
        }
    }

    package enum Layout: Equatable, Sendable {
        /// No week has enough dictations to draw a trend yet.
        case empty(title: String, detail: String)
        case trend(Trend)
    }

    package var layout: Layout

    package static let weeks = 8
    package static let maxNewTerms = 6

    package init(layout: Layout) {
        self.layout = layout
    }

    package init(_ vocabulary: WidgetSnapshot.Vocabulary, locale: Locale = .current) {
        let shares = Array(vocabulary.weeklyShares.suffix(Self.weeks))
        let measured = shares.compactMap { $0 }
        guard let latest = measured.last, let first = measured.first else {
            layout = vocabulary.termCount == 0
                ? .empty(title: "Nothing learned yet", detail: "Terms show up here as the app learns the words you use.")
                : .empty(
                    title: vocabulary.termCount == 1 ? "1 term learned" : "\(WidgetFormat.count(vocabulary.termCount, locale: locale)) terms learned",
                    detail: "The trend shows once a week has five dictations with your terms."
                )
            return
        }
        let total = WidgetFormat.count(vocabulary.termCount, locale: locale)
        let learned = vocabulary.termsLearnedThisWeek.count
        let shown = Array(vocabulary.termsLearnedThisWeek.prefix(Self.maxNewTerms))
        layout = .trend(Trend(
            share: WidgetFormat.percent(latest),
            shareCaption: shares.last.flatMap { $0 } != nil
                ? "learned terms spelled right this week"
                : "learned terms spelled right in the last measured week",
            weeklyShares: shares,
            firstShare: WidgetFormat.percent(first),
            countLine: "\(total) terms · +\(WidgetFormat.count(learned, locale: locale)) this week",
            total: "\(total) total",
            newTerms: shown,
            moreTerms: learned > shown.count ? "+\(WidgetFormat.count(learned - shown.count, locale: locale)) more" : nil
        ))
    }
}
