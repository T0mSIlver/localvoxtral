import Foundation

/// Markdown code fences, as an editor's markdown shortcut sees them.
package enum MarkdownCodeFence {
    /// True when any line of `text` opens with three backticks or three
    /// tildes, after optional spaces or tabs. Typed key by key at the start of
    /// a line, that is what turns Claude Desktop's prompt into a code block
    /// (#695). Backticks later in a line do not count.
    package static func containsFenceLine(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let rest = line.drop { $0 == " " || $0 == "\t" }
            return rest.hasPrefix("```") || rest.hasPrefix("~~~")
        }
    }
}
