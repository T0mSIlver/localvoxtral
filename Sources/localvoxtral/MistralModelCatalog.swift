import Foundation

/// One model Mistral serves to this key, as `GET /v1/models` describes it.
/// Mistral lists every alias as its own entry (`zai-glm-5-3`, `zai-glm-5`,
/// `zai-glm-latest` are three rows with the same `name`); this is the group,
/// so a picker shows each model once.
struct MistralModel: Codable, Equatable, Sendable, Identifiable {
    /// The group's canonical id (`name` in the listing).
    let id: String
    /// Every id that reaches this model, `id` included.
    let ids: [String]
    let supportsChat: Bool
    let supportsRealtimeTranscription: Bool
    let supportsReasoning: Bool
    let isDeprecated: Bool

    func answers(to modelID: String) -> Bool {
        ids.contains(modelID)
    }
}

/// What a Mistral polish request says about reasoning. Mistral answers 400 for
/// a value the model does not take, so this is per model, not a constant:
/// measured 2026-09-18 against the live API.
enum MistralReasoningEffort: String, Sendable {
    /// `"none"`: reasoning switched off — Mistral's own reasoning models.
    case off
    /// GLM rejects `none` (it takes `low`/`high`/`max`) and reasons at length
    /// when the field is absent; `low` answers a short polish with no trace.
    case low
    /// The field is not sent: a model without reasoning rejects it outright
    /// ("reasoning_effort is not enabled for this model").
    case omitted
    /// For work nobody is waiting on (term suggestions). `/v1/models` only
    /// says WHETHER a model reasons, not which levels it takes, but `"high"`
    /// is the one value every reasoning model accepted (live API, 2026-09-19:
    /// GLM takes low/high/max, Mistral's own models none/high) — one below
    /// the top on GLM, the top elsewhere, and no per-model table.
    case high

    var wireValue: String? {
        switch self {
        case .off: return "none"
        case .low: return "low"
        case .omitted: return nil
        case .high: return "high"
        }
    }

    /// The effort for `modelID`. The catalog says whether the model reasons at
    /// all; without it (no key yet, the eval harness) every model is assumed
    /// to, which is what the default model does.
    static func forModel(_ modelID: String, catalog: [MistralModel] = []) -> Self {
        if let model = catalog.first(where: { $0.answers(to: modelID) }),
            !model.supportsReasoning
        {
            return .omitted
        }
        return MistralModelCatalog.isGLM(modelID) ? .low : .off
    }
}

extension MistralReasoningEffort {
    /// The effort for a request that asked to think hard: `high` wherever the
    /// polish effort says the model reasons at all.
    var deepened: Self { self == .omitted ? .omitted : .high }
}

/// One row of a Mistral model picker. `tag` is what Settings stores: empty for
/// the pinned default, so a user on the default follows it when the pin moves.
struct MistralModelPickerEntry: Equatable, Identifiable, Sendable {
    let tag: String
    let label: String
    let section: MistralModelCatalog.Section

    var id: String { tag }
}

enum MistralModelCatalog {
    enum Section: String, CaseIterable, Sendable {
        case mistral = "Mistral"
        case zai = "Z.ai"
    }

    enum Purpose: Sendable {
        case dictation
        case polishing
    }

    static func isGLM(_ modelID: String) -> Bool {
        let tokens = modelID.lowercased().split(separator: "-")
        return tokens.contains("glm")
    }

    // MARK: Parsing

    private struct ListResponse: Decodable {
        struct Entry: Decodable {
            struct Capabilities: Decodable {
                let completionChat: Bool?
                let audioTranscriptionRealtime: Bool?
                let reasoning: Bool?

                enum CodingKeys: String, CodingKey {
                    case completionChat = "completion_chat"
                    case audioTranscriptionRealtime = "audio_transcription_realtime"
                    case reasoning
                }
            }

            let id: String
            let name: String?
            let capabilities: Capabilities?
            let deprecation: String?
        }

        let data: [Entry]
    }

    /// `GET /v1/models` → one `MistralModel` per `name`, in the order the
    /// listing first mentions each.
    static func models(fromListResponse data: Data) throws -> [MistralModel] {
        let entries = try JSONDecoder().decode(ListResponse.self, from: data).data
        var order: [String] = []
        var groups: [String: [ListResponse.Entry]] = [:]
        for entry in entries {
            let name = entry.name?.trimmed.isEmpty == false ? entry.name!.trimmed : entry.id
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(entry)
        }
        return order.compactMap { name in
            guard let members = groups[name], let first = members.first else { return nil }
            var ids = members.map(\.id)
            if !ids.contains(name) { ids.insert(name, at: 0) }
            return MistralModel(
                id: name,
                ids: ids,
                supportsChat: first.capabilities?.completionChat ?? false,
                supportsRealtimeTranscription:
                    first.capabilities?.audioTranscriptionRealtime ?? false,
                supportsReasoning: first.capabilities?.reasoning ?? false,
                isDeprecated: first.deprecation != nil
            )
        }
    }

    // MARK: Picker

    /// The picker rows for one engine: the default first, then every other
    /// model that can do the job, one row per model. A stored id the catalog
    /// does not know (an env override, a model retired since, a catalog not
    /// fetched yet) keeps its own row rather than silently reading as another.
    static func pickerEntries(
        for purpose: Purpose,
        catalog: [MistralModel],
        storedModel: String,
        defaultModel: String
    ) -> [MistralModelPickerEntry] {
        let candidates = catalog.filter { model in
            guard !model.isDeprecated else { return false }
            switch purpose {
            case .dictation: return model.supportsRealtimeTranscription
            case .polishing: return model.supportsChat
            }
        }
        let defaultGroup = candidates.first { $0.answers(to: defaultModel) }

        var entries = [
            MistralModelPickerEntry(
                tag: "",
                label: "\(displayName(for: defaultModel)) (default)",
                section: section(for: defaultModel)
            )
        ]
        let others = candidates
            .filter { $0.id != defaultGroup?.id }
            .map { model in
                MistralModelPickerEntry(
                    tag: model.id,
                    label: displayName(for: model.id),
                    section: section(for: model.id)
                )
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        entries += others

        let selected = selectionTag(
            storedModel: storedModel, catalog: catalog, defaultModel: defaultModel
        )
        if !entries.contains(where: { $0.tag == selected }) {
            entries.append(
                MistralModelPickerEntry(
                    tag: selected,
                    label: displayName(for: selected),
                    section: section(for: selected)
                )
            )
        }
        return entries
    }

    /// The row a stored id selects: an alias selects its model's row, and
    /// anything that reaches the default selects the default row.
    static func selectionTag(
        storedModel: String,
        catalog: [MistralModel],
        defaultModel: String
    ) -> String {
        let stored = storedModel.trimmed
        guard !stored.isEmpty, stored != defaultModel else { return "" }
        guard let model = catalog.first(where: { $0.answers(to: stored) }) else {
            return stored
        }
        return model.answers(to: defaultModel) ? "" : model.id
    }

    static func section(for modelID: String) -> Section {
        let lowered = modelID.lowercased()
        return isGLM(lowered) || lowered.hasPrefix("zai-") ? .zai : .mistral
    }

    /// A readable name from a model id: `mistral-medium-3-5` → "Mistral
    /// Medium 3.5", `zai-glm-5-3` → "GLM 5.3" (the section says Z.ai),
    /// `ministral-8b-2512` → "Ministral 8B 25.12". Derived rather than
    /// looked up, so a model Mistral adds tomorrow gets a sensible row too.
    static func displayName(for modelID: String) -> String {
        let tokens = modelID.split(separator: "-").map(String.init)
        var words: [String] = []
        var versionParts: [String] = []

        func flushVersion() {
            guard !versionParts.isEmpty else { return }
            words.append(versionParts.joined(separator: "."))
            versionParts.removeAll()
        }

        for token in tokens {
            let lowered = token.lowercased()
            if lowered.allSatisfy(\.isNumber), lowered.count <= 2 {
                versionParts.append(lowered)
                continue
            }
            flushVersion()
            if lowered.allSatisfy(\.isNumber), lowered.count == 4 {
                // Mistral's yymm release stamp, written the way its docs do.
                words.append("\(lowered.prefix(2)).\(lowered.suffix(2))")
            } else if lowered == "zai" {
                continue
            } else if let special = specialWords[lowered] {
                words.append(special)
            } else if lowered.last == "b", lowered.dropLast().allSatisfy(\.isNumber),
                lowered.count > 1
            {
                words.append(lowered.dropLast() + "B")
            } else {
                words.append(lowered.prefix(1).uppercased() + lowered.dropFirst())
            }
        }
        flushVersion()
        return words.isEmpty ? modelID : words.joined(separator: " ")
    }

    private static let specialWords = [
        "glm": "GLM",
        "ocr": "OCR",
        "tts": "TTS",
        "fim": "FIM",
        "latest": "(latest)",
    ]
}

/// Loading the model list. Injected so Settings, previews and the unit suite
/// share one seam and only production ever opens a socket.
protocol MistralModelListing: Sendable {
    func listModels(apiKey: String) async -> MistralModelListResult
}

enum MistralModelListResult: Equatable, Sendable {
    case loaded([MistralModel])
    case rejected(statusCode: Int)
    case failed(String)
}

/// Production listing: the same authenticated `GET /v1/models` the key check
/// uses, this time reading the body.
struct MistralModelLister: MistralModelListing {
    func listModels(apiKey: String) async -> MistralModelListResult {
        let trimmed = apiKey.trimmed
        guard !trimmed.isEmpty else { return .failed("Enter an API key first.") }

        var request = URLRequest(url: MistralAPIKeyVerifier.modelsEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = MistralAPIKeyVerifier.timeoutInterval
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        Log.backends.info("mistral model list requested")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Log.backends.error(
                "mistral model list failed: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            Log.backends.error("mistral model list got a non-HTTP response")
            return .failed("Mistral sent an unexpected response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            Log.backends.error(
                "mistral model list failed status=\(httpResponse.statusCode, privacy: .public)"
            )
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .rejected(statusCode: httpResponse.statusCode)
            }
            return .failed("Mistral returned HTTP \(httpResponse.statusCode).")
        }
        do {
            let models = try MistralModelCatalog.models(fromListResponse: data)
            Log.backends.info("mistral model list completed models=\(models.count, privacy: .public)")
            return .loaded(models)
        } catch {
            Log.backends.error(
                "mistral model list unreadable: \(error.localizedDescription, privacy: .public)"
            )
            return .failed("Mistral sent a model list this version cannot read.")
        }
    }
}

/// UI state of the model list, for the picker rows' one-line status.
enum MistralModelListState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(MistralModelListResult)

    var statusLine: String? {
        switch self {
        case .idle, .loaded:
            return nil
        case .loading:
            return "Loading models…"
        case .failed(.rejected):
            return "Key rejected"
        case .failed:
            return "Could not load models"
        }
    }

    var isLoading: Bool { self == .loading }
}
