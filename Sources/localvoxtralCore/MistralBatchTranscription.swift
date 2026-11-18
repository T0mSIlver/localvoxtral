import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Mistral's batch transcription endpoint (`POST /v1/audio/transcriptions`),
/// used for the second pass an Overlay Buffer dictation gets on stop in
/// Mistral API mode (#317) and for the stall backfill: the model takes up to
/// 100 `context_bias` terms.
///
/// The model is Voxtral Mini Transcribe 3 (`voxtral-mini-transcribe-3-0`).
/// Mistral deprecated the 2602 batch model (`voxtral-mini-2602`, alias
/// `voxtral-mini-latest`) on 2026-10-31 and retires it on 2027-04-30.
/// Measured on the live API (2026-11-04), not in the docs: Transcribe 3 takes
/// phrases with spaces and items with commas, and writes a listed identifier
/// as listed ("OverlayBufferStateMachine"). The 2602 model refused both with
/// a 400, which is why terms used to go out joined with `_`.
package enum MistralBatchTranscription {
    package static let model = "voxtral-mini-transcribe-3-0"
    package static let maxContextBiasTerms = 100
    /// The batch model takes terms the way Voxtral Realtime 3 does at start.
    package static let capabilities = DictationModelCapabilities(
        termBias: .sessionList(maxTerms: maxContextBiasTerms))

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

    /// The `context_bias` list: candidates in priority order, whitespace runs
    /// collapsed to one space, duplicates dropped by a case-insensitive key
    /// keeping the first spelling, cut at 100.
    package static func contextBias(from candidates: [String]) -> [String] {
        capabilities.sessionTerms(from: candidates)
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

extension MistralBatchTranscription {
    /// How much of a request body went out and how long it took, from the
    /// request's start to the last body bytes handed to the network. A
    /// request cancelled mid-upload still measures what it sent.
    package struct UploadMeasurement: Equatable, Sendable {
        package let bytes: Int64
        package let seconds: Double

        package init(bytes: Int64, seconds: Double) {
            self.bytes = bytes
            self.seconds = seconds
        }

        /// Below this the bytes sit in the socket's send buffer and say
        /// nothing about the link.
        package static let minimumBytes: Int64 = 256 * 1024

        /// Nil when too little went out to measure.
        package var bytesPerSecond: Double? {
            guard bytes >= Self.minimumBytes, seconds > 0 else { return nil }
            return Double(bytes) / seconds
        }
    }
}

/// Sends one batch transcription. The seam the stop-commit is tested through.
package protocol MistralBatchTranscribing: Sendable {
    /// `onUpload` gets the upload's measurement once the request ends,
    /// whether it answered, failed or was cancelled, when it sent anything.
    /// It may come after `transcribe` returns.
    func transcribe(
        wav: Data,
        language: String?,
        contextBias: [String],
        apiKey: String,
        endpoint: URL,
        onUpload: @escaping @Sendable (MistralBatchTranscription.UploadMeasurement) -> Void
    ) async throws -> MistralBatchTranscription.Result
}

extension MistralBatchTranscribing {
    package func transcribe(
        wav: Data,
        language: String?,
        contextBias: [String],
        apiKey: String,
        endpoint: URL
    ) async throws -> MistralBatchTranscription.Result {
        try await transcribe(
            wav: wav, language: language, contextBias: contextBias, apiKey: apiKey,
            endpoint: endpoint, onUpload: { _ in })
    }
}

package struct MistralBatchTranscriptionClient: MistralBatchTranscribing {
    /// A backstop only: the stop-commit's deadline gives up long before this,
    /// and cancels the request when it does.
    package static let requestTimeout: TimeInterval = 120

    private let session: URLSession

    package init(session: URLSession = SameOriginHTTP.shared) {
        self.session = session
    }

    package func transcribe(
        wav: Data,
        language: String?,
        contextBias: [String],
        apiKey: String,
        endpoint: URL,
        onUpload: @escaping @Sendable (MistralBatchTranscription.UploadMeasurement) -> Void
    ) async throws -> MistralBatchTranscription.Result {
        let request = MistralBatchTranscription.request(
            endpoint: endpoint,
            apiKey: apiKey,
            wav: wav,
            language: language,
            contextBias: contextBias,
            timeout: Self.requestTimeout
        )
        let meter = UploadMeter()
        // Read on the session's delegate queue, which is serial for a session
        // made with none (SameOriginHTTP): the progress callbacks the upload
        // queued there run first. `data(for:delegate:)` can return before
        // they have run, and the meter read here would find nothing (LVX-20).
        defer {
            session.delegateQueue.addOperation {
                if let measurement = meter.measurement() { onUpload(measurement) }
            }
        }
        #if canImport(FoundationNetworking)
        let (data, response) = try await session.data(for: request)
        #else
        // A task delegate for the progress only: it implements no redirect
        // method, so redirects still reach the session's `RedirectGate`.
        let (data, response) = try await session.data(for: request, delegate: meter)
        #endif
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try MistralBatchTranscription.result(status: status, body: data)
    }
}

/// Times the body's upload from the meter's creation, just before the
/// request starts, to the last progress callback.
private final class UploadMeter: NSObject, URLSessionTaskDelegate, Sendable {
    private let start = ContinuousClock.now
    private let sent = Mutex<(bytes: Int64, at: ContinuousClock.Instant)?>(nil)

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let now = ContinuousClock.now
        sent.withLock { $0 = (totalBytesSent, now) }
    }

    func measurement() -> MistralBatchTranscription.UploadMeasurement? {
        guard let sent = sent.withLock({ $0 }), sent.bytes > 0 else { return nil }
        let elapsed = sent.at - start
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        return MistralBatchTranscription.UploadMeasurement(bytes: sent.bytes, seconds: seconds)
    }
}
