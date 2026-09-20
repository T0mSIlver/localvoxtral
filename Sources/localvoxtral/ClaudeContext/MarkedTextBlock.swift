import Foundation

/// A block of lines this app owns inside a text file the user also edits,
/// delimited by a begin and an end marker line.
///
/// Written for the shell rc block (`ClaudeShellRCSetup`) and shared with
/// Vibe's `hooks.toml` (`VibeHooksInstallService`): both are files where a
/// second copy of our block is a behavior change and a lost user line is
/// unforgivable, so both get the same rules.
public struct MarkedTextBlock: Sendable, Equatable {
    public var markerBegin: String
    public var markerEnd: String

    public init(markerBegin: String, markerEnd: String) {
        self.markerBegin = markerBegin
        self.markerEnd = markerEnd
    }

    /// Is our block already in this text?
    public func containsBlock(_ existing: String) -> Bool {
        if case .present = locateBlock(in: splitLines(existing)) { return true }
        return false
    }

    /// Is our block in this text exactly once, and exactly this snippet?
    ///
    /// Line terminators aside: `apply` writes the file's own, so a CRLF file
    /// holding this build's block is current. Two copies are not current even
    /// when both match, because `apply` would still collapse them.
    public func containsCurrentBlock(_ existing: String, snippet: String) -> Bool {
        let lines = splitLines(existing)
        guard case .present(let ranges) = locateBlock(in: lines), ranges.count == 1 else {
            return false
        }
        return Array(lines[ranges[0]]) == splitLines(snippet)
    }

    /// Does this text carry an unpaired begin marker?
    public func hasDamagedBlock(_ existing: String) -> Bool {
        locateBlock(in: splitLines(existing)) == .damaged
    }

    /// Lines, plus the terminator the file actually uses.
    ///
    /// A CRLF file spliced with LF comes back mixed (review finding m3), and
    /// "mostly CRLF with one LF region" is a file we damaged in a way the user
    /// will notice in their editor. The whole file is never normalized either —
    /// that would be the same crime in the other direction.
    func lineTerminator(of text: String) -> String {
        text.contains("\r\n") ? "\r\n" : "\n"
    }

    /// Split on LF and strip a trailing CR, so a CRLF file's lines compare and
    /// rejoin like any other.
    func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }

    /// Insert or REPLACE the block, leaving everything else byte for byte.
    ///
    /// Idempotent by delimiter, like the ssh-config writer and for a sharper
    /// reason: an rc file with two copies of this block is not merely untidy,
    /// it would run `tty` twice per shell start forever.
    /// - Returns: nil when the file's markers do not pair — the caller must
    ///   refuse rather than write.
    public func apply(to existing: String, snippet: String) -> String? {
        let terminator = lineTerminator(of: existing)
        let lines = splitLines(existing)
        switch locateBlock(in: lines) {
        case .damaged:
            return nil
        case .absent:
            var prefix = existing
            if !prefix.isEmpty, !prefix.hasSuffix(terminator) { prefix += terminator }
            if !prefix.isEmpty, !prefix.hasSuffix(terminator + terminator) {
                prefix += terminator
            }
            let body = snippet.components(separatedBy: "\n").joined(separator: terminator)
            return prefix + body + terminator
        case .present(let ranges):
            // Replace the FIRST block in place and drop the rest, so a file
            // that was hand-duplicated converges to one.
            var result: [String] = []
            var cursor = 0
            for (offset, range) in ranges.enumerated() {
                result.append(contentsOf: lines[cursor..<range.lowerBound])
                if offset == 0 {
                    result.append(contentsOf: snippet.components(separatedBy: "\n"))
                }
                cursor = range.upperBound + 1
            }
            result.append(contentsOf: lines[cursor...])
            return result.joined(separator: terminator)
        }
    }

    /// Remove the block, leaving everything else untouched.
    /// - Returns: nil for the same unpaired-marker case as `apply`.
    public func remove(from existing: String) -> String? {
        let terminator = lineTerminator(of: existing)
        let lines = splitLines(existing)
        switch locateBlock(in: lines) {
        case .damaged:
            return nil
        case .absent:
            return existing
        case .present(let ranges):
            var result: [String] = []
            var cursor = 0
            for range in ranges {
                var start = range.lowerBound
                // Take back the blank line `apply` inserted as a separator, so
                // apply-then-remove is byte-identical to the original rather
                // than leaving a growing gap behind (review finding m1). Only
                // ONE, and only when it is a blank line we would have added.
                if start > cursor, lines[start - 1].isEmpty { start -= 1 }
                result.append(contentsOf: lines[cursor..<start])
                cursor = range.upperBound + 1
            }
            result.append(contentsOf: lines[cursor...])
            return result.joined(separator: terminator)
        }
    }

    /// Every complete block, in order; or `.damaged` when the markers do not
    /// nest and pair the way we wrote them.
    ///
    /// `.damaged` is not fussiness, and it took two review rounds to get its
    /// definition right. A begin with NO end lets an append leave two begins
    /// and one end, and the next apply then replaces everything between the
    /// first begin and that single end. A begin followed by ANOTHER begin
    /// before any end is the same wound already open: taking the first begin
    /// and the first end after it spans the user's lines in between and
    /// deletes them (review finding M1). Both are hand-edit shapes — delete an
    /// end marker, re-paste the README block to "fix" it — and refusing to
    /// touch such a file is the only answer that cannot lose content.
    ///
    /// SEVERAL complete pairs are not damage but they are not one block
    /// either: `apply` replaces the first and would leave the rest forever,
    /// which is the duplicate the idempotency claim exists to prevent. All of
    /// them are replaced (review finding m2).
    func locateBlock(in lines: [String]) -> Location {
        var ranges: [ClosedRange<Int>] = []
        var openedAt: Int?
        for (index, line) in lines.enumerated() {
            if isMarker(line, markerBegin) {
                guard openedAt == nil else { return .damaged }
                openedAt = index
                continue
            }
            if isMarker(line, markerEnd) {
                guard let begin = openedAt else {
                    // An end with no begin: also not a shape we wrote.
                    return .damaged
                }
                ranges.append(begin...index)
                openedAt = nil
            }
        }
        if openedAt != nil { return .damaged }
        return ranges.isEmpty ? .absent : .present(ranges)
    }

    public enum Location: Sendable, Equatable {
        case absent
        /// One or more complete blocks, in file order.
        case present([ClosedRange<Int>])
        /// Markers that do not pair — a hand-edit we will not write past.
        case damaged
    }

    /// Trimmed of whitespace AND newlines, so an indented copy counts and a
    /// CRLF file's `…(begin)\r` is still our marker. `.whitespaces` alone is
    /// space and tab only, and a dotfile synced from a Windows-touched repo
    /// would have looked marker-free — which means appending a duplicate.
    private func isMarker(_ line: String, _ marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == marker
    }
}
