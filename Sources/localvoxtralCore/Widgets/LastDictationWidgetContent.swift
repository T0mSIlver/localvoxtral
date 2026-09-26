import Foundation

/// What the Last dictation widget draws (#630).
package struct LastDictationWidgetContent: Equatable, Sendable {
    package struct Dictation: Equatable, Sendable {
        /// Marked privacy-sensitive in the view: macOS hides it on the lock
        /// screen.
        package var text: String
        /// The app it went to, or "Last dictation" when unknown.
        package var title: String
        /// The view renders the age from this, so it stays current.
        package var finishedAt: Date
        /// "Polished" when a model polished it.
        package var badge: String?
        /// "19 words · polish 0.8 s".
        package var footer: String

        package init(text: String, title: String, finishedAt: Date, badge: String?, footer: String) {
            self.text = text
            self.title = title
            self.finishedAt = finishedAt
            self.badge = badge
            self.footer = footer
        }
    }

    package enum Layout: Equatable, Sendable {
        case message(title: String, detail: String)
        case dictation(Dictation)
    }

    package var layout: Layout
    /// Copy only works on text the widget has.
    package var showsCopy: Bool {
        if case .dictation = layout { return true }
        return false
    }

    package init(layout: Layout) {
        self.layout = layout
    }

    package init(_ snapshot: WidgetSnapshot, locale: Locale = .current) {
        guard snapshot.historyKept else {
            layout = .message(title: "History is off", detail: "Keep history in localvoxtral to see your last dictation here.")
            return
        }
        guard let last = snapshot.lastDictation else {
            layout = .message(title: "No dictation yet", detail: "Your last dictation shows here, with a button to copy it.")
            return
        }
        let words = last.words
        var footer = words == 1 ? "1 word" : "\(WidgetFormat.count(words, locale: locale)) words"
        if last.polishRan, let seconds = last.polishSeconds {
            footer += " · polish \(seconds.formatted(.number.precision(.fractionLength(1)).locale(locale))) s"
        }
        layout = .dictation(Dictation(
            text: last.text,
            title: last.appName ?? "Last dictation",
            finishedAt: last.finishedAt,
            badge: last.polishRan ? "Polished" : nil,
            footer: footer
        ))
    }
}
