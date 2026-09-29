import Foundation

/// A quick capture's one polish (#970): the request
/// `QuickCapturePolishPrompt.request` builds from Settings and the config
/// files, sent through `LLMPolishingService` with the user's polishing
/// configuration. No screen, clipboard or session context: the capture goes
/// to no app.
@MainActor
final class QuickCaptureLLMPolisher: QuickCapturePolishing {
    private let settings: SettingsStore
    private let appConfigStore: @MainActor () -> any AppConfigServing
    private let service: @MainActor () -> any LLMPolishingServicing

    init(
        settings: SettingsStore,
        appConfigStore: @escaping @MainActor () -> any AppConfigServing,
        service: @escaping @MainActor () -> any LLMPolishingServicing
    ) {
        self.settings = settings
        self.appConfigStore = appConfigStore
        self.service = service
    }

    /// Polishing is on and configured. Off, a capture routes its raw words
    /// without waiting.
    var isConfigured: Bool { settings.llmPolishingConfiguration != nil }

    /// What Settings and the config files give the request: the standard
    /// profile, as a capture goes to no terminal.
    static func inputs(settings: SettingsStore, appConfigStore: any AppConfigServing) -> QuickCapturePolishInputs {
        QuickCapturePolishInputs(
            templates: appConfigStore.loadLLMPromptTemplates(profile: .standard),
            speakerProfile: settings.polishSpeakerProfile,
            speakerTerms: settings.polishSpeakerTerms,
            replacementDictionary: settings.replacementDictionaryEnabled
                ? appConfigStore.loadReplacementDictionary() : nil
        )
    }

    /// The request as the app sends it.
    static func request(_ built: QuickCapturePolishRequest) -> LLMPolishingRequest {
        LLMPolishingRequest(
            inputText: built.inputText,
            systemPrompt: built.systemPrompt,
            userPrompts: built.userPrompts,
            usageFeature: .quickCapturePolish
        )
    }

    func polish(_ text: String, vocabulary: [String]) async -> QuickCapturePolish? {
        guard let configuration = settings.llmPolishingConfiguration else { return nil }
        let inputs = Self.inputs(settings: settings, appConfigStore: appConfigStore())
        let built = await Task.detached(priority: .userInitiated) {
            QuickCapturePolishPrompt.request(transcript: text, vocabulary: vocabulary, inputs: inputs)
        }.value
        do {
            let result = try await service().polish(request: Self.request(built), configuration: configuration)
            Log.polishing.info(
                "Quick capture polish: done in \(String(format: "%.2f", result.durationSeconds), privacy: .public) s, \(vocabulary.count, privacy: .public) terms offered"
            )
            return QuickCapturePolish(text: result.polishedText, durationSeconds: result.durationSeconds)
        } catch {
            Log.polishing.error(
                "Quick capture polish failed, routing the raw words: \(LLMPolishingError.publicLogDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }
}
