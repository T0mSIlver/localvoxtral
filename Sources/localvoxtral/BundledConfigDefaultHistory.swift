import Foundation

/// SHA-256 (hex) of every version of each bundled default config file ever
/// shipped on main, keyed by file name.
///
/// `AppConfigStore.reconcileBundledDefaults()` uses this to tell an UNEDITED
/// stale seed (its hash is listed here, so replacing it loses nothing) from a
/// user-customized file (unknown hash — never overwritten without asking).
/// A hash missing from this list degrades safely: the file is treated as
/// customized and the user is prompted instead of silently refreshed.
///
/// When you change a TOML under `Sources/localvoxtral/Resources/Config`, ADD
/// the new content's hash here and KEEP the old ones — the old entries are
/// what lets existing installs adopt your change.
/// `AppConfigStoreTests.testCurrentBundledDefaultsAreRegisteredInHistory`
/// fails with the exact hash to paste if you forget.
enum BundledConfigDefaultHistory {
    static let knownDefaultHashes: [String: Set<String>] = [
        "llm_system_prompt.toml": [
            // 2026-07-12 prompt trim (#126)
            "6255e385bcc265e7948b9b9be263fac5a193510dfcd7385d544ec9889547cef6",
            // 2026-07-07 punctuation-spacing focus (#80)
            "31dbd825f037d73aa54e8b49bc103fa3d023cfd0c458c82bafa65ce68b512675",
            // 2026-03-14 v0.6.0 initial (#14)
            "6736867bb539f20e241812c45399198dc86b4c87488ddc50458348c2558ace69",
        ],
        "llm_user_prompt.toml": [
            // 2026-07-12 prompt trim (#126)
            "06c1b26b7708748d07392f85ddce1a7a9a8da97c7a69a01c550c41648f9d5bd7",
            // 2026-07-07 punctuation-spacing focus (#80)
            "d53ce4d91c98249861cf3177c9f7431b83661e31d09603e2f5ef1331680e046f",
            // 2026-03-14 v0.6.0 initial (#14)
            "43ededf94739fe2a1d5ccfb7c99bcefc438afc30737c974cd9d284826bbbb771",
        ],
        "llm_system_prompt_agent.toml": [
            // 2026-07-12 prompt trim (#126)
            "e3c586e3cf1a7ba2d30fe693f2e0213b63f97e4e62dabb915ae1dc90298d0a8c",
            // 2026-07-12 agent profile introduction (#113)
            "8150e32ae3868e19554707e7b7b76fb979c1311306339d8dae1308cd7cf84cb5",
        ],
        "llm_user_prompt_agent.toml": [
            // 2026-07-12 prompt trim (#126)
            "0041927e3aed8fd87d0e0f8033b24faf22fc0a685b86740a9c2f8e063da04134",
            // 2026-07-12 agent profile introduction (#113)
            "283f547c020da4da1ea2fa62873752bd3561f10830b590023dadd26f854b04fa",
        ],
        "replacement_dictionary.toml": [
            // 2026-03-14 v0.6.0 initial (#14)
            "6a03d1fb6fc480aeac2d71a48ec4426cb6f4c07f1fd166e30b52f6b456288e38",
        ],
        "terminal_apps.toml": [
            // 2026-07-08 terminal-safe live dictation (#82)
            "f0fbb2b09c20274b88ec4a868d2e3faa2389ef678fd4504b84f089d09f936426",
        ],
    ]
}

/// Outcome of `AppConfigStore.reconcileBundledDefaults()`.
struct BundledDefaultsReconciliation: Equatable, Sendable {
    /// Files whose on-disk content was an unedited older default; they were
    /// silently replaced with the current bundled default.
    var refreshedFileNames: [String] = []
    /// Files the user customized while this build ships a newer default, with
    /// no decision recorded for that default yet. The caller should prompt.
    var customizedOutdatedFileNames: [String] = []
}
