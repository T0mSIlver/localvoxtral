import Foundation

/// Scrubs secret-shaped runs out of a record before it reaches disk.
///
/// Records keep screen text, rendered prompts and harvested repo terms, and a
/// terminal shows secrets: an `export` line, a `curl -H "Authorization: …"`,
/// a key a CLI printed. The app cannot know which strings are secrets, so it
/// matches the shapes they come in. That is a backstop: it misses a secret
/// with no recognisable shape, and it masks some strings that are not
/// secrets (a full git commit hash is long hex). The guarantee is that
/// records never leave the Mac.
package enum DiagnosticRecordRedaction {
    package static let placeholder = ClaudeRemoteTokenRedaction.placeholder
    /// Stands in for the lines of the prompt the user last sent to their
    /// agent (`withholdPrompt`).
    package static let withheldPromptPlaceholder = "<prior prompt withheld>"
    /// Stands in for the joined session's unsent prompt draft
    /// (`ClaudePromptDraft`), which the session context carries too.
    package static let withheldDraftPlaceholder = "<prompt draft withheld>"
    /// The remote-enrollment token: 43 base64url characters with no prefix.
    package static let tokenLength = 43

    /// Pattern and replacement template, applied in order. A replacement
    /// keeps the label in front of the secret (`Bearer `, `API_KEY=`) so a
    /// review still sees what was there.
    private static let rules: [(NSRegularExpression, String)] = [
        // A PEM private key, to its END line or, when the screen cut it off,
        // to the end of the text.
        (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#,
         placeholder),
        // A JWT: base64url JSON header, payload and (possibly cut) signature.
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#, placeholder),
        // `Bearer <token>`; the token must hold a digit or a symbol, so
        // "bearer instruments" stays.
        (#"(?i)(\bbearer\s+)(?=[A-Za-z0-9._~+/=-]*[0-9._~+/=-])[A-Za-z0-9._~+/=-]{12,}"#,
         "$1" + placeholder),
        // Keys whose prefix names the service.
        (#"\b(?:sk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abposr]-[A-Za-z0-9-]{10,}|(?:AKIA|ASIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|glpat-[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{30,}|(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}|npm_[A-Za-z0-9]{36}|pypi-[A-Za-z0-9_-]{50,})"#,
         placeholder),
        // A shell assignment to a variable named like a secret:
        // `OPENAI_API_KEY=…`, `export DB_PASSWORD="…"`, and the bare
        // `PASSWORD=…` (#1571).
        (#"\b((?:[A-Z][A-Z0-9_]*)?(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)[A-Z0-9_]*\s*=\s*["']?)[^\s"']{6,}"#,
         "$1" + placeholder),
        // 32 or more hex digits: API secrets, session ids, and also full
        // commit hashes, which a record can do without.
        (#"(?<![A-Za-z0-9])[0-9a-fA-F]{32,}(?![A-Za-z0-9])"#, placeholder),
    ].map { pattern, template in
        // The patterns are literals; a typo is a crash on first use in any
        // test that writes a record.
        (try! NSRegularExpression(pattern: pattern), template)
    }

    /// Redacts in place, returning how many runs were replaced.
    package static func redact(_ record: inout DiagnosticRecord) -> Int {
        var count = 0
        forEachString(in: &record) { redacting($0, count: &count) }
        return count
    }

    /// Replaces every secret-shaped run in `text`, adding the number replaced
    /// to `count`.
    package static func redacting(_ text: String, count: inout Int) -> String {
        // The shortest shape above is a ten-character `KEY=` assignment.
        guard text.utf16.count >= 10 else { return text }
        var output = text
        for (expression, template) in rules {
            let range = NSRange(output.startIndex..., in: output)
            let matches = expression.numberOfMatches(in: output, range: range)
            guard matches > 0 else { continue }
            count += matches
            output = expression.stringByReplacingMatches(
                in: output, range: range, withTemplate: template)
        }
        return redactingTokenRuns(output, count: &count)
    }

    /// Replaces every maximal base64url run of exactly `tokenLength`
    /// characters. Runs of any other length are left alone: a token is fixed
    /// width, and "any long base64-ish thing" would shred identifiers.
    private static func redactingTokenRuns(_ text: String, count: inout Int) -> String {
        guard text.count >= tokenLength else { return text }

        var output = ""
        output.reserveCapacity(text.count)
        var run = ""

        func flush() {
            if run.count == tokenLength {
                output += placeholder
                count += 1
            } else {
                output += run
            }
            run.removeAll(keepingCapacity: true)
        }

        for character in text {
            if isBase64URL(character) {
                run.append(character)
            } else {
                flush()
                output.append(character)
            }
        }
        flush()
        return output
    }

    private static func isBase64URL(_ character: Character) -> Bool {
        character.isLetter && character.isASCII
            || character.isNumber && character.isASCII
            || character == "-"
            || character == "_"
    }

    // MARK: - The prompt sent to the agent

    /// Takes the prompt the user last sent to their agent out of the record's
    /// context text. The joined session hands it over as context
    /// (`ClaudeSessionContextText`), so it reaches the rendered prompts and
    /// the agent source's excerpt; a Claude Code screen shows it too. The app
    /// promises it never saves that prompt (docs/dictation.md), and a record
    /// is a save.
    ///
    /// First the whole prompt behind its label, whatever its length, and the
    /// rest of the label's line, which holds the prompt's first line however
    /// short. Then line by line, because the excerpt selector keeps whole
    /// lines and the screen shows the prompt without the label. Lines shorter
    /// than `minimumLineLength` are left to the label passes: "ok" would mask
    /// every "ok" in the record. A line the excerpt cut short is caught by its
    /// first `truncatedPrefixLength` characters, masked to the end of that
    /// line. The transcript fields are left alone: the user may dictate the
    /// same words again, and those are this dictation's.
    ///
    /// Every pass looks for each line both as sent and as a selected excerpt
    /// renders it (`PolishContextExcerptSelector.renderedLine`: tabs as
    /// spaces, control characters dropped), because a context over its grant
    /// renders the second form (#1106).
    ///
    /// The screen gets one more pass (`withholdingWrapped`): a terminal
    /// soft-wraps a long prompt line at the pane width and expands its tabs,
    /// so a row there can hold any stretch of a line (#1121).
    package static func withholdPrompt(_ prompt: String?, from record: inout DiagnosticRecord) {
        withhold(.priorPrompt(prompt), from: &record)
    }

    /// The person's own words the context carried and a record must not
    /// keep: the text, the labels that head it in the session block, and
    /// what stands in for it.
    package struct Withheld: Equatable {
        package let text: String
        package let labels: [String]
        package let placeholder: String
        /// Pieces of `text` whose lines are looked for too: a field may hold
        /// one of them on its own.
        package var pieces: [String] = []

        /// `text` and its pieces, one line per needle.
        var needles: String {
            ([text] + pieces).joined(separator: "\n")
        }

        /// The prompt the user last sent to the joined agent.
        package static func priorPrompt(_ prompt: String?) -> Withheld? {
            guard let prompt, !prompt.isEmpty else { return nil }
            return Withheld(
                text: prompt,
                labels: [ClaudeSessionContextText.priorPromptLabel],
                placeholder: withheldPromptPlaceholder
            )
        }

        /// The joined session's unsent draft, both sides of the cursor. The
        /// session block puts each side on one line behind its label; the
        /// screen shows the draft's own lines, which the cursor does not
        /// split. Each side's lines are looked for as well, for a field that
        /// holds only one side.
        package static func draft(_ draft: ClaudePromptDraft?) -> Withheld? {
            guard let draft, !draft.isEmpty else { return nil }
            return Withheld(
                text: draft.beforeCursor + draft.afterCursor,
                labels: [ClaudePromptDraft.beforeCursorLabel, ClaudePromptDraft.afterCursorLabel],
                placeholder: withheldDraftPlaceholder,
                pieces: [draft.beforeCursor, draft.afterCursor].filter { !$0.isEmpty }
            )
        }
    }

    /// `withholdPrompt` for every `Withheld` the record must not keep, all
    /// at once: one value's text can spell part of another's label ("prompt
    /// box"), so every label is masked before any value's lines are.
    package static func withhold(_ withheld: [Withheld], from record: inout DiagnosticRecord) {
        guard !withheld.isEmpty else { return }
        let withhold = promptWithholder(withheld, softWrapped: false)
        let withholdScreen = promptWithholder(withheld, softWrapped: true)

        func withholdOptional(_ text: inout String?) {
            text = text.map(withhold)
        }

        withholdOptional(&record.text.systemPrompt)
        record.text.userPrompts = record.text.userPrompts.map(withhold)
        if var screen = record.screen {
            screen.sanitizedText = screen.sanitizedText.map(withholdScreen)
            record.screen = screen
        }
        for index in record.sources.indices {
            withholdOptional(&record.sources[index].renderedExcerpt)
        }
    }

    /// `withholdPrompt` for any `Withheld`.
    package static func withhold(_ withheld: Withheld?, from record: inout DiagnosticRecord) {
        withhold([withheld].compactMap { $0 }, from: &record)
    }

    /// `text` with the prompt taken out as `withholdPrompt` takes it out of
    /// the record's fields. A source's harvest is re-derived from its text,
    /// so the builder harvests what this returns; harvested from the text as
    /// captured, the harvest keeps the prompt's identifiers.
    ///
    /// `softWrapped` adds the screen's pass (`withholdingWrapped`). It walks
    /// the text once per prompt anchor, so only screen text, which is capped,
    /// takes it; the clipboard can hold millions of characters.
    package static func withholdingPrompt(_ prompt: String?, in text: String, softWrapped: Bool) -> String {
        withholding(.priorPrompt(prompt), in: text, softWrapped: softWrapped)
    }

    /// `text` with every one of `withheld` taken out, labels first, as
    /// `withhold(_:from:)` takes them out of a record.
    package static func withholding(_ withheld: [Withheld], in text: String, softWrapped: Bool) -> String {
        withheld.isEmpty ? text : promptWithholder(withheld, softWrapped: softWrapped)(text)
    }

    /// `withholdingPrompt` for any `Withheld`.
    package static func withholding(_ withheld: Withheld?, in text: String, softWrapped: Bool) -> String {
        withholding([withheld].compactMap { $0 }, in: text, softWrapped: softWrapped)
    }

    /// The label, soft-wrap, whole-line and cut-line passes `withholdPrompt`
    /// runs on every field, each pass over every value before the next pass.
    private static func promptWithholder(_ withheld: [Withheld], softWrapped: Bool) -> (String) -> String {
        let labelled = withheld.flatMap { value in
            let renderedText = value.text.components(separatedBy: "\n")
                .map(PolishContextExcerptSelector.renderedLine)
                .joined(separator: "\n")
            return value.labels.flatMap { label in
                Set([value.text, renderedText]).map {
                    (whole: label + $0, label: label, placeholder: value.placeholder)
                }
            }
        }
        .sorted { $0.whole.count > $1.whole.count }
        let lines = withheld.flatMap { value in
            Set(
                value.needles.split(whereSeparator: \.isNewline).flatMap { line in
                    [String(line), PolishContextExcerptSelector.renderedLine(String(line))]
                }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= minimumLineLength }
            )
            .map { (line: $0, placeholder: value.placeholder) }
        }
        .sorted { $0.line.count > $1.line.count }

        /// Replaces each `head` and the rest of its line with `kept` and the
        /// placeholder, searching on after each replacement, which may hold
        /// `head` itself.
        func maskingToLineEnd(
            _ head: String, in text: String, keeping kept: String = "", placeholder: String
        ) -> String {
            let replacement = kept + placeholder
            var output = text
            var searchFrom = 0
            while let found = output.range(
                of: head, range: output.index(output.startIndex, offsetBy: searchFrom)..<output.endIndex
            ) {
                let end = output[found.lowerBound...].firstIndex(where: \.isNewline)
                    ?? output.endIndex
                searchFrom = output.distance(from: output.startIndex, to: found.lowerBound)
                    + replacement.count
                output.replaceSubrange(found.lowerBound..<end, with: replacement)
            }
            return output
        }

        func withhold(_ text: String) -> String {
            var output = text
            for (whole, label, placeholder) in labelled {
                output = output.replacingOccurrences(of: whole, with: label + placeholder)
            }
            for value in withheld {
                for label in value.labels {
                    output = maskingToLineEnd(label, in: output, keeping: label, placeholder: value.placeholder)
                }
            }
            if softWrapped {
                for value in withheld {
                    output = withholdingWrapped(value.needles, in: output, placeholder: value.placeholder)
                }
            }
            for (line, placeholder) in lines {
                output = output.replacingOccurrences(of: line, with: placeholder)
            }
            for (line, placeholder) in lines where line.count >= truncatedPrefixLength {
                output = maskingToLineEnd(
                    String(line.prefix(truncatedPrefixLength)), in: output, placeholder: placeholder)
            }
            return output
        }

        return withhold
    }

    /// Masks the stretches of `text` that spell a prompt line once whitespace
    /// and control characters are ignored on both sides, so a row break, the
    /// continuation row's indent or a tab's spaces never stop a match.
    ///
    /// A screen may hold only part of a line: rows scrolled off the top, rows
    /// past the capture cap. So every `truncatedPrefixLength`-character
    /// stretch of the line (and its last one) is an anchor, and each anchor
    /// found is extended both ways for as long as the line goes on matching.
    /// A line shorter than an anchor must match whole; one shorter than
    /// `minimumLineLength` is not looked for, as in `withholdPrompt`.
    package static func withholdingWrapped(
        _ prompt: String, in text: String, placeholder: String = withheldPromptPlaceholder
    ) -> String {
        let needles = prompt.split(whereSeparator: \.isNewline)
            .map { $0.filter(isSpelled) }
            .filter { $0.count >= minimumLineLength }
            .map(Array.init)
            .sorted { $0.count > $1.count }
        var output = text
        for needle in needles {
            let indices = output.indices.filter { isSpelled(output[$0]) }
            let haystack = indices.map { output[$0] }
            let anchor = min(needle.count, truncatedPrefixLength)
            let starts = Set(Array(stride(from: 0, to: needle.count - anchor, by: anchor))
                + [needle.count - anchor])

            var spans: [Range<Int>] = []
            for start in starts.sorted() {
                let key = needle[start..<start + anchor]
                var position = 0
                while position + anchor <= haystack.count {
                    defer { position += 1 }
                    guard haystack[position..<position + anchor].elementsEqual(key) else { continue }
                    var lower = position, upper = position + anchor
                    var needleLower = start, needleUpper = start + anchor
                    while lower > 0, needleLower > 0, haystack[lower - 1] == needle[needleLower - 1] {
                        lower -= 1
                        needleLower -= 1
                    }
                    while upper < haystack.count, needleUpper < needle.count,
                          haystack[upper] == needle[needleUpper] {
                        upper += 1
                        needleUpper += 1
                    }
                    spans.append(lower..<upper)
                }
            }

            var merged: [Range<Int>] = []
            for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, span.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
                } else {
                    merged.append(span)
                }
            }
            for span in merged.reversed() {
                let range = indices[span.lowerBound]..<output.index(after: indices[span.upperBound - 1])
                output.replaceSubrange(range, with: placeholder)
            }
        }
        return output
    }

    /// A character a terminal shows as written: not whitespace, which wraps
    /// and tab stops rewrite, and not a control character, which the screen
    /// and excerpt sanitizers drop.
    private static func isSpelled(_ character: Character) -> Bool {
        !character.isWhitespace
            && !character.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    package static let minimumLineLength = 8
    package static let truncatedPrefixLength = 24

    /// Every string a record carries, not just the bulky ones: a proposal's
    /// `term` comes out of the harvest and its `heard` spans out of the
    /// transcript, so a secret reaches disk through an entry as easily as
    /// through the harvest.
    private static func forEachString(
        in record: inout DiagnosticRecord, _ transform: (String) -> String
    ) {
        func each(_ text: inout String) { text = transform(text) }
        func each(_ text: inout String?) { text = text.map(transform) }
        func each(_ entries: inout [DiagnosticRecord.Source.Entry]) {
            for index in entries.indices {
                entries[index].term = transform(entries[index].term)
                entries[index].heard = entries[index].heard.map(transform)
            }
        }

        each(&record.text.rawTranscript)
        each(&record.text.workingText)
        each(&record.text.groundedText)
        each(&record.text.systemPrompt)
        each(&record.text.polishedOutput)
        each(&record.text.committedText)
        record.text.userPrompts = record.text.userPrompts.map(transform)
        if var screen = record.screen {
            each(&screen.sanitizedText)
            record.screen = screen
        }
        for index in record.sources.indices {
            record.sources[index].harvest = record.sources[index].harvest.map(transform)
            each(&record.sources[index].renderedExcerpt)
            each(&record.sources[index].entries)
            each(&record.sources[index].phoneticEntries)
            each(&record.sources[index].verificationEntries)
        }
    }
}
