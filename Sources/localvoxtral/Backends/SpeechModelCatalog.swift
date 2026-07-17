import Foundation

struct SpeechModelOption: Equatable, Sendable {
    let repoID: String
    /// Exact commit downloaded by the app and loaded by speechd. The upstream
    /// loader otherwise resolves `main`, which would let a model-repo edit
    /// change strict weight keys beneath an installed app.
    let revision: String
    let displayName: String
}

enum SpeechModelCatalog {
    static let options: [SpeechModelOption] = [
        SpeechModelOption(
            repoID: "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit",
            revision: "fdebf7b2af834a1db4b8a3c99ab7480b333adf9e",
            displayName: "Voxtral Mini 4B Realtime (4-bit)"
        ),
    ]

    static let defaultOption: SpeechModelOption = {
        guard let option = option(
            forRepoID: "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
        ) else {
            preconditionFailure("Default speech model missing from the catalog.")
        }
        return option
    }()

    static func option(forRepoID repoID: String) -> SpeechModelOption? {
        options.first { $0.repoID == repoID }
    }
}
