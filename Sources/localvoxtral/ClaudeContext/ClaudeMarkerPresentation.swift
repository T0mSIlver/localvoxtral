import ClaudeContextWire
import Foundation

/// Reading a marker back out of the focused terminal.
///
/// The *outbound* half of the focus join is done and no longer pluggable: the
/// broker allocates a marker, replies with it on the socket, and the publisher
/// asks Claude Code to write it into the window title via an OSC 2 sequence
/// (`ClaudeMarkerSequence`). The marker is on screen, in the title bar.
///
/// The *inbound* half — given the frontmost window, which marker is it showing?
/// — is what remains, and it is per-terminal work rather than one mechanism:
/// AX `AXTitle` on the focused window covers most terminals, but Ghostty has
/// historically exposed no screen text and may need its own path.
///
/// Until an implementation exists, this abstains. That is the correct
/// behaviour, not a placeholder: a wrong answer here silently attributes one
/// session's context to another terminal, which is worse than no context at
/// all. Callers must treat nil as "we do not know" — never as a cue to guess.
public protocol ClaudeMarkerReading: Sendable {
    /// The marker visible in the focused terminal, or nil to abstain.
    func markerInFocusedTerminal() -> ClaudeSessionMarker?
}

/// The shipping implementation until the per-terminal readback lands.
public struct ClaudeUnavailableMarkerReader: ClaudeMarkerReading {
    public init() {}

    public func markerInFocusedTerminal() -> ClaudeSessionMarker? {
        nil
    }
}

/// Recovers a marker from a window title.
///
/// Split out from any AX plumbing so the parsing is testable on its own, and so
/// the terminal-specific part stays as small as possible.
public enum ClaudeMarkerTitleParser {
    /// Extract a marker from a title string.
    ///
    /// Terminals decorate titles freely (appending a shell name, a size, a
    /// directory), so the marker is searched for rather than matched whole —
    /// but only the exact grammar `ClaudeMarkerSequence` is willing to emit is
    /// ever accepted, and an ambiguous title yields nothing.
    public static func marker(inTitle title: String) -> ClaudeSessionMarker? {
        // Whitespace only — a marker contains "-" (`lvx-abcd`), so splitting on
        // punctuation would tear it in half.
        let candidates = title
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { ClaudeMarkerSequence.isValidMarker($0) }

        // Two markers in one title means we cannot tell which session owns the
        // window. Abstain.
        guard candidates.count == 1 else { return nil }
        return ClaudeSessionMarker(value: candidates[0])
    }
}
