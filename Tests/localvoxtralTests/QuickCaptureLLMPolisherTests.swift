import Foundation
import XCTest
@testable import localvoxtral
import localvoxtralTestSupport

/// #970: the capture's polish is a standard-profile polish request with the
/// Inbox's vocabulary, and History gets its words on the capture's record.
@MainActor
final class QuickCaptureLLMPolisherTests: XCTestCase {
    private let raw = "put slash reload plugins in the local Voxroll docs"

    private func configuredSettings() -> SettingsStore {
        let settings = makeSettings()
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = .mistralAPI
        settings.mistralAPIKey = "mk-test"
        settings.polishSpeakerTerms = ["Qwen"]
        return settings
    }

    private let config = MockAppConfigStore(
        replacementDictionary: ReplacementDictionary(entries: [
            ReplacementEntry(replaceWith: "/reload-plugins", matches: ["slash reload plugins"]),
        ]),
        promptTemplates: LLMPromptTemplates(
            systemContent: "You polish dictated text.",
            userContent: "{{replacement_dictionary}}\n\n{{input_text}}"
        ),
        agentPromptTemplates: LLMPromptTemplates(systemContent: "agent", userContent: "{{input_text}}")
    )

    func testThePolishIsAStandardRequestWithTheVocabularyAndTheUsersTerms() async throws {
        let settings = configuredSettings()
        settings.replacementDictionaryEnabled = true
        let service = FakePolishingService(returning: "Put /reload-plugins in the localvoxtral docs.", durationSeconds: 0.8)
        let polisher = QuickCaptureLLMPolisher(settings: settings, appConfigStore: { self.config }, service: { service })

        let result = await polisher.polish(raw, vocabulary: ["localvoxtral", "reach"])

        XCTAssertEqual(result, QuickCapturePolish(text: "Put /reload-plugins in the localvoxtral docs.", durationSeconds: 0.8))
        let last = await service.lastRequest
        let request = try XCTUnwrap(last)
        XCTAssertEqual(
            request.systemPrompt,
            StopCommitCoordinator.promptTemplates(profile: .standard, settings: settings, appConfigStore: config).systemContent
        )
        XCTAssertTrue(request.systemPrompt.contains("Names and terms they use: Qwen"))
        XCTAssertEqual(request.inputText, "put /reload-plugins in the local Voxroll docs", "the replacement rules ran first")
        let user = request.userPrompts.joined(separator: "\n")
        XCTAssertTrue(user.contains("\(RepoVocabularyMatcher.verificationCandidatesHeader)\n- localvoxtral"))
        XCTAssertFalse(user.contains("reach"), "a term the words do not match is not sent")
        XCTAssertTrue(user.hasSuffix(request.inputText))
        XCTAssertEqual(request.usageFeature, .quickCapturePolish)
    }

    func testAFailedRequestOrNoConfigurationGivesNothing() async throws {
        let failing = FakePolishingService(failing: URLError(.timedOut))
        let settings = configuredSettings()
        let polisher = QuickCaptureLLMPolisher(settings: settings, appConfigStore: { self.config }, service: { failing })
        XCTAssertTrue(polisher.isConfigured)
        let failed = await polisher.polish(raw, vocabulary: [])
        XCTAssertNil(failed)

        settings.llmPolishingEnabled = false
        let unused = FakePolishingService()
        let off = QuickCaptureLLMPolisher(settings: settings, appConfigStore: { self.config }, service: { unused })
        XCTAssertFalse(off.isConfigured)
        let none = await off.polish(raw, vocabulary: [])
        XCTAssertNil(none)
        let sent = await unused.requests
        XCTAssertTrue(sent.isEmpty)
    }

    func testHistoryKeepsTheRawWordsAndGetsThePolishedOnes() async throws {
        let store = try XCTUnwrap(DictationSessionStore(inMemory: true))
        let id = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store.save(DictationSessionRecord(
            id: id, startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(4), rawText: raw,
            provider: "mistral", model: "voxtral", outputMode: DictationSessionRecord.quickCaptureOutputMode,
            targetAppBundleID: nil, status: .sttCompleted, commitSucceeded: true
        ))

        await store.setQuickCapturePolish("Put /reload-plugins in the localvoxtral docs.", seconds: 0.8, id: id).value

        let entries = await store.entries()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.rawText, raw)
        XCTAssertEqual(entry.finalText, "Put /reload-plugins in the localvoxtral docs.")
        XCTAssertTrue(entry.polishRan)
    }
}
