import Foundation

/// Dictation into a joined herdr pane through herdr's socket (#726): an
/// append is `pane.send_text`, a submit is `pane.send_keys ["enter"]`, both
/// to the one pane and socket the join resolved (`ClaudeHerdrPaneBinding`).
/// Built only by `ClaudeSessionJoinResolver.herdrPromptRoute(for:)`, for the
/// dictation in progress. Read docs/agent/invariants.md ("The app writes
/// into an agent only through its routes") before widening it.
package struct HerdrPanePromptRoute: AgentPromptRoute {
    /// Bytes of text one append may carry; anything longer goes by keys.
    package static let maxAppendBytes = 32 * 1024

    package let binding: ClaudeHerdrPaneBinding
    private let writer: any HerdrPaneWriting
    /// Whether the pane still runs the joined session's agent in the
    /// foreground. Asked before every Enter: a pane back at its shell would
    /// run the prompt as a command.
    private let agentIsForeground: @Sendable () async -> Bool
    /// Whether a key typed now would land in this pane: its terminal is
    /// frontmost and herdr's focused pane is this one. Asked only after a
    /// refusal, to choose between typing the text and keeping it in History.
    private let keysReachThePane: @Sendable () async -> Bool

    package var name: String { "herdr pane" }

    package init(
        binding: ClaudeHerdrPaneBinding,
        writer: any HerdrPaneWriting,
        agentIsForeground: @escaping @Sendable () async -> Bool,
        keysReachThePane: @escaping @Sendable () async -> Bool
    ) {
        self.binding = binding
        self.writer = writer
        self.agentIsForeground = agentIsForeground
        self.keysReachThePane = keysReachThePane
    }

    package func deliver(_ call: AgentPromptCall) async -> AgentPromptDelivery {
        let outcome: HerdrWriteOutcome
        switch call {
        case .append(let text):
            guard Self.isSendable(text) else {
                Log.backends.notice("herdr pane route: text holds a control character or is too long; not sent")
                return await refused()
            }
            outcome = await writer.sendText(socketPath: binding.socketPath, paneID: binding.paneID, text: text)
        case .submit:
            guard await agentIsForeground() else {
                // The text is in the pane's prompt already; nothing is typed.
                Log.backends.notice("herdr pane route: joined agent is no longer foreground in the pane; no Enter")
                return .keepInHistory
            }
            outcome = await writer.pressEnter(socketPath: binding.socketPath, paneID: binding.paneID)
        }
        switch outcome {
        case .ok: return .delivered
        case .refused: return await refused()
        // It may have landed: typing it again would put it in twice.
        case .unknown: return .keepInHistory
        }
    }

    /// herdr writes `pane.send_text` to the pane's input byte for byte, with
    /// no bracketed paste: a newline would press Enter, an escape would start
    /// a key sequence. Such text is never sent; keystrokes type it as text.
    package static func isSendable(_ text: String) -> Bool {
        guard text.utf8.count <= maxAppendBytes else { return false }
        return !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private func refused() async -> AgentPromptDelivery {
        await keysReachThePane() ? .typeInstead : .keepInHistory
    }
}
