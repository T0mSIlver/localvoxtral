import Foundation

/// Counts the tokens of one part of the polish prompt for Settings (#1007).
///
/// Prompt size matters most on the bundled helper, where it drives prefill
/// time and memory, so there the helper's own tokenizer counts it exactly
/// (`POST /v1/tokenize`). Every other backend, or a helper that is not
/// running or predates the route, gets `PolishPromptTokenRatio`'s estimate.
struct PolishPromptTokenCounter: Sendable {
    enum Count: Equatable, Sendable {
        case exact(Int)
        case estimated(Int)
    }

    let ratio: PolishPromptTokenRatio
    /// Set when the bundled helper polishes.
    let helperTokenizeURL: URL?
    var session: URLSession = .shared

    @MainActor
    init(settings: SettingsStore, ledger: UsageLedger?) {
        let backend: UsageEntry.Backend = switch settings.polishingBackendMode {
        case .managedLocal: .bundledHelper
        case .mistralAPI: .mistral
        case .externalURL: .userServer
        }
        ratio = PolishPromptTokenRatio(entries: ledger?.entries() ?? [], backend: backend)
        helperTokenizeURL = backend == .bundledHelper
            ? URL(string: "http://127.0.0.1:\(ManagedBackendEndpoints.polishdPort)/v1/tokenize") : nil
    }

    init(ratio: PolishPromptTokenRatio, helperTokenizeURL: URL?, session: URLSession = .shared) {
        self.ratio = ratio
        self.helperTokenizeURL = helperTokenizeURL
        self.session = session
    }

    /// Nil for an empty text. `termList` picks the estimate's weight.
    func count(_ text: String, termList: Bool = false) async -> Count? {
        guard !text.isEmpty else { return nil }
        if let helperTokenizeURL, let tokens = await Self.helperCount(text, url: helperTokenizeURL, session: session) {
            return .exact(tokens)
        }
        return .estimated(
            termList
                ? ratio.tokens(termListCharacters: text.count)
                : ratio.tokens(proseCharacters: text.count))
    }

    private static func helperCount(_ text: String, url: URL, session: URLSession) async -> Int? {
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["text": text])
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = (object["tokens"] as? NSNumber)?.intValue
            else {
                Log.backends.info("polishd tokenize: status \(status, privacy: .public); estimating instead")
                return nil
            }
            return tokens
        } catch {
            Log.backends.info(
                "polishd tokenize failed: \(error.localizedDescription, privacy: .public); estimating instead")
            return nil
        }
    }
}

/// The status text next to each part.
enum PolishPromptTokenText {
    /// "1,229 tokens" from the helper, "≈ 1,230 tokens" estimated; both
    /// profiles when the agent one is on: "≈ 1,230 · agent ≈ 1,760 tokens".
    static func instructions(standard: PolishPromptTokenCounter.Count, agent: PolishPromptTokenCounter.Count?) -> String {
        guard let agent else { return "\(format(standard)) tokens" }
        return "\(format(standard)) · agent \(format(agent)) tokens"
    }

    /// "12 terms · ≈ 90 tokens".
    static func globalTerms(count: Int, tokens: PolishPromptTokenCounter.Count) -> String {
        "\(count) term\(count == 1 ? "" : "s") · \(format(tokens)) tokens"
    }

    /// "up to ≈ 120 tokens".
    static func projectTerms(_ tokens: PolishPromptTokenCounter.Count) -> String {
        "up to \(format(tokens)) tokens"
    }

    /// An estimate rounds to tens from 100 up: its last digit means nothing.
    static func format(_ count: PolishPromptTokenCounter.Count) -> String {
        switch count {
        case .exact(let tokens):
            return tokens.formatted()
        case .estimated(let tokens):
            let rounded = tokens >= 100 ? Int((Double(tokens) / 10).rounded()) * 10 : tokens
            return "≈ \(rounded.formatted())"
        }
    }
}
