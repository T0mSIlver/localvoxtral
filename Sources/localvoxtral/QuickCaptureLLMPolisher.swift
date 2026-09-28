import Foundation

/// A quick capture's one polish (#970): the user's polishing configuration,
/// replacement rules and standard prompt, as a dictation's polish uses, with
/// the Inbox's vocabulary in the `{{replacement_dictionary}}` slot. No
/// screen, clipboard or session context: the capture goes to no app.
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

    func polish(_ text: String, vocabulary: [String]) async -> QuickCapturePolish? {
        guard let configuration = settings.llmPolishingConfiguration else { return nil }
        let appConfigStore = appConfigStore()
        let replaced = StopCommitCoordinator.effectiveReplacementDictionary(
            settings: settings, appConfigStore: appConfigStore
        )?.apply(to: text) ?? text
        let templates = StopCommitCoordinator.promptTemplates(
            profile: .standard, settings: settings, appConfigStore: appConfigStore
        )
        let rendersDictionary = templates.supportsReplacementDictionary
        let prepared = await Task.detached(priority: .userInitiated) {
            QuickCapturePolishPrompt.prepare(
                transcript: replaced, vocabulary: vocabulary, rendersDictionary: rendersDictionary
            )
        }.value
        let request = LLMPolishingRequest(
            inputText: prepared.workingText,
            systemPrompt: templates.systemContent,
            userPrompts: templates.renderedUserPrompts(
                inputText: prepared.workingText, replacementDictionary: prepared.dictionarySection
            ),
            usageFeature: .quickCapturePolish
        )
        do {
            let result = try await service().polish(request: request, configuration: configuration)
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
