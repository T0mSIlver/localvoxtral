import Foundation
import localvoxtralCore

extension LLMPolishingConfiguration {
    package enum ReplayError: Error, Equatable {
        case notAJSONObject
        case unknownField(String)
    }

    /// A polishing server named on a replay script's command line
    /// (`scripts/linux/quick-capture-*.sh`): the shape read from the host,
    /// as Settings reads an External URL, with Mistral's API on its own
    /// shape, and the settings `extra` names as a JSON object:
    /// `chat_template_kwargs`, `thinking_budget_tokens`, `reasoning_effort`
    /// (`none`, `low` or `high`). Any other field is an error, since no
    /// setting would send it.
    package static func replay(url: URL, apiKey: String, model: String, extra: String? = nil) throws -> Self {
        var object: [String: Any] = [:]
        if let extra, !extra.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: Data(extra.utf8))) as? [String: Any]
            else { throw ReplayError.notAJSONObject }
            object = parsed
        }
        if let unknown = object.keys.sorted().first(where: {
            !["chat_template_kwargs", "thinking_budget_tokens", "reasoning_effort"].contains($0)
        }) {
            throw ReplayError.unknownField(unknown)
        }
        let effort = (object["reasoning_effort"] as? String).flatMap { wire in
            [MistralReasoningEffort.off, .low, .high].first { $0.wireValue == wire }
        }
        return LLMPolishingConfiguration(
            endpointURL: url,
            apiKey: apiKey,
            model: model,
            chatTemplateArguments: object["chat_template_kwargs"] as? [String: Bool],
            thinkingBudgetTokens: object["thinking_budget_tokens"] as? Int,
            requestShape: url.host?.lowercased() == "api.mistral.ai" ? .mistral : .forExternalEndpoint(url),
            mistralReasoningEffort: effort
        )
    }
}
