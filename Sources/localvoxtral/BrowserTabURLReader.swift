import AppKit
import Foundation

/// Bundle IDs whose FOCUSED TAB URL may be read to join a Claude Code
/// "Remote Control" session.
///
/// Deliberately a separate list from `TerminalScreenAllowlist`, not an
/// extension of it, because it grants a different capability. That list answers
/// "may this app's visible screen be read", and every member has a verified
/// per-pane capture route. This one answers only "may we ask this app for the
/// URL of its focused tab" — one short string, matched against ids the user's
/// own hooks published. A browser NEVER gets a screen read: there is no
/// verified route, the page is arbitrary web content, and
/// `TerminalScreenClaudeJoinAuthorizer` refuses the `.browserTab` mechanism
/// outright. Keeping the lists apart is what makes that impossible to widen by
/// accident — adding a browser here can never hand it a screen capability.
///
/// Membership is exact-match and reviewed. Chromium forks share Chrome's
/// scripting dictionary (`active tab of front window`), so Brave uses the same
/// script under its own bundle id; Safari has its own (`current tab`). Firefox
/// is out of scope: it exposes no AppleScript surface for the focused tab's
/// URL, so there is nothing to read and nothing to abstain about.
enum BrowserTabAllowlist {
    /// Google Chrome's shipped bundle identifier.
    static let chromeBundleID = "com.google.Chrome"
    /// Brave Browser's shipped bundle identifier (Chromium fork; Chrome's
    /// scripting dictionary).
    static let braveBundleID = "com.brave.Browser"
    /// Safari's bundle identifier.
    static let safariBundleID = "com.apple.Safari"

    /// Browsers whose focused tab URL may be read for a Claude session join.
    static let supportedBundleIDs: Set<String> = [
        chromeBundleID, braveBundleID, safariBundleID,
    ]

    /// Exact-match only: no prefix matching (which would admit unverified
    /// channel builds and every "…Chrome Canary"-shaped id) and no user list.
    static func isSupported(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return supportedBundleIDs.contains(bundleID)
    }
}

/// Reads the URL of the focused window's active tab, keyed by bundle id.
///
/// The seam exists for the same reason `TerminalFocusedTTYReading` does: the
/// live implementation sends an Apple event, which raises the TCC Automation
/// consent sheet on first use, so no test may ever reach it by default.
///
/// Nil means "abstain" in every failure mode — unsupported app, Automation
/// denied, no front window, a reply that is not shaped like a URL. It never
/// means "guess".
@MainActor
protocol FocusedBrowserTabURLReading {
    func focusedTabURL(bundleID: String) async -> String?
}

/// The live reader: one bounded AppleScript question per supported browser.
///
/// Modeled on `AppleScriptTerminalTTYReader` down to the executor, and it
/// reuses that type's serial executor (one `DispatchQueue` + compiled-script
/// cache per bundle id) so the two readers cannot drift apart on the two things
/// that were learned the hard way: `NSAppleScript` is not thread-safe, and the
/// TCC consent sheet dies with the Apple event that raised it (field bug
/// 2026-07-22). Hence the same split — a 1 s read for the dictation path, and a
/// 600 s `consentPrewarmScriptSource` that `TerminalAutomationConsentPrewarm`
/// parks in so a human can actually answer the sheet.
@MainActor
struct AppleScriptFocusedBrowserTabURLReader: FocusedBrowserTabURLReading {
    /// The executor's result type, shared with the terminal reader rather than
    /// re-declared: one queue discipline, one result shape.
    typealias ExecutionResult = AppleScriptTerminalTTYReader.ExecutionResult

    /// The read used during dictation: 1 s, because a wedged browser must not
    /// hold session start hostage.
    static func scriptSource(forBundleID bundleID: String) -> String? {
        script(forBundleID: bundleID, timeoutSeconds: 1)
    }

    /// The consent pre-warm's variant: identical question, but the Apple event
    /// must outlive a human reading and answering the Automation consent sheet.
    static func consentPrewarmScriptSource(forBundleID bundleID: String) -> String? {
        script(forBundleID: bundleID, timeoutSeconds: 600)
    }

    /// Per-browser property chains, each naming the FOCUSED tab of the FRONT
    /// window — never a tab list, never other windows:
    /// - Chrome and Chromium forks (Brave): `active tab of front window`.
    /// - Safari: `current tab of front window`.
    ///
    /// `tell application id` (not by name) for the same reason the terminal
    /// reader uses it: the caller only ever asks about an app it just observed
    /// as frontmost, so nothing is launched.
    private static func script(forBundleID bundleID: String, timeoutSeconds: Int) -> String? {
        let propertyChain: String
        switch bundleID {
        case BrowserTabAllowlist.chromeBundleID, BrowserTabAllowlist.braveBundleID:
            propertyChain = "URL of active tab of front window"
        case BrowserTabAllowlist.safariBundleID:
            propertyChain = "URL of current tab of front window"
        default:
            return nil
        }
        let timeout = timeoutSeconds == 1 ? "1 second" : "\(timeoutSeconds) seconds"
        return """
        with timeout of \(timeout)
            tell application id "\(bundleID)"
                get \(propertyChain)
            end tell
        end timeout
        """
    }

    /// One executor (queue + compiled-script cache) per supported browser,
    /// built up front so `focusedTabURL` is a pure lookup.
    private let executors: [String: TerminalAppleScriptSerialExecutor]

    /// `executeScript` is the test seam: it receives the bundle id being asked
    /// about and replaces the live AppleScript execution. Unit tests must never
    /// send real Apple events.
    init(executeScript: (@Sendable (String) -> ExecutionResult)? = nil) {
        var executors: [String: TerminalAppleScriptSerialExecutor] = [:]
        for bundleID in BrowserTabAllowlist.supportedBundleIDs {
            guard let source = Self.scriptSource(forBundleID: bundleID) else { continue }
            let executeOverride: (@Sendable () -> ExecutionResult)?
            if let executeScript {
                executeOverride = { executeScript(bundleID) }
            } else {
                executeOverride = nil
            }
            executors[bundleID] = TerminalAppleScriptSerialExecutor(
                source: source,
                queueLabel: "com.localvoxtral.browser-tab-url-applescript.\(bundleID)",
                executeOverride: executeOverride
            )
        }
        self.executors = executors
    }

    func focusedTabURL(bundleID: String) async -> String? {
        // Allowlisted browsers only, exact match: each script is that app's
        // dictionary, and sending one anywhere else is at best an error and at
        // worst a prompt to automate an app the user never pointed us at.
        guard let executor = executors[bundleID] else { return nil }
        switch await executor.execute() {
        case .failure(let code):
            // Code only. An AppleScript error string can quote a window title,
            // and a browser title is page content.
            // -1743: the user declined the Automation prompt.
            // -1728: no front window (all windows closed/minimized).
            if code == -1743 {
                Log.claudeContext.info(
                    "Automation permission denied — grant localvoxtral → \(bundleID, privacy: .public) in System Settings > Privacy > Automation"
                )
            } else {
                Log.claudeContext.info(
                    "Focused-tab URL unavailable for \(bundleID, privacy: .public) (AppleScript error \(code, privacy: .public))"
                )
            }
            return nil
        case .success(let rawURL):
            return Self.validatedURL(rawURL)
        }
    }

    /// Shape-only validation of the reply, before it reaches the parser.
    ///
    /// A URL is CONTENT — it names a page the user is looking at — so this
    /// neither logs it nor interprets it. It only rejects replies that cannot
    /// be a URL at all (empty, oversized, non-ASCII, containing whitespace or
    /// control bytes), the same way `validatedTTY` rejects a reply that is not
    /// shaped like a device path. Whether the URL is a joinable Claude Code
    /// session is `ClaudeBridgeSessionURL`'s question, and it is strict.
    static func validatedURL(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 2048 else { return nil }
        // Printable ASCII only: no space, no C0 control byte, no DEL, nothing
        // non-ASCII. A CR/LF or NUL in a reply is not a URL under any reading.
        let isPrintableASCII = raw.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value > 0x20 && scalar.value != 0x7F
        }
        return isPrintableASCII ? raw : nil
    }
}
