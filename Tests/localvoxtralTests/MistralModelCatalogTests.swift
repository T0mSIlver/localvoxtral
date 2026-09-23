import Foundation
import XCTest

@testable import localvoxtral

/// The Mistral model pickers: `GET /v1/models` grouped into one row per model,
/// the rows each engine offers, and the per-model `reasoning_effort` a polish
/// request carries (a wrong one is a 400, measured against the live API
/// 2026-09-18).
final class MistralModelCatalogTests: XCTestCase {
    /// A cut of the live listing (2026-09-18): every alias is its own entry,
    /// grouped by `name`, and capabilities decide which engine may use it.
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

    // MARK: - Parsing

    func testAliasesCollapseIntoOneModelPerName() throws {
        let models = try catalog()

        XCTAssertEqual(
            models.map(\.id),
            [
                "mistral-medium-latest", "zai-glm-5-3", "glm-5-2", "ministral-8b-2512",
                "mistral-large-2411", "mistral-ocr-2512", "mistral-embed-2312",
                "voxtral-mini-transcribe-realtime-2602",
            ]
        )
        let glm = try XCTUnwrap(models.first { $0.id == "zai-glm-5-3" })
        XCTAssertEqual(glm.ids, ["zai-glm-5-3", "zai-glm-5", "zai-glm-latest"])
        XCTAssertTrue(glm.supportsChat)
        XCTAssertTrue(glm.supportsReasoning)
        XCTAssertFalse(glm.supportsRealtimeTranscription)
        // A group whose `name` is not itself listed still answers to it.
        let embed = try XCTUnwrap(models.first { $0.id == "mistral-embed-2312" })
        XCTAssertEqual(embed.ids, ["mistral-embed-2312", "mistral-embed"])
        XCTAssertTrue(try XCTUnwrap(models.first { $0.id == "mistral-large-2411" }).isDeprecated)
    }

    // MARK: - Picker rows

    func testPolishingPickerOffersGLM53AndEveryChatModelOnce() throws {
        let entries = MistralModelCatalog.pickerEntries(
            for: .polishing,
            catalog: try catalog(),
            storedModel: "",
            defaultModel: MistralPolishDefaults.model
        )

        XCTAssertEqual(
            entries,
            [
                MistralModelPickerEntry(
                    tag: "", label: "Mistral Medium 3.5 (default)", section: .mistral),
                MistralModelPickerEntry(tag: "glm-5-2", label: "GLM 5.2", section: .zai),
                MistralModelPickerEntry(tag: "zai-glm-5-3", label: "GLM 5.3", section: .zai),
                MistralModelPickerEntry(
                    tag: "ministral-8b-2512", label: "Ministral 8B 25.12", section: .mistral),
            ]
        )
    }

    func testDictationPickerOffersOnlyRealtimeTranscriptionModels() throws {
        let entries = MistralModelCatalog.pickerEntries(
            for: .dictation,
            catalog: try catalog(),
            storedModel: "",
            defaultModel: MistralRealtimeWebSocketClient.defaultModel
        )

        XCTAssertEqual(
            entries,
            [
                MistralModelPickerEntry(
                    tag: "",
                    label: "Voxtral Mini Transcribe Realtime 26.02 (default)",
                    section: .mistral
                )
            ]
        )
    }

    /// No key yet, or the fetch failed on first run: the default is still
    /// selectable, never an empty menu.
    func testAnEmptyCatalogStillOffersTheDefault() {
        let entries = MistralModelCatalog.pickerEntries(
            for: .polishing, catalog: [], storedModel: "", defaultModel: MistralPolishDefaults.model
        )

        XCTAssertEqual(entries.map(\.tag), [""])
    }

    func testAStoredAliasSelectsItsModelsRow() throws {
        let models = try catalog()

        XCTAssertEqual(
            MistralModelCatalog.selectionTag(
                storedModel: "zai-glm-latest", catalog: models,
                defaultModel: MistralPolishDefaults.model),
            "zai-glm-5-3"
        )
        // Any id that reaches the default is the default row.
        XCTAssertEqual(
            MistralModelCatalog.selectionTag(
                storedModel: "mistral-medium-latest", catalog: models,
                defaultModel: MistralPolishDefaults.model),
            ""
        )
        XCTAssertEqual(
            MistralModelCatalog.selectionTag(
                storedModel: "  ", catalog: models, defaultModel: MistralPolishDefaults.model),
            ""
        )
    }

    /// A model typed into the old text field (or set by env) that the list
    /// does not offer keeps its own row: the picker must not show another
    /// model selected while requests go to this one.
    func testAStoredModelTheListDoesNotOfferKeepsItsOwnRow() throws {
        let models = try catalog()
        for stored in ["my-fine-tune-2609", "mistral-large-2411", "mistral-ocr-2512"] {
            let entries = MistralModelCatalog.pickerEntries(
                for: .polishing, catalog: models, storedModel: stored,
                defaultModel: MistralPolishDefaults.model
            )
            let tag = MistralModelCatalog.selectionTag(
                storedModel: stored, catalog: models, defaultModel: MistralPolishDefaults.model
            )

            XCTAssertEqual(tag, stored)
            XCTAssertEqual(entries.filter { $0.tag == stored }.count, 1, stored)
        }
    }

    func testDisplayNames() {
        let cases = [
            "mistral-medium-3-5": "Mistral Medium 3.5",
            "zai-glm-5-3": "GLM 5.3",
            "glm-5-2": "GLM 5.2",
            "ministral-14b-2512": "Ministral 14B 25.12",
            "codestral-2508": "Codestral 25.08",
            "labs-leanstral-1-5-1": "Labs Leanstral 1.5.1",
            "mistral-small-latest": "Mistral Small (latest)",
            "voxtral-mini-transcribe-realtime-2602": "Voxtral Mini Transcribe Realtime 26.02",
        ]
        for (id, expected) in cases {
            XCTAssertEqual(MistralModelCatalog.displayName(for: id), expected, id)
        }
    }

    // MARK: - Reasoning effort

    func testReasoningEffortFollowsWhatEachModelAccepts() throws {
        let models = try catalog()

        // Mistral's reasoning models take "none".
        XCTAssertEqual(MistralReasoningEffort.forModel("mistral-medium-3-5", catalog: models), .off)
        // GLM rejects "none" (400: supported values low/high/max).
        XCTAssertEqual(MistralReasoningEffort.forModel("zai-glm-5-3", catalog: models), .low)
        XCTAssertEqual(MistralReasoningEffort.forModel("zai-glm-latest", catalog: models), .low)
        // A model without reasoning rejects the field itself.
        XCTAssertEqual(
            MistralReasoningEffort.forModel("ministral-8b-latest", catalog: models), .omitted)
        // No catalog (the eval harness, a key not yet listed): by id alone.
        XCTAssertEqual(MistralReasoningEffort.forModel("zai-glm-5-3"), .low)
        XCTAssertEqual(MistralReasoningEffort.forModel("mistral-medium-3-5"), .off)
    }

    func testPolishRequestForGLMSendsLowEffort() throws {
        let json = try requestJSON(model: "zai-glm-5-3", effort: nil)

        XCTAssertEqual(json["model"] as? String, "zai-glm-5-3")
        XCTAssertEqual(json["reasoning_effort"] as? String, "low")
    }

    func testPolishRequestForAModelWithoutReasoningOmitsTheField() throws {
        let json = try requestJSON(model: "ministral-8b-2512", effort: .omitted)

        XCTAssertEqual(Set(json.keys), ["model", "messages", "temperature", "prompt_cache_key"])
    }

    @MainActor
    func testSettingsPassTheCatalogsAnswerToThePolishRequest() throws {
        let suiteName = "localvoxtral.MistralModelCatalogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
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

    private func requestJSON(
        model: String, effort: MistralReasoningEffort?
    ) throws -> [String: Any] {
        let configuration = LLMPolishingConfiguration(
            endpointURL: MistralPolishDefaults.endpoint,
            apiKey: "secret",
            model: model,
            requestShape: .mistral,
            mistralReasoningEffort: effort
        )
        let request = LLMPolishingRequest(
            inputText: "hello", systemPrompt: "system", userPrompts: ["hello"]
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: LLMPolishingService.requestBody(
                    request: request, configuration: configuration)
            ) as? [String: Any]
        )
    }
}
