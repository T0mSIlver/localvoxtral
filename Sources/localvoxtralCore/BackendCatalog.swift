import Foundation

package struct ManagedBackendSpec: Equatable, Sendable {
    package let id: String
    package let displayName: String
    package let executableName: String
    package let port: Int
}

package enum BackendCatalog {
    /// The dictation engine: localvoxtral-speechd (MLX Swift, see
    /// SpeechHelper/), bundled inside the .app. It serves the loopback OpenAI
    /// Realtime subset consumed by the production realtime client.
    package static let speechd = ManagedBackendSpec(
        id: "speechd",
        displayName: "Dictation engine",
        executableName: "localvoxtral-speechd",
        port: 8471
    )

    /// The polishing engine: localvoxtral-polishd (MLX Swift, see
    /// PolishHelper/), bundled inside the .app.
    package static let polishd = ManagedBackendSpec(
        id: "polishd",
        displayName: "Polishing engine",
        executableName: "localvoxtral-polishd",
        port: 8472
    )

    package static let all: [ManagedBackendSpec] = [speechd, polishd]
}
