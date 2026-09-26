import Foundation

/// A repo's `.github/dictation.md`: terms the team, or a coding agent working
/// in the repo, wrote down so dictation spells them right. VS Code's built-in
/// dictation reads the same file, so one list serves both.
///
/// The file is prose for a cleanup model, so only its term-shaped parts are
/// taken: inline code spans anywhere, and the head of a plain list item
/// ("- Voxtral — the speech model" yields "Voxtral"). Fenced blocks, headings
/// and paragraph text are ignored, and none of the file's text reaches the
/// polish prompt: the terms join the repo vocabulary and are grounded only
/// where the transcript matches them, exactly like tracked file names.
package enum DictationTermsFile {
    package static let relativePath = ".github/dictation.md"
    /// A larger file is not a term list; it is skipped, never truncated.
    package static let maximumBytes = 64 * 1024
    package static let maximumTerms = 200
    static let maximumTermLength = 64
    static let maximumWords = 4

    /// The file's terms, in order of first appearance, or `[]` when the file
    /// is missing, not a regular file (a symlink is refused), over
    /// `maximumBytes`, or not UTF-8.
    package static func read(root: String, fileManager: FileManager = .default) -> [String] {
        let path = fileURL(root: root).path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumBytes,
              let data = fileManager.contents(atPath: path),
              data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return terms(fromMarkdown: text)
    }

    /// The file's modification date, or nil when it does not exist. The
    /// vocabulary cache compares it so a term an agent just wrote is picked up
    /// by the next dictation instead of after the cache's TTL.
    package static func modificationDate(root: String, fileManager: FileManager = .default) -> Date? {
        (try? fileManager.attributesOfItem(atPath: fileURL(root: root).path))?[.modificationDate] as? Date
    }

    package static func terms(fromMarkdown markdown: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ candidate: String) {
            guard result.count < maximumTerms,
                  let term = accepted(candidate),
                  seen.insert(term).inserted
            else { return }
            result.append(term)
        }

        var fenceMarker: String?
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker {
                if line.hasPrefix(marker) { fenceMarker = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fenceMarker = String(line.prefix(3))
                continue
            }
            if line.hasPrefix("#") { continue }

            let spans = codeSpans(in: line)
            spans.forEach(add)
            if spans.isEmpty, let item = listItemText(line) {
                add(itemHead(item))
            }
        }
        return result
    }

    static func fileURL(root: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(relativePath)
    }

    private static func codeSpans(in line: String) -> [String] {
        var spans: [String] = []
        var current: String?
        for character in line {
            if character == "`" {
                if let span = current { spans.append(span) }
                current = current == nil ? "" : nil
            } else if current != nil {
                current?.append(character)
            }
        }
        return spans
    }

    /// The text after a list marker (`-`, `*`, `+`, `1.`, `1)`), or nil.
    private static func listItemText(_ line: String) -> String? {
        if let first = line.first, "-*+".contains(first) {
            let rest = line.dropFirst()
            guard rest.first == " " else { return nil }
            return String(rest.dropFirst())
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")",
              rest.dropFirst().first == " "
        else { return nil }
        return String(rest.dropFirst(2))
    }

    /// The term an item names, before any explanation that follows it.
    private static func itemHead(_ item: String) -> String {
        var head = item
        for separator in [" — ", " – ", " - ", ": ", " = ", " -> ", " → ", " ("] {
            if let range = head.range(of: separator) {
                head = String(head[..<range.lowerBound])
            }
        }
        for emphasis in ["**", "__"] where head.hasPrefix(emphasis) && head.hasSuffix(emphasis)
            && head.count > emphasis.count * 2
        {
            head = String(head.dropFirst(emphasis.count).dropLast(emphasis.count))
        }
        return head.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
    }

    /// The term-shape filter: 2 to 64 characters with a letter, at most four
    /// words, no Markdown link or URL. `ProjectTermProposal` applies it to an
    /// agent's answer too.
    package static func accepted(_ candidate: String) -> String? {
        let term = candidate.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2, term.count <= maximumTermLength,
              term.contains(where: \.isLetter),
              term.split(separator: " ").count <= maximumWords,
              !term.contains("]("), !term.contains("://")
        else { return nil }
        return term
    }
}
