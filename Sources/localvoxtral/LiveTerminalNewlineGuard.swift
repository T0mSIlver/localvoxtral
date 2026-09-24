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
/// with no delay, and the check runs only for chunks that need it. The state
/// below carries the previous chunk's ending across the boundary so no double
/// space appears either side of a collapsed run.
struct LiveTerminalNewlineGuard {
    /// Whether the last typed character was whitespace. Starts true, like the
    /// stream, so a collapse run opening the session types no leading space.
    private var lastTypedWasWhitespace = true
    /// Whether the last chunk ended in a collapsed run; the next chunk's
    /// leading whitespace is then dropped (the run's space is already typed).
    private var endsWithCollapsedRun = false

    struct Prepared {
        let text: String
        let collapsedRunCount: Int
        /// The guard state to keep once `text` is typed. A failed insertion
        /// keeps the old state, and the retry prepares the raw text again.
        let stateAfterTyping: LiveTerminalNewlineGuard
    }

    /// `targetIsTerminalLike` runs only when `text` holds a newline or tab.
    func prepare(_ text: String, targetIsTerminalLike: () -> Bool) -> Prepared {
        var input = Substring(text)
        if endsWithCollapsedRun {
            input = input.drop(while: { $0.isWhitespace && !Self.isCollapseTrigger($0) })
        }

        var output = ""
        var collapsedRunCount = 0
        var trailingRunCollapsed = false
        if input.contains(where: Self.isCollapseTrigger), targetIsTerminalLike() {
            var run = ""
            var runNeedsCollapse = false
            var precededByWhitespace = endsWithCollapsedRun || lastTypedWasWhitespace
            func emitRun() {
                if runNeedsCollapse {
                    collapsedRunCount += 1
                    if !precededByWhitespace { output.append(" ") }
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
                emitRun()
                output.append(character)
                precededByWhitespace = false
            }
            trailingRunCollapsed = runNeedsCollapse
            emitRun()
        } else {
            output = String(input)
        }

        var next = self
        if let last = output.last {
            next.lastTypedWasWhitespace = last.isWhitespace
        }
        if !output.isEmpty || trailingRunCollapsed {
            next.endsWithCollapsedRun = trailingRunCollapsed
        }
        return Prepared(text: output, collapsedRunCount: collapsedRunCount, stateAfterTyping: next)
    }

    private static func isCollapseTrigger(_ character: Character) -> Bool {
        character.isNewline || character == "\t"
    }
}
