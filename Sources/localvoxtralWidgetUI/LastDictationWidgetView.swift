import SwiftUI
import WidgetKit
import localvoxtralCore

/// The Last dictation widget: the final text and where it went, with a Copy
/// button for text that landed in the wrong window (#630). The text is
/// privacy-sensitive, so macOS redacts it on the lock screen.
package struct LastDictationWidgetView<Copy: View>: View {
    let content: LastDictationWidgetContent
    /// The timeline entry's date, which the age is counted against.
    let now: Date
    let copy: Copy

    package init(content: LastDictationWidgetContent, now: Date, @ViewBuilder copy: () -> Copy) {
        self.content = content
        self.now = now
        self.copy = copy()
    }

    /// "2 min ago", "3 hr ago", against the entry's date rather than the
    /// moment WidgetKit happens to render.
    static func age(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    package var body: some View {
        switch content.layout {
        case let .message(title, detail):
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader(symbol: "text.bubble", title: "Last dictation")
                Spacer(minLength: 6)
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).padding(.top, 3)
                Spacer(minLength: 0)
            }
        case let .dictation(dictation):
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                        .widgetAccentable()
                    Text(dictation.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("· \(Self.age(dictation.finishedAt, now: now))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let badge = dictation.badge {
                        HStack(spacing: 3) {
                            EngineMark(role: .polish, size: 8)
                            Text(badge)
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                    }
                }
                Text(dictation.text)
                    .font(.system(size: 13))
                    .lineLimit(4)
                    .privacySensitive()
                Spacer(minLength: 0)
                HStack {
                    Text(dictation.footer)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    copy
                }
            }
        }
    }
}
