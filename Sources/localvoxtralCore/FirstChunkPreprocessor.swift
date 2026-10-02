import Foundation

/// Applies one-time normalization to the first transcript chunk in a session:
/// trims leading whitespace/newlines from the first non-empty chunk. After a
/// reconnect, the replacement server session's first text gets a leading space
/// when it has none instead (#1364).
package struct FirstChunkPreprocessor {
    private(set) var isFirstChunkPending = true
    private(set) var isReconnectBoundaryPending = false

    package init() {}

    package mutating func reset() {
        isFirstChunkPending = true
        isReconnectBoundaryPending = false
    }

    /// The socket was replaced while the dictation already holds text. The
    /// new server session starts a fresh transcript whose first word carries
    /// no space, and would run into the last word typed; the context
    /// rollover handles the same case in `RealtimeAPIWebSocketClient`.
    package mutating func markReconnect() {
        guard !isFirstChunkPending else { return }
        isReconnectBoundaryPending = true
    }

    package mutating func preprocess(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        if isFirstChunkPending {
            isFirstChunkPending = false
            guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return "" }
            return String(text[start...])
        }
        guard isReconnectBoundaryPending else { return text }
        isReconnectBoundaryPending = false
        return text.first?.isWhitespace == true ? text : " " + text
    }
}
