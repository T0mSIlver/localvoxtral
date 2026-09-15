import Foundation

/// What asking Mistral about an API key came back with.
enum MistralAPIKeyVerification: Equatable, Sendable {
    /// Mistral answered the authenticated request.
    case accepted
    /// Mistral answered, but refused the key (401/403) or the request.
    case rejected(statusCode: Int)
    /// Nothing usable came back: offline, DNS, TLS, a timeout, or a Mistral-side
    /// error that says nothing about the key.
    case unreachable(String)
}

/// Checking an API key without dictating. Injected so Settings, the onboarding
/// wizard, previews and the unit suite share one seam and only production ever
/// opens a socket.
protocol MistralAPIKeyVerifying: Sendable {
    func verify(apiKey: String) async -> MistralAPIKeyVerification
}

/// Production check: an authenticated `GET /v1/models`. The cheapest endpoint
/// that distinguishes "this key works" from "this key does not" — it bills
/// nothing, needs no model, and its 401 is the same 401 a dictation would hit.
struct MistralAPIKeyVerifier: MistralAPIKeyVerifying {
    static let modelsEndpoint = URL(string: "https://api.mistral.ai/v1/models")!

    /// Short on purpose: this runs behind a button the user is watching, and a
    /// slow answer is an answer they can act on ("could not reach Mistral").
    static let timeoutInterval: TimeInterval = 10

    func verify(apiKey: String) async -> MistralAPIKeyVerification {
        let trimmed = apiKey.trimmed
        guard !trimmed.isEmpty else {
            return .unreachable("Enter an API key first.")
        }

        var request = URLRequest(url: Self.modelsEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutInterval
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        Log.backends.info("mistral api key check requested")

        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            Log.backends.error(
                "mistral api key check failed: \(error.localizedDescription, privacy: .public)"
            )
            return .unreachable(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Log.backends.error("mistral api key check got a non-HTTP response")
            return .unreachable("Mistral sent an unexpected response.")
        }

        let verification = Self.verification(forStatusCode: httpResponse.statusCode)
        Log.backends.info(
            "mistral api key check completed status=\(httpResponse.statusCode, privacy: .public)"
        )
        return verification
    }

    /// Status → verdict. A 429 or a 5xx says nothing about the KEY (the account
    /// is throttled, or Mistral is having a moment), so neither is reported as a
    /// rejection — telling someone their good key is bad is the one answer this
    /// check must never give.
    static func verification(forStatusCode statusCode: Int) -> MistralAPIKeyVerification {
        switch statusCode {
        case 200..<300:
            return .accepted
        case 401, 403:
            return .rejected(statusCode: statusCode)
        case 429:
            return .unreachable("Mistral is rate limiting requests. Try again in a moment.")
        case 500...599:
            return .unreachable("Mistral returned a server error (HTTP \(statusCode)).")
        default:
            return .rejected(statusCode: statusCode)
        }
    }
}

/// UI state of one "Check key" press. Owned separately by Settings and by the
/// onboarding wizard — they check different strings (the stored key vs the
/// wizard's draft) and must not overwrite each other's result.
enum MistralAPIKeyCheckState: Equatable, Sendable {
    case idle
    case checking
    case finished(MistralAPIKeyVerification)

    /// ONE line for the row's status label; nil renders no label at all.
    var statusLine: String? {
        switch self {
        case .idle:
            return nil
        case .checking:
            return "Checking…"
        case .finished(.accepted):
            return "Key accepted"
        case .finished(.rejected(let statusCode)):
            return "Rejected (HTTP \(statusCode))"
        case .finished(.unreachable):
            // The system's error text can be a paragraph and this label sits in
            // a settings row: the reason goes to the log, the row stays a line.
            return "Could not reach Mistral"
        }
    }

    var isChecking: Bool { self == .checking }
}
