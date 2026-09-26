import Foundation
import Observation

/// The Inbox page's observable face (#725). The work is
/// `QuickCaptureInboxModel`'s, in the core so Linux tests reach it; this
/// wraps it for SwiftUI and builds its router and drafter from Settings.
@MainActor
@Observable
final class QuickCaptureInboxViewModel {
    private(set) var items: [QuickCaptureItem] = []
    @ObservationIgnored let model: QuickCaptureInboxModel

    init(
        settings: SettingsStore,
        learnedTerms: @escaping @MainActor () -> LearnedTerms,
        fileURL: URL?,
        applicationSupport: URL,
        github: any QuickCaptureGitHub = QuickCaptureGHClient()
    ) {
        let drafter = QuickCaptureDrafter(
            runner: QuickCaptureDraftProcessRunner(
                vibeHome: applicationSupport.appendingPathComponent("vibe-home", isDirectory: true),
                userVibeDirectory: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".vibe", isDirectory: true)
            ),
            openIssues: { await github.openIssues(ofCheckout: $0) }
        )
        model = QuickCaptureInboxModel(
            fileURL: fileURL,
            makeRouter: { QuickCaptureRouter(classifiers: Self.classifiers(settings: settings)) },
            projects: {
                QuickCaptureProjects.projects(
                    from: learnedTerms(),
                    userLines: [:],
                    readme: { QuickCaptureProjects.readme(atRoot: $0) }
                )
            },
            agents: { [.claude, .vibe] },
            drafter: { drafter },
            github: github
        )
        items = model.items
        model.onChange = { [weak self] in
            guard let self else { return }
            self.items = self.model.items
        }
    }

    static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("localvoxtral", isDirectory: true)
            .appendingPathComponent("quick-captures.json")
    }

    var waitingCount: Int { items.filter { $0.state != .filed }.count }

    /// Jev only when the user allowed it and a key is set; the polishing
    /// model next, when polishing has a configuration. With neither, every
    /// capture waits in the Inbox for the user to place it.
    static func classifiers(settings: SettingsStore) -> [any QuickCaptureClassifying] {
        var classifiers: [any QuickCaptureClassifying] = []
        if settings.quickCaptureJevEnabled { settings.ensureSecretsLoaded([.jevAPIKey]) }
        let jevKey = settings.jevAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.quickCaptureJevEnabled, !jevKey.isEmpty {
            classifiers.append(JevClassifier(host: jevHost(forKey: jevKey), apiKey: jevKey))
        }
        if let polishing = settings.llmPolishingConfiguration {
            classifiers.append(QuickCaptureChatClassifier(
                endpoint: LLMPolishingService.normalizedChatCompletionsURL(polishing.endpointURL),
                apiKey: polishing.apiKey,
                model: polishing.model,
                extraBody: chatExtraBody(polishing)
            ))
        }
        return classifiers
    }

    /// Vercel AI Gateway keys start `vck_`; any other key is TypeSafe's.
    static func jevHost(forKey key: String) -> Jev.Host {
        key.hasPrefix("vck_") ? .vercelGateway : .typesafe
    }

    /// The fields the polish request adds that change whether a reasoning
    /// model answers quickly: the Mistral shape's reasoning effort, or a
    /// self-hosted server's chat template switches and thinking budget.
    static func chatExtraBody(_ configuration: LLMPolishingConfiguration) -> [String: any Sendable] {
        if configuration.requestShape == .mistral {
            let effort = configuration.mistralReasoningEffort ?? MistralReasoningEffort.forModel(configuration.model)
            guard let wireValue = effort.wireValue else { return [:] }
            return ["reasoning_effort": wireValue]
        }
        var extra: [String: any Sendable] = [:]
        if let arguments = configuration.chatTemplateArguments { extra["chat_template_kwargs"] = arguments }
        if let budget = configuration.thinkingBudgetTokens { extra["thinking_budget_tokens"] = budget }
        return extra
    }
}
