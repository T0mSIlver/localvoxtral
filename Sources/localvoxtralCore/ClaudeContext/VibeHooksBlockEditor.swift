import Foundation

/// The text rules for keeping one marked block of `[[hooks]]` tables in a Vibe
/// `hooks.toml`, shared by the two blocks this app writes: the local one on
/// this Mac (`VibeHooksInstallService`) and the remote one on an enrolled ssh
/// host (`ClaudeRemoteEnrollmentService.setUpRemoteVibeHooks`). Both blocks can
/// sit in one file, so each editor knows only its own markers and hook names.
///
/// Pure functions over text: the caller does the IO, locally or over ssh.
public struct VibeHooksBlockEditor: Sendable, Equatable {
    public var block: MarkedTextBlock
    /// The exact hook names the block declares. Vibe deduplicates by name.
    public var hookNames: Set<String>

    public init(block: MarkedTextBlock, hookNames: Set<String>) {
        self.block = block
        self.hookNames = hookNames
    }

    public static let local = VibeHooksBlockEditor(
        block: MarkedTextBlock(markerBegin: "# >>> localvoxtral >>>", markerEnd: "# <<< localvoxtral <<<"),
        hookNames: ["localvoxtral-files", "localvoxtral-turn"]
    )

    public static let remote = VibeHooksBlockEditor(
        block: MarkedTextBlock(
            markerBegin: "# >>> localvoxtral remote >>>", markerEnd: "# <<< localvoxtral remote <<<"
        ),
        hookNames: ["localvoxtral-remote-files", "localvoxtral-remote-turn"]
    )

    /// What a `hooks.toml` holds, as far as this block is concerned.
    public enum Reading: Sendable, Equatable {
        case absent
        case current
        case outdated
        /// One of our hook names outside the block, or a key right after it.
        case conflicting
        /// Unpaired markers, or a marker inside a multi-line string.
        case unreadable
    }

    /// Why a `hooks.toml` was left alone. Each case is a different fix for
    /// the user; the caller owns the sentence, since it knows whose file it is.
    public enum Refusal: Sendable, Equatable {
        case notUTF8
        case unpairedMarkers
        case unclosedString
        case conflictingHookName
        case keyAfterBlock
        case hooksIsNotAnArrayOfTables
    }

    /// The first reason not to write into this text, or nil.
    public func refusal(for existing: String) -> Refusal? {
        if block.hasDamagedBlock(existing) { return .unpairedMarkers }
        if hasUnclosedOrMarkedMultilineString(existing) { return .unclosedString }
        if definesHooksStatically(existing) { return .hooksIsNotAnArrayOfTables }
        if declaresOurHookOutsideBlock(existing) { return .conflictingHookName }
        if keyFollowsBlock(existing) { return .keyAfterBlock }
        return nil
    }

    public func reading(of existing: String, snippet: String?) -> Reading {
        switch refusal(for: existing) {
        case .unpairedMarkers, .unclosedString, .notUTF8: return .unreadable
        case .conflictingHookName, .keyAfterBlock, .hooksIsNotAnArrayOfTables: return .conflicting
        case nil: break
        }
        guard block.containsBlock(existing) else { return .absent }
        guard let snippet else { return .current }
        return block.containsCurrentBlock(existing, snippet: snippet) ? .current : .outdated
    }

    /// `text` with our block removed. A static `hooks` value or a name
    /// collision does not stop a removal: taking our block out cannot make
    /// either worse.
    public func hooksByRemoving(from existing: String) throws -> String {
        let blocking: [Refusal] = [.unpairedMarkers, .unclosedString, .keyAfterBlock]
        if let refusal = refusal(for: existing), blocking.contains(refusal) { throw refusal }
        guard let remaining = block.remove(from: existing) else { throw Refusal.unpairedMarkers }
        return remaining
    }

    /// A bundled block file as the snippet `MarkedTextBlock` splices: without
    /// its trailing newline, and only when it is exactly one block of ours.
    public func snippet(fromBundled text: String) -> String? {
        let snippet = text.trimmingCharacters(in: .newlines)
        let lines = block.splitLines(snippet)
        guard case .present(let ranges) = block.locateBlock(in: lines),
              ranges == [0...(lines.count - 1)]
        else { return nil }
        return snippet
    }

    /// `hooks.toml` text with this build's block in it.
    public func hooksByInstalling(snippet: String, into existing: String) throws -> String {
        if let refusal = refusal(for: existing) { throw refusal }
        guard let updated = block.apply(to: existing, snippet: snippet) else { throw Refusal.unpairedMarkers }
        return updated
    }

    /// These checks read TOML line by line instead of parsing it: the
    /// app has no TOML parser, and each check only has to be right about the
    /// few shapes that make a marker-based edit unsafe. Each errs toward
    /// refusing.

    /// Does the text, with our block taken out, declare a hook with one of our
    /// exact names? `name` may be written bare or quoted, and the value in
    /// either TOML string style. Unpaired markers count as "yes": there is no
    /// telling what is outside a block that does not close.
    package func declaresOurHookOutsideBlock(_ existing: String) -> Bool {
        guard let outside = block.remove(from: existing) else { return true }
        return block.splitLines(outside).contains { line in
            guard let (key, value) = keyValue(in: line), key == "name" else { return false }
            // A multi-line value could spell one of our names on its next
            // line; this scan cannot tell, so it counts as a conflict.
            if value.hasPrefix("\"\"\"") || value.hasPrefix("'''") { return true }
            return hookNames.contains { value.hasPrefix("\"\($0)\"") || value.hasPrefix("'\($0)'") }
        }
    }

    /// Is the first meaningful line after a block a key rather than a table
    /// header? Such a key belongs to OUR last `[[hooks]]` table; removing or
    /// replacing the block would silently hand it to the table before.
    package func keyFollowsBlock(_ existing: String) -> Bool {
        let lines = block.splitLines(existing)
        guard case .present(let ranges) = block.locateBlock(in: lines) else { return false }
        return ranges.contains { range in
            let next = lines[(range.upperBound + 1)...].first { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
            guard let next else { return false }
            return !next.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        }
    }

    /// Does a marker line sit inside a TOML multi-line string, or is a string
    /// still open at the end of the file? A marker inside a string is the
    /// user's data, not a delimiter, and a block appended after an unclosed
    /// string lands INSIDE it. Counted as an odd number of `"""` or `'''`
    /// delimiters; a file this cannot classify is refused.
    package func hasUnclosedOrMarkedMultilineString(_ existing: String) -> Bool {
        var openBasic = false
        var openLiteral = false
        for line in block.splitLines(existing) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == block.markerBegin || trimmed == block.markerEnd {
                if openBasic || openLiteral { return true }
                continue
            }
            if !openLiteral, line.components(separatedBy: "\"\"\"").count % 2 == 0 { openBasic.toggle() }
            if !openBasic, line.components(separatedBy: "'''").count % 2 == 0 { openLiteral.toggle() }
        }
        return openBasic || openLiteral
    }

    /// Is `hooks` defined as a plain value (`hooks = [...]`) or a plain table
    /// (`[hooks]`)? TOML forbids extending either with `[[hooks]]` tables, so
    /// appending our block would make the WHOLE file unparseable and stop
    /// every hook the user has (GLM review, 2026-09-20).
    package func definesHooksStatically(_ existing: String) -> Bool {
        block.splitLines(existing).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let (key, _) = keyValue(in: line), key == "hooks" { return true }
            guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[[") else { return false }
            let header = trimmed.dropFirst().prefix { $0 != "]" }.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return header == "hooks"
        }
    }

    /// `key = value` of one line, the key unquoted. Nil for anything else.
    private func keyValue(in line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let equals = trimmed.firstIndex(of: "="), !trimmed.hasPrefix("#") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }
}

extension VibeHooksBlockEditor.Refusal: Error {}
