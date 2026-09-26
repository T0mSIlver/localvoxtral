import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Mistral's batch transcription endpoint (`POST /v1/audio/transcriptions`),
/// used for the second pass an Overlay Buffer dictation gets on stop in
/// Mistral API mode (#317): the realtime model takes no vocabulary, the batch
/// model takes up to 100 `context_bias` terms.
///
/// Docs: `context_bias` is an array of strings on the multipart request, at
/// most 100 "words or phrases", optimized for English
/// (docs.mistral.ai/studio/audio/speech_to_text/offline_transcription,
/// "Context biasing"). Measured on the live API (2026-09-26), not in the docs:
/// an item holding whitespace or a comma is a 400 ("must not contain commas or
/// whitespace"), and a phrase joined with `_` comes back spelled with spaces.
package enum MistralBatchTranscription {
    /// Voxtral Mini Transcribe 2, the one model the endpoint serves.
    package static let model = "voxtral-mini-latest"
    package static let maxContextBiasTerms = 100

    // MARK: - Endpoint

    /// The batch endpoint on the host the realtime socket dialed, so the key
    /// goes nowhere the session did not already send it:
    /// `wss://host/v1/audio/transcriptions/realtime` becomes
    /// `https://host/v1/audio/transcriptions`. Nil for any other shape.
    package static func endpoint(forRealtimeEndpoint realtime: URL) -> URL? {
        guard var components = URLComponents(url: realtime, resolvingAgainstBaseURL: false)
        else { return nil }
        switch components.scheme?.lowercased() {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        default: return nil
        }
        let suffix = "/realtime"
        guard components.path.hasSuffix(suffix) else { return nil }
        components.path = String(components.path.dropLast(suffix.count))
        components.query = nil
        return components.url
    }

    // MARK: - Terms

    /// The `context_bias` list: candidates in priority order, each made
    /// acceptable to the API (whitespace runs become `_`; an item with a comma
    /// is dropped, since no joiner keeps its meaning), duplicates dropped by a
    /// case-insensitive key keeping the first spelling, and cut at 100.
    package static func contextBias(from candidates: [String]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for candidate in candidates {
            let words = candidate.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            guard !words.isEmpty else { continue }
            let term = words.joined(separator: "_")
            guard !term.contains(",") else { continue }
            guard seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == maxContextBiasTerms { break }
        }
        return terms
    }

    /// The answer with every phrase `contextBias` joined put back as it was
    /// listed: the model writes about half of them as sent ("Claude_Code"),
    /// the rest with spaces (measured 2026-09-26 on the term-recall set: 22
    /// joined, 21 spaced). A term that held `_` itself is left alone.
    package static func restoringPhrases(in text: String, candidates: [String]) -> String {
        let sent = Set(contextBias(from: candidates))
        var result = text
        for candidate in candidates {
            let words = candidate.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            guard words.count > 1 else { continue }
            let joined = words.joined(separator: "_")
            guard sent.contains(joined) else { continue }
            let pattern = "(?<![\\p{L}\\p{N}_])"
                + NSRegularExpression.escapedPattern(for: joined)
                + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: words.joined(separator: " "))
            )
        }
        return result
    }

    // MARK: - Request

    /// The multipart body: the WAV as `file`, then `model`, `language` when
    /// known, and one `context_bias` field per term (the API takes the array
    /// as repeated fields, as in the docs' curl sample).
    package static func multipartBody(
        wav: Data,
        language: String?,
        contextBias: [String],
        boundary: String
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: Array(string.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n")
        field("model", model)
        if let language, !language.isEmpty {
            field("language", language)
        }
        for term in contextBias {
            field("context_bias", term)
        }
        append("--\(boundary)--\r\n")
        return body
    }

    package static func request(
        endpoint: URL,
        apiKey: String,
        wav: Data,
        language: String?,
        contextBias: [String],
        boundary: String = "localvoxtral-\(UUID().uuidString)",
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            wav: wav, language: language, contextBias: contextBias, boundary: boundary)
        return request
    }

    // MARK: - Response

    package struct Result: Equatable, Sendable {
        package let text: String
        package init(text: String) { self.text = text }
    }

    package enum Failure: Error, Equatable, Sendable {
        /// A non-2xx answer; `message` is the API's own when it gave one.
        case http(status: Int, message: String?)
        case malformedResponse
    }

    /// The `text` of a 2xx answer; the error's message otherwise.
    package static func result(status: Int, body: Data) throws -> Result {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = (json?["message"] as? String)
                ?? ((json?["detail"] as? [String: Any])?["message"] as? String)
            throw Failure.http(status: status, message: message)
        }
        guard let text = json?["text"] as? String else { throw Failure.malformedResponse }
        return Result(text: text)
    }
}

/// Sends one batch transcription. The seam the stop-commit is tested through.
package protocol MistralBatchTranscribing: Sendable {
    func transcribe(
        wav: Data,
        language: String?,
        contextBias: [String],
        apiKey: String,
        endpoint: URL
    ) async throws -> MistralBatchTranscription.Result
}

package struct MistralBatchTranscriptionClient: MistralBatchTranscribing {
    /// A backstop only: the stop-commit's deadline gives up long before this,
    /// and cancels the request when it does.
    package static let requestTimeout: TimeInterval = 120

    private let session: URLSession

    package init(session: URLSession = .shared) {
        self.session = session
    }

    package func transcribe(
        wav: Data,
        language: String?,
        contextBias: [String],
        apiKey: String,
        endpoint: URL
    ) async throws -> MistralBatchTranscription.Result {
        let request = MistralBatchTranscription.request(
            endpoint: endpoint,
            apiKey: apiKey,
            wav: wav,
            language: language,
            contextBias: contextBias,
            timeout: Self.requestTimeout
        )
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try MistralBatchTranscription.result(status: status, body: data)
    }
}
