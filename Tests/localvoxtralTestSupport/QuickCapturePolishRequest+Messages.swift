import localvoxtralCore

extension QuickCapturePolishRequest {
    /// The chat messages: the system prompt when there is one, then each
    /// user message, as a chat/completions body orders them.
    package var messages: [[String: String]] {
        (systemPrompt.isEmpty ? [] : [["role": "system", "content": systemPrompt]])
            + userPrompts.map { ["role": "user", "content": $0] }
    }
}
