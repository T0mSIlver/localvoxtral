import ClaudeContextWire
import ClaudeHookPublisherCore
import Foundation

// localvoxtral-claude-hook — the Claude Code hook publisher.
//
// Invoked once per hook event as `localvoxtral-claude-hook --event <Name>`
// with the hook JSON on stdin. It reads, normalizes, enriches with process/TTY
// metadata, and fires one NDJSON line at the app's socket under a ~250ms
// deadline.
//
// It exits 0 on every path and prints nothing, ever. Claude Code interprets a
// hook's stdout and surfaces its failures; a dictation nicety must never be
// able to interfere with the user's turn. All error handling above is
// "return a reason no one reads".
//
// The target is named for the binary because SwiftPM names the built
// executable after the TARGET, not the product — same reason
// PolishHelper's target is `localvoxtral-polishd`.

func parsedEvent(from arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "--event"), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())

// Status-line mode: `localvoxtral-claude-hook --statusline`, wired by the USER
// into Claude Code's `statusLine` setting (the app never writes that file).
// Reads the status-line payload, asks the broker whether this session is live,
// and prints ONE fixed indicator line. The strings are compile-time constants
// chosen by outcome — nothing read off the socket is ever echoed — and a
// payload we cannot attribute prints nothing rather than guessing.
if arguments.contains("--statusline") {
    let payload = ClaudeHookPublisher.readBoundedStdin()
    let outcome = ClaudeHookPublisher().runStatusQuery(stdin: payload)
    if let text = ClaudeHookPublisher.statusLineText(for: outcome) {
        ClaudeHookPublisher.writeStdout(Data((text + "\n").utf8))
    }
    exit(0)
}

let event = parsedEvent(from: arguments)
let stdin = ClaudeHookPublisher.readBoundedStdin()
let outcome = ClaudeHookPublisher().run(stdin: stdin, fallbackEvent: event)

// The ONLY thing this process ever prints: a complete, valid hook JSON object
// carrying the marker's terminal sequence. `stdout` is nil on every other path,
// and nil means print nothing — not an empty object, not a newline.
//
// This matters most for UserPromptSubmit, whose non-JSON stdout Claude Code
// appends to the user's prompt. Half-written or malformed output would land in
// their context as garbage, so it is emitted in one write or not at all.
if let output = outcome.stdout {
    ClaudeHookPublisher.writeStdout(output)
}
exit(0)
