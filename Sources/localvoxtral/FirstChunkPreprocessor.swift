import Foundation

/// Applies one-time normalization for the first transcript chunk in a session.
/// Current rule: trim leading whitespace/newlines from the first non-empty chunk.
struct FirstChunkPreprocessor {
    private(set) var isFirstChunkPending = true

    mutating func reset() {
        isFirstChunkPending = true
    }

    mutating func preprocess(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        guard isFirstChunkPending else { return text }
        isFirstChunkPending = false
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(text[start...])
    }
}
