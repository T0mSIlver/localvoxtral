import Foundation

extension SettingsStore {
    func persistMistralModelCatalog() {
        guard let data = try? JSONEncoder().encode(mistralModelCatalog) else { return }
        defaults.set(data, forKey: Keys.mistralModelCatalog)
    }

    static func loadMistralModelCatalog(from defaults: UserDefaults) -> [MistralModel] {
        guard let data = defaults.data(forKey: Keys.mistralModelCatalog) else { return [] }
        do {
            return try JSONDecoder().decode([MistralModel].self, from: data)
        } catch {
            // A cache: the next fetch rebuilds it.
            Log.persistence.error(
                "Stored Mistral model list is unreadable; starting empty. \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    var trimmedAPIKey: String {
        // `trimmedAPIKey` is only ever used as the realtime connection bearer
        // token (see RealtimeAPIWebSocketClient, which omits the Authorization
        // header when it is empty). Managed local servers need no key.
        switch dictationBackendMode {
        case .managedLocal:
            return ""
        case .externalURL:
            return apiKey.trimmed
        case .mistralAPI:
            return trimmedMistralAPIKey
        }
    }

    // MARK: - Mistral API

    var trimmedMistralAPIKey: String { mistralAPIKey.trimmed }

    var resolvedMistralDictationModel: String {
        let model = mistralDictationModel.trimmed
        return model.isEmpty ? MistralRealtimeWebSocketClient.defaultModel : model
    }

    var resolvedMistralPolishingModel: String {
        let model = mistralPolishingModel.trimmed
        return model.isEmpty ? MistralPolishDefaults.model : model
    }

    /// Whether the Mistral engines have everything they need. The key is the
    /// only thing a user can get wrong here — the endpoints are pinned and the
    /// models have defaults.
    var isMistralAPIConfigured: Bool { !trimmedMistralAPIKey.isEmpty }

    /// The Engines pane's one-line Mistral status. Deliberately says nothing
    /// about reachability: Settings never fires a request of its own, and the
    /// "Check key" row is where a user asks Mistral anything.
    var mistralAPIStatusSummary: String {
        // A keychain that will not answer must never read as "API key missing":
        // that sends the user to paste a key they already have.
        if let secretStoreFailureSummary { return secretStoreFailureSummary }
        return isMistralAPIConfigured ? "Ready" : "API key missing"
    }

    var effectiveModelName: String {
        effectiveModelName(for: realtimeProvider)
    }

    var displayModelName: String {
        effectiveModelName
    }

    var endpointPlaceholder: String {
        realtimeProvider.defaultEndpoint
    }

    var modelPlaceholder: String {
        realtimeProvider.defaultModelName
    }

    func modelName(for provider: RealtimeProvider) -> String {
        realtimeAPIModelName
    }

    func effectiveModelName(for provider: RealtimeProvider) -> String {
        if dictationBackendMode == .mistralAPI {
            // Hosted Voxtral ids have nothing to do with the external
            // provider's placeholder or the managed HF repo pin.
            return resolvedMistralDictationModel
        }
        if dictationBackendMode == .managedLocal {
            // The bundled Swift engine needs its dedicated HF-layout pin.
            // Keep the external provider's placeholder/default independent:
            // user-typed external values remain ignored in managed mode, but
            // an existing external endpoint still sees its historical model.
            return resolvedManagedSpeechModel.repoID
        }
        let normalized = Self.normalizedModelName(from: modelName(for: provider))
        return normalized.isEmpty ? provider.defaultModelName : normalized
    }

    func endpointURL(for provider: RealtimeProvider) -> String {
        realtimeAPIEndpointURL
    }

    var resolvedWebSocketURL: URL? {
        resolvedWebSocketURL(for: realtimeProvider)
    }

    func resolvedWebSocketURL(for provider: RealtimeProvider) -> URL? {
        if dictationBackendMode == .mistralAPI {
            // Pinned, not user-editable: the client appends the `?model=` query
            // item itself, so a hand-typed endpoint could only break it.
            return MistralRealtimeWebSocketClient.defaultEndpoint
        }
        if dictationBackendMode == .managedLocal {
            return URL(string: ManagedBackendEndpoints.realtimeURLString)
        }
        let trimmed = endpointURL(for: provider).trimmed
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
            return URL(string: trimmed)
        }

        if trimmed.hasPrefix("http://") {
            return URL(string: "ws://" + trimmed.dropFirst("http://".count))
        }

        if trimmed.hasPrefix("https://") {
            return URL(string: "wss://" + trimmed.dropFirst("https://".count))
        }

        return URL(string: "ws://\(trimmed)")
    }

    static func normalizedModelName(from raw: String) -> String {
        let trimmed = raw.trimmed
        guard !trimmed.isEmpty else { return "" }

        let lines =
            trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }

        guard let candidate = lines.last else {
            return trimmed
        }

        if candidate.contains(" ") {
            let tokens = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
            if let token = tokens.last {
                return token
            }
        }

        return candidate
    }

    /// The catalog entry the managed dictation helper runs. Resolves only
    /// entries the bundled helper knows how to load, so a stale stored repo
    /// falls back to the default instead of failing the launch.
    var resolvedManagedSpeechModel: SpeechModelOption {
        SpeechModelCatalog.option(forRepoID: managedSpeechModel.trimmed)
            ?? SpeechModelCatalog.defaultOption
    }
}
