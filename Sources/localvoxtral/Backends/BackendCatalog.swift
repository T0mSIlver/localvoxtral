import Foundation

struct ManagedBackendSpec: Equatable, Sendable {
    let id: String
    let displayName: String
    let executableName: String
    let port: Int
}

enum BackendCatalog {
    /// The dictation engine: localvoxtral-speechd (MLX Swift, see
    /// SpeechHelper/), bundled inside the .app. It serves the loopback OpenAI
    /// Realtime subset consumed by the production realtime client.
    static let speechd = ManagedBackendSpec(
        id: "speechd",
        displayName: "Dictation engine",
        executableName: "localvoxtral-speechd",
        port: 8471
    )

    /// The polishing engine: localvoxtral-polishd (MLX Swift, see
    /// PolishHelper/), bundled inside the .app.
    static let polishd = ManagedBackendSpec(
        id: "polishd",
        displayName: "Polishing engine",
        executableName: "localvoxtral-polishd",
        port: 8472
    )

    static let all: [ManagedBackendSpec] = [speechd, polishd]
}
