/// Newline/tab guard for a Live Auto-Paste session judged NOT terminal-like at
/// its start (#513). The verdict is taken once, but focus can move to a
/// terminal mid-session, where a typed newline acts as Enter and submits the
/// prompt. So each chunk holding a newline or tab re-asks, just before it is
/// typed, whether the focused target is terminal-like now; if it is, every
/// whitespace run containing a newline or tab collapses to one space, the
/// same result `LiveHoldBackReplacementStream` gives a session started in a
/// terminal.
///
/// Unlike that stream, nothing is buffered: an editor session keeps typing
/// with no delay, and the check runs only for chunks that need it. The space
/// a collapsed run stands for is typed with the next non-whitespace
/// character, never at the end of a chunk. So a dictation ending in a newline
/// leaves no trailing space to dismiss a TUI autocomplete popup, and a chunk
/// that follows into another app keeps its own leading whitespace.
///
/// Two limits, both accepted: whitespace typed before a later chunk's newline
/// is already in the field, so `a␣␣` then `\nb` reaches the terminal as
/// `a␣␣b`, not `a␣b`. And an inconclusive AX probe reads as non-terminal,
/// the same verdict a session started in that app gets.
struct LiveTerminalNewlineGuard {
    /// Whether the last typed character was whitespace. Starts true, like the
    /// stream, so a collapse run opening the session types no leading space.
    private var lastTypedWasWhitespace = true
    /// A collapsed run's space not typed yet; the next non-whitespace
    /// character pays it, and the whitespace in front of that character is
    /// dropped in its favor.
    private var owesSpace = false

    struct Prepared {
        let text: String
        let collapsedRunCount: Int
        /// The guard state to keep once `text` is typed. A failed insertion
        /// keeps the old state, and the retry prepares the raw text again.
        let stateAfterTyping: LiveTerminalNewlineGuard
    }

    /// `targetIsTerminalLike` runs only when `text` holds a newline or tab.
    func prepare(_ text: String, targetIsTerminalLike: () -> Bool) -> Prepared {
        var owes = owesSpace
        var input = Substring(text)
        if owes {
            input = input.drop(while: { $0.isWhitespace && !Self.isCollapseTrigger($0) })
        }

        var output = ""
        var collapsedRunCount = 0
        if input.contains(where: Self.isCollapseTrigger), targetIsTerminalLike() {
            var run = ""
            var runNeedsCollapse = false
            var atSessionTextStart = lastTypedWasWhitespace && !owes
            func endRun() {
                if runNeedsCollapse {
                    collapsedRunCount += 1
                    // Right after typed whitespace the space is already there.
                    if !atSessionTextStart { owes = true }
                } else {
                    output.append(run)
                }
                run = ""
                runNeedsCollapse = false
            }
            for character in input {
                if character.isWhitespace {
                    run.append(character)
                    runNeedsCollapse = runNeedsCollapse || Self.isCollapseTrigger(character)
                    continue
                }
                endRun()
                if owes {
                    output.append(" ")
                    owes = false
                }
                output.append(character)
                atSessionTextStart = false
            }
            endRun()
        } else if owes, let first = input.first {
            // Not a terminal now: a newline of its own replaces the owed
            // space; anything else gets it back.
            output = Self.isCollapseTrigger(first) ? String(input) : " " + input
            owes = false
        } else {
            output = String(input)
        }

        var next = self
        if let last = output.last {
            next.lastTypedWasWhitespace = last.isWhitespace
        }
        next.owesSpace = owes
        return Prepared(text: output, collapsedRunCount: collapsedRunCount, stateAfterTyping: next)
    }

    private static func isCollapseTrigger(_ character: Character) -> Bool {
        character.isNewline || character == "\t"
    }
}
