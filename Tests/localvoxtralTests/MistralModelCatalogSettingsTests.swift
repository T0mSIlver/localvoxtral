import Foundation
import XCTest
import localvoxtralTestSupport
@testable import localvoxtral

/// The Mistral catalog as Settings keeps and uses it; the catalog itself is
/// tested in the core suite (`MistralModelCatalogTests`).
final class MistralModelCatalogSettingsTests: XCTestCase {
    private static let listing = """
        {"object": "list", "data": [
          \(entry("mistral-medium-latest", name: "mistral-medium-latest", chat: true, reasoning: true)),
          \(entry("mistral-medium-3-5", name: "mistral-medium-latest", chat: true, reasoning: true)),
          \(entry("mistral-medium-2604", name: "mistral-medium-latest", chat: true, reasoning: true)),
          \(entry("zai-glm-5-3", name: "zai-glm-5-3", chat: true, reasoning: true)),
          \(entry("zai-glm-5", name: "zai-glm-5-3", chat: true, reasoning: true)),
          \(entry("zai-glm-latest", name: "zai-glm-5-3", chat: true, reasoning: true)),
          \(entry("glm-5-2", name: "glm-5-2", chat: true, reasoning: true)),
          \(entry("zai-glm-5-2", name: "glm-5-2", chat: true, reasoning: true)),
          \(entry("ministral-8b-2512", name: "ministral-8b-2512", chat: true)),
          \(entry("ministral-8b-latest", name: "ministral-8b-2512", chat: true)),
          \(entry("mistral-large-2411", name: "mistral-large-2411", chat: true, deprecation: "2026-11-30T12:00:00Z")),
          \(entry("mistral-ocr-2512", name: "mistral-ocr-2512")),
          \(entry("mistral-embed", name: "mistral-embed-2312")),
          \(entry("voxtral-mini-transcribe-realtime-2602", name: "voxtral-mini-transcribe-realtime-2602", realtime: true)),
          \(entry("voxtral-mini-realtime-latest", name: "voxtral-mini-transcribe-realtime-2602", realtime: true))
        ]}
        """

    private static func entry(
        _ id: String,
        name: String,
        chat: Bool = false,
        reasoning: Bool = false,
        realtime: Bool = false,
        deprecation: String? = nil
    ) -> String {
        let deprecationJSON = deprecation.map { "\"\($0)\"" } ?? "null"
        return """
            {"id": "\(id)", "object": "model", "name": "\(name)", "owned_by": "mistralai",
             "capabilities": {"completion_chat": \(chat), "reasoning": \(reasoning),
               "audio_transcription_realtime": \(realtime), "vision": false},
             "deprecation": \(deprecationJSON), "type": "base"}
            """
    }

    private func catalog() throws -> [MistralModel] {
        try MistralModelCatalog.models(fromListResponse: Data(Self.listing.utf8))
    }

    @MainActor
    func testSettingsPassTheCatalogsAnswerToThePolishRequest() throws {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = .mistralAPI
        settings.mistralAPIKey = "mk-mistral"
        settings.mistralModelCatalog = try catalog()

        settings.mistralPolishingModel = "ministral-8b-2512"
        XCTAssertEqual(settings.llmPolishingConfiguration?.mistralReasoningEffort, .omitted)

        settings.mistralPolishingModel = "zai-glm-5-3"
        XCTAssertEqual(settings.llmPolishingConfiguration?.mistralReasoningEffort, .low)

        // The list outlives the process: a relaunch offline still knows it.
        let relaunched = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        XCTAssertEqual(relaunched.mistralModelCatalog, settings.mistralModelCatalog)
    }
}
