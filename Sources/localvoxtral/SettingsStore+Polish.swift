import Foundation

extension SettingsStore {
    var llmPolishingConfiguration: LLMPolishingConfiguration? {
        guard llmPolishingEnabled else { return nil }
        if polishingBackendMode == .managedLocal {
            guard let url = URL(string: ManagedBackendEndpoints.polishingURLString)
            else { return nil }
            let model = resolvedManagedLLMPolishingModel
            let option = PolishModelCatalog.option(forRepoID: model)
            return LLMPolishingConfiguration(
                endpointURL: url,
                apiKey: "",
                model: model,
                samplingDefaults: option?.samplingDefaults,
                chatTemplateArguments: option?.chatTemplateArguments
            )
        }
        if polishingBackendMode == .mistralAPI {
            // No key, no request. A polish sent to Mistral without credentials
            // can only come back 401, and the commit path reports a nil
            // configuration as one actionable line — which is strictly better
            // than an HTTP status the user cannot act on.
            let key = trimmedMistralAPIKey
            guard !key.isEmpty else { return nil }
            return LLMPolishingConfiguration(
                endpointURL: MistralPolishDefaults.endpoint,
                apiKey: key,
                model: resolvedMistralPolishingModel,
                requestShape: .mistral,
                mistralReasoningEffort: MistralReasoningEffort.forModel(
                    resolvedMistralPolishingModel, catalog: mistralModelCatalog
                )
            )
        }
        let trimmedEndpoint = llmPolishingEndpointURL.trimmed
        guard !trimmedEndpoint.isEmpty, let url = URL(string: trimmedEndpoint) else { return nil }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            components.host != nil
        else {
            return nil
        }
        return LLMPolishingConfiguration(
            endpointURL: url,
            apiKey: llmPolishingAPIKey.trimmed,
            model: llmPolishingModel.trimmed.isEmpty
                ? Self.defaultLLMPolishingModel
                : llmPolishingModel.trimmed
        )
    }

    /// The managed picker's stored selection, hardened against an empty env
    /// override. External mode's `llmPolishingModel` is a server-side model
    /// NAME; this is an HF repo the helper must download — separate keys so a
    /// leftover external value can never leak into a managed launch.
    var resolvedManagedLLMPolishingModel: String {
        let model = managedLLMPolishingModel.trimmed
        return model.isEmpty ? Self.defaultLLMPolishingModel : model
    }
}
