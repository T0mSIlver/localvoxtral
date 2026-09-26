import AppKit
import ClaudeContextWire
import Foundation

/// Brings a local session's terminal pane to the front by the tty its hooks
/// reported (#723 step 1): the terminal selects the tab or split holding that
/// tty, then the terminal is activated. Nothing is typed.
///
/// The answer is checked the way the join reads a pane: the terminal's
/// focused-pane tty (`TerminalFocusedTTYReading`) must equal the session's,
/// or the outcome is `.unverified`. A Return after a focus (#723 step 3) or
/// #717's answer hotkey must hold out for `.focused`.
@MainActor
final class TerminalSessionPaneFocuser: SessionPaneFocusing {
    /// Bundle IDs of the supported terminals that are running now. A
    /// `tell application id` to one that is not would launch it.
    private let runningTerminalBundleIDs: () -> Set<String>
    private let runScript: (String) async -> AppleScriptTerminalTTYReader.ExecutionResult
    private let activate: (String) -> Bool
    private let focusedTTY: (String) async -> String?

    /// The terminals, in the order they are asked when the session's
    /// `$TERM_PROGRAM` names none of them.
    static let terminalBundleIDs = [
        TerminalScreenAllowlist.ghosttyBundleID,
        TerminalScreenAllowlist.iterm2BundleID,
        TerminalScreenAllowlist.appleTerminalBundleID,
    ]

    init(
        runningTerminalBundleIDs: @escaping () -> Set<String>,
        runScript: @escaping (String) async -> AppleScriptTerminalTTYReader.ExecutionResult,
        activate: @escaping (String) -> Bool,
        focusedTTY: @escaping (String) async -> String?
    ) {
        self.runningTerminalBundleIDs = runningTerminalBundleIDs
        self.runScript = runScript
        self.activate = activate
        self.focusedTTY = focusedTTY
    }

    /// The Apple events and the activation are real; only the app builds one.
    static func live(ttyReader: any TerminalFocusedTTYReading) -> TerminalSessionPaneFocuser {
        let queue = DispatchQueue(label: "com.localvoxtral.session-pane-focus")
        return TerminalSessionPaneFocuser(
            runningTerminalBundleIDs: {
                Set(terminalBundleIDs.filter {
                    !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
                })
            },
            runScript: { source in
                await withCheckedContinuation { continuation in
                    queue.async {
                        var error: NSDictionary?
                        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                        if let error {
                            continuation.resume(returning: .failure(
                                code: (error[NSAppleScript.errorNumber] as? Int) ?? 0))
                        } else {
                            continuation.resume(returning: .success(result?.stringValue))
                        }
                    }
                }
            },
            activate: { bundleID in
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
                else { return false }
                return app.activate(options: [])
            },
            focusedTTY: { await ttyReader.focusedTerminalTTY(bundleID: $0) }
        )
    }

    func focusPane(of session: ClaudeSessionSnapshot) async -> SessionPaneFocusOutcome {
        let tty: String
        let termProgram: String?
        switch SessionPaneFocusRoute.of(session) {
        case .unsupported(let reason):
            Log.claudeContext.info("go to session: no route to the pane (\(reason.rawValue, privacy: .public))")
            return .unsupported(reason)
        case .terminalTTY(let sessionTTY, let program):
            tty = sessionTTY
            termProgram = program
        }
        guard Self.isScriptSafeTTY(tty) else {
            Log.claudeContext.error("go to session: the session's tty is not a device path; not asking any terminal")
            return .paneNotFound
        }
        let running = runningTerminalBundleIDs()
        for bundleID in Self.askingOrder(termProgram: termProgram) where running.contains(bundleID) {
            guard let source = Self.focusScriptSource(bundleID: bundleID, tty: tty) else { continue }
            switch await runScript(source) {
            case .failure(let code):
                // Code only: an AppleScript error string can quote a title.
                Log.claudeContext.info(
                    "go to session: \(bundleID, privacy: .public) could not be asked (AppleScript error \(code, privacy: .public))"
                )
                continue
            case .success(let reply) where reply == Self.focusedReply:
                let activated = activate(bundleID)
                let readBack = await focusedTTY(bundleID)
                let verified = readBack == tty
                Log.claudeContext.info(
                    "go to session: \(bundleID, privacy: .public) selected the pane; activated=\(activated, privacy: .public) verified=\(verified, privacy: .public)"
                )
                return verified ? .focused(bundleID: bundleID) : .unverified(bundleID: bundleID)
            case .success:
                continue
            }
        }
        Log.claudeContext.info("go to session: no running terminal holds the session's tty")
        return .paneNotFound
    }

    static let focusedReply = "focused"

    static func askingOrder(termProgram: String?) -> [String] {
        let preferred: String? = switch termProgram {
        case "ghostty": TerminalScreenAllowlist.ghosttyBundleID
        case "iTerm.app": TerminalScreenAllowlist.iterm2BundleID
        case "Apple_Terminal": TerminalScreenAllowlist.appleTerminalBundleID
        default: nil
        }
        guard let preferred else { return terminalBundleIDs }
        return [preferred] + terminalBundleIDs.filter { $0 != preferred }
    }

    /// The tty is spliced into AppleScript source, so it must be a device
    /// path of letters and digits: no quote, backslash or space can reach
    /// the script. Stricter than the join's reply check on purpose.
    static func isScriptSafeTTY(_ tty: String) -> Bool {
        let prefix = "/dev/tty"
        guard tty.hasPrefix(prefix), tty.count <= 32 else { return false }
        let rest = tty.dropFirst(prefix.count)
        return !rest.isEmpty && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Selects the pane holding `tty` and answers "focused", or answers
    /// nothing when no pane holds it. Nil for an unsupported terminal or an
    /// unsafe tty.
    /// - Ghostty ≥ 1.4: `focus` on the terminal whose `tty` matches; it
    ///   selects the tab and split and brings the window to the front.
    /// - iTerm2: `select` the window, tab and session.
    /// - Terminal.app: set the window's selected tab and raise the window.
    static func focusScriptSource(bundleID: String, tty: String) -> String? {
        guard isScriptSafeTTY(tty) else { return nil }
        let body: String
        switch bundleID {
        case TerminalScreenAllowlist.ghosttyBundleID:
            body = """
                    repeat with t in terminals
                        if tty of t is "\(tty)" then
                            focus t
                            return "\(focusedReply)"
                        end if
                    end repeat
            """
        case TerminalScreenAllowlist.iterm2BundleID:
            body = """
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select w
                                    select t
                                    select s
                                    return "\(focusedReply)"
                                end if
                            end repeat
                        end repeat
                    end repeat
            """
        case TerminalScreenAllowlist.appleTerminalBundleID:
            body = """
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected tab of w to t
                                set index of w to 1
                                return "\(focusedReply)"
                            end if
                        end repeat
                    end repeat
            """
        default:
            return nil
        }
        return """
        with timeout of 2 seconds
            tell application id "\(bundleID)"
        \(body)
            end tell
        end timeout
        return ""
        """
    }
}
