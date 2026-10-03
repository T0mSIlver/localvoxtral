import Foundation
import Synchronization
import localvoxtralCore

/// A route that answers each call with the outcome `answer` picks and
/// records what it was asked. `answer` may suspend, to hold a call open.
package final class ScriptedPromptRoute: AgentPromptRoute, @unchecked Sendable {
    private let answer: @Sendable (AgentPromptCall) async -> AgentPromptDelivery
    private let received = Mutex<[AgentPromptCall]>([])

    package init(answer: @escaping @Sendable (AgentPromptCall) async -> AgentPromptDelivery) {
        self.answer = answer
    }

    package var name: String { "scripted route" }
    package var calls: [AgentPromptCall] { received.withLock { $0 } }

    package func deliver(_ call: AgentPromptCall) async -> AgentPromptDelivery {
        received.withLock { $0.append(call) }
        return await answer(call)
    }
}
