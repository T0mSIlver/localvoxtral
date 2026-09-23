import Foundation

enum BackendMode: String, CaseIterable, Identifiable {
    case managedLocal = "managed_local"
    case externalURL = "external_url"
    /// Mistral's hosted API: the realtime transcription socket for dictation
    /// (`MistralRealtimeWebSocketClient`) and `/v1/chat/completions` for
    /// polishing, both authenticated with the one shared Mistral API key.
    case mistralAPI = "mistral_api"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .managedLocal:
            return "Managed local"
        case .externalURL:
            return "External URL"
        case .mistralAPI:
            return "Mistral API"
        }
    }

    /// Whether this mode runs on a bundled helper this app supervises. The
    /// engine lifecycle (warmup, shutdown, readiness) keys off this rather
    /// than off `.externalURL`, so every hosted mode behaves the same way.
    var isManaged: Bool { self == .managedLocal }
}
