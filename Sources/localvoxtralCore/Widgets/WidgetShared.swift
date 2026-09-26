import Foundation

/// What the app and the widget extension agree on (#630).
package enum WidgetShared {
    /// The snapshot, under the user's real home. The extension's sandbox
    /// grants read access to this directory alone
    /// (`scripts/packaging/widgets.entitlements`): an App Group needs a Team
    /// ID, which these builds do not have.
    package static let directoryInHome = "Library/Application Support/localvoxtral/widgets"
    package static let fileName = "snapshot.json"

    package static func fileURL(home: URL) -> URL {
        home.appendingPathComponent(directoryInHome, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The Darwin notification "Turn off polish" posts. The widget's intent
    /// runs in the extension, and this is how it reaches the running app. It
    /// carries no data, and any process can post it, so it only ever means
    /// "turn polish off".
    package static let turnOffPolishNotification = "com.localvoxtral.widget.turn-off-polish"

    package enum Kind: String, CaseIterable, Sendable {
        case engines = "com.localvoxtral.widget.engines"
        case dictation = "com.localvoxtral.widget.dictation"
        case vocabulary = "com.localvoxtral.widget.vocabulary"
        case lastDictation = "com.localvoxtral.widget.last-dictation"
    }
}

/// Model names as the widget rows show them, from a catalog display name or
/// a custom repo id.
package enum WidgetModelName {
    /// "Voxtral Mini 4B Realtime (4-bit, quantized head)" becomes
    /// "Voxtral Mini 4B Realtime"; "org/Custom-Model" becomes "Custom-Model".
    package static func full(_ name: String) -> String {
        var name = name
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if let paren = name.range(of: " (") {
            name = String(name[..<paren.lowerBound])
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// The family and the parameter count: "Voxtral 4B", "Nemotron 0.6B",
    /// "Qwen3.5 4B". A name without a size stays whole.
    package static func short(_ name: String) -> String {
        let words = full(name).split(separator: " ")
        guard let family = words.first,
              let size = words.dropFirst().first(where: isParameterCount)
        else { return full(name) }
        return "\(family) \(size)"
    }

    private static func isParameterCount(_ word: Substring) -> Bool {
        guard word.count >= 2, word.last == "B" else { return false }
        return Double(word.dropLast()) != nil
    }
}
