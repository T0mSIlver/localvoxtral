import Foundation

/// The opt-outs a CI lane sets before launching the REAL packaged app on the
/// owner's Mac, so an unattended run cannot put a modal dialog on a human's
/// desktop.
///
/// Two separate dialogs, two separate flags, because the lanes need them
/// separately:
///
/// - TCC (`environmentKey`): the launched app's permission checks are
///   attributed to the runner's bundled node, whose Accessibility grant dies on
///   every runner auto-update, so the startup permission pass pops a real
///   dialog once per run (2026-07-24). Only the launch smoke wants this — a
///   lane that drives the UI still needs the production startup path.
/// - Login keychain (`keychainEnvironmentKey`): this app has no Team ID — ad-hoc
///   and self-signed builds alike partition their keychain items by the
///   per-build code-signing hash — so the first read of an API-key item from a
///   freshly built binary is an ACL partition mismatch, which macOS answers
///   with a modal keychain prompt. CI packages and launches the app on every
///   push: on 2026-09-17 `securityd` logged one
///   `displaying keychain prompt for /private/var/.../T/tmp.*/localvoxtral.app`
///   per CI run on the owner's Mac, and no other keychain prompt at all.
///   Suppressing TCC prompts implies this one; a lane can also ask for it
///   alone.
///
/// Env vars rather than a compile flag on purpose: the lanes must launch the
/// same binary end users get, not a special build.
enum StartupPermissionSuppression {
    /// Set to `"1"` by the packaged-app launch smoke (`ci.yml`, `release.yml`).
    static let environmentKey = "LOCALVOXTRAL_SUPPRESS_STARTUP_PERMISSION_PROMPTS"

    /// Set to `"1"` by every other workflow step that launches the app on the
    /// self-hosted Mac. Grep both keys in `.github/workflows/` before adding a
    /// lane that opens the bundle.
    static let keychainEnvironmentKey = "LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN"

    /// True when the startup microphone/Accessibility pass must not run.
    static func isActive(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }

    /// True when nothing in this process may touch the login keychain.
    static func loginKeychainIsDisabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isActive(environment: environment) || environment[keychainEnvironmentKey] == "1"
    }
}
