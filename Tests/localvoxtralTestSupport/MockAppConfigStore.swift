import Foundation
import localvoxtralCore

/// Serves fixed config from memory so a session never reads the user's real
/// config directory. `agentPromptTemplates` defaults to `promptTemplates`.
package final class MockAppConfigStore: AppConfigServing {
    private let replacementDictionary: ReplacementDictionary
    private let promptTemplates: LLMPromptTemplates
    private let agentPromptTemplates: LLMPromptTemplates
    private let terminalAppBundleIDs: [String]
    private let configDirectory: URL

    package private(set) var loadReplacementDictionaryCallCount = 0
    package private(set) var loadLLMPromptTemplatesCallCount = 0
    package private(set) var requestedProfiles: [PolishPromptProfile] = []

    package init(
        replacementDictionary: ReplacementDictionary = ReplacementDictionary(entries: []),
        promptTemplates: LLMPromptTemplates = LLMPromptTemplates(
            systemContent: "system",
            userContent: "{{input_text}}"
        ),
        agentPromptTemplates: LLMPromptTemplates? = nil,
        terminalAppBundleIDs: [String] = [],
        configDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.replacementDictionary = replacementDictionary
        self.promptTemplates = promptTemplates
        self.agentPromptTemplates = agentPromptTemplates ?? promptTemplates
        self.terminalAppBundleIDs = terminalAppBundleIDs
        self.configDirectory = configDirectory
    }

    package func configDirectoryURL() -> URL {
        configDirectory
    }

    package func loadReplacementDictionary() -> ReplacementDictionary {
        loadReplacementDictionaryCallCount += 1
        return replacementDictionary
    }

    package func loadLLMPromptTemplates() -> LLMPromptTemplates {
        loadLLMPromptTemplatesCallCount += 1
        return promptTemplates
    }

    package func loadLLMPromptTemplates(profile: PolishPromptProfile) -> LLMPromptTemplates {
        loadLLMPromptTemplatesCallCount += 1
        requestedProfiles.append(profile)
        switch profile {
        case .standard:
            return promptTemplates
        case .agent:
            return agentPromptTemplates
        }
    }

    package func loadTerminalAppBundleIDs() -> [String] {
        terminalAppBundleIDs
    }
}
