import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How much audio one vLLM `/v1/realtime` session may take before the client
/// finishes it and carries the dictation on in a fresh one (#1139).
///
/// Voxtral Realtime spends one token per 80 ms step, so a session's context
/// grows with the take. Past the server's `max_model_len` the transcript
/// turns to garbage, and with prefix caching on (vLLM's default) the engine
/// dies on an assertion and cuts every session on the server with close code
/// 1012 (vllm-project/vllm#38428, closed upstream without a fix). At the
/// default 2048 that is about 164 s of audio.
package struct RealtimeContextBudget: Sendable, Equatable {
    /// Where the limit came from, for the log.
    package enum Source: String, Sendable, Equatable {
        /// `GET /v1/models` named it for the model.
        case reported
        /// `GET /v1/models` answered without one; `defaultMaxModelLen` stands in.
        case defaulted
    }

    /// One token per 80 ms step of audio.
    package static let secondsPerToken = 0.08
    /// vLLM's default `max_model_len` for Voxtral Realtime, used when the
    /// server lists the model without one.
    package static let defaultMaxModelLen = 2048
    /// From `pauseFraction` of the capacity on, a pause rolls the session over.
    package static let pauseFraction = 0.6
    /// At `forceFraction` of the capacity the session rolls over whatever is
    /// being said. The rest is margin for the prompt and the model's delay.
    package static let forceFraction = 0.85
    /// No transcript text for this long while audio flows counts as a pause:
    /// the model writes nothing over silence.
    package static let pauseQuietSeconds: TimeInterval = 0.8

    package let maxModelLen: Int
    package let source: Source

    package init(maxModelLen: Int, source: Source = .reported) {
        self.maxModelLen = max(1, maxModelLen)
        self.source = source
    }

    /// The PCM16 bytes whose tokens fill the whole context.
    package var capacityBytes: Int {
        Int(Double(maxModelLen) * Self.secondsPerToken * Double(AudioChunkBuffer.bytesPerSecond))
    }

    /// From here a pause rolls the session over.
    package var pauseWindowBytes: Int {
        Int(Double(capacityBytes) * Self.pauseFraction)
    }

    /// Here the session rolls over, pause or not.
    package var forceBytes: Int {
        Int(Double(capacityBytes) * Self.forceFraction)
    }

    package var forceSeconds: Double {
        Double(forceBytes) / Double(AudioChunkBuffer.bytesPerSecond)
    }
}

/// Reads a realtime server's context limit from `GET /v1/models`, which vLLM
/// answers with a `max_model_len` on each model (#1139).
package enum RealtimeContextLimitProbe {
    package typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// `ws://host:port/v1/realtime` → `http://host:port/v1/models`. A path
    /// that does not end in `realtime` gets `/v1/models` at the root.
    package static func modelsURL(forRealtimeEndpoint endpoint: URL) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        case "http", "https": break
        default: return nil
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/realtime") {
            path = String(path.dropLast("realtime".count)) + "models"
        } else {
            path = "/v1/models"
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The limit `body` reports for `model`: the entry whose `id` is the
    /// model, else the first entry. Nil when `body` is no model list, which
    /// is a server this does not apply to. A listed model without a usable
    /// `max_model_len` gets the default.
    package static func budget(fromModelsResponse body: Data, model: String) -> RealtimeContextBudget? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let entries = json["data"] as? [[String: Any]],
              !entries.isEmpty
        else { return nil }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = entries.first { ($0["id"] as? String) == trimmed } ?? entries[0]
        if let limit = (entry["max_model_len"] as? NSNumber)?.intValue, limit > 0 {
            return RealtimeContextBudget(maxModelLen: limit, source: .reported)
        }
        return RealtimeContextBudget(maxModelLen: RealtimeContextBudget.defaultMaxModelLen, source: .defaulted)
    }

    /// The budget for `configuration`'s server, or nil when it lists no
    /// models (not vLLM, or unreachable). Logs the outcome either way.
    package static func budget(
        for configuration: RealtimeSessionConfiguration,
        fetch: Fetch = { try await URLSession.shared.data(for: $0) }
    ) async -> RealtimeContextBudget? {
        guard let url = modelsURL(forRealtimeEndpoint: configuration.endpoint) else {
            Log.backends.error("realtime context limit: no models URL for the realtime endpoint; no rollover")
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: Data
        do {
            let (data, response) = try await fetch(request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                Log.backends.notice(
                    "realtime context limit: GET /v1/models answered \(http.statusCode, privacy: .public); no rollover"
                )
                return nil
            }
            body = data
        } catch {
            Log.backends.notice(
                "realtime context limit: GET /v1/models failed (\(error.localizedDescription, privacy: .public)); no rollover"
            )
            return nil
        }
        guard let budget = budget(fromModelsResponse: body, model: configuration.model) else {
            Log.backends.notice("realtime context limit: /v1/models listed no models; no rollover")
            return nil
        }
        Log.backends.notice(
            "realtime context limit: max_model_len \(budget.maxModelLen, privacy: .public) (\(budget.source.rawValue, privacy: .public)); sessions roll over by \(Int(budget.forceSeconds), privacy: .public)s of audio"
        )
        return budget
    }
}
