import Foundation

/// `localvoxtral --probe-surface [--json]`: resolve the Claude Code join for
/// whatever surface is frontmost right now, print the answer, exit.
///
/// The verb exists because the join is otherwise unobservable. In the field the
/// only symptom of a join that will not resolve is context that never arrives,
/// and the resolver reduces every abstention to a `Log.claudeContext` line that
/// says nothing about which of a dozen causes fired — the gap that made the
/// Ghostty ssh-wrapper case (2026-08-03, the tty probe reporting
/// `undeterminable` because the wrapper hid the client) take a remote-probing
/// session to attribute. Running the verb from the terminal you would dictate
/// into makes THAT terminal the frontmost surface, so the answer describes
/// exactly the surface in question.
///
/// ## Read-only by construction, not by discipline
///
/// The remote-herdr arm can open an `ssh -L` and stamp a `pane.report_metadata`
/// nonce into a herdr agents panel. A one-shot process is the worst possible
/// owner for either: it has no supervisor, no idle window, and no second chance
/// to clear a stamp if it is killed between stamping and clearing. So the probe
/// does not decline to do those things — it is BUILT UNABLE TO. The forward and
/// panel-metadata capabilities are passed as `nil`, which is the resolver's own
/// documented "the arm can never spawn anything" configuration, and no flag
/// re-enables them. The arm's read-only halves (the process-table ssh probe and
/// enrolled-host matching) still run, because those are exactly the steps the
/// field questions are about and they touch nothing.
///
/// Everything else the probe wires is a read: the AppleScript focused-pane tty,
/// the herdr process-table binding, `pane.current`/`pane.process_info` on a
/// local herdr socket, the AX focused-window identity. Nothing is written,
/// nothing outlives the process, and the printed summary carries no token,
/// nonce, host, pane id, session id, or path (see
/// `ClaudeSessionJoinSummary`).
///
/// ## What this process cannot know
///
/// The session registry is per-process and lives only in the running app: it is
/// built from hook records the app's broker received. A separate one-shot
/// process therefore starts with an EMPTY registry, so `arm` reports what a
/// resolve against no known sessions concludes, and the diagnostic value is in
/// `abstentionReason` — which arms ran, how far each got, and where the surface
/// stopped being identifiable. `probe: no live Claude sessions in this process`
/// is noted first whenever that is the case, so the chain can never be misread
/// as "the surface failed". See `docs/agent/field-debugging.md`.
@MainActor
enum ClaudeSurfaceProbe {
    static let verb = "--probe-surface"

    struct Options: Equatable {
        /// One line of JSON on stdout instead of the aligned human form.
        var json = false
    }

    enum Invocation: Equatable {
        /// `--probe-surface` was not on the command line; launch the app.
        case notRequested
        case run(Options)
        /// The verb was requested but the rest of the line made no sense.
        case usageError(String)
    }

    /// Reasons the PROBE declined before the resolver ever ran.
    ///
    /// New strings, unavoidably: they name facts about running as a one-shot
    /// diagnostic process that no arm has ever had to report. Everything the
    /// resolver itself can conclude is reported in the resolver's own
    /// vocabulary, unchanged, and nothing here restates one of those.
    enum ProbeAbstention: String, Equatable {
        case accessibilityNotGranted = "probe: accessibility permission not granted"
        case noFrontmostApplication = "probe: no frontmost application"
        case unsupportedSurface = "probe: frontmost application is not a joinable surface"
        case noLiveSessions = "probe: no live Claude sessions in this process"
        case timedOut = "probe: resolver did not answer within the probe deadline"
    }

    static let usageText = """
    usage: localvoxtral --probe-surface [--json]

    Resolves the Claude Code session join for the frontmost surface once and
    exits. Run it from the terminal you would dictate into: that terminal is
    the frontmost surface, which is the one being probed.

      --json   one line of JSON instead of the aligned human form

    Exit status: 0 an arm joined, 1 no arm joined, 2 usage error.
    """

    static func invocation(arguments: [String]) -> Invocation {
        let arguments = Array(arguments.dropFirst())
        guard arguments.contains(verb) else { return .notRequested }
        var options = Options()
        for argument in arguments {
            switch argument {
            case verb: continue
            case "--json": options.json = true
            default:
                return .usageError("unrecognized option for \(verb): \(argument)")
            }
        }
        return .run(options)
    }

    /// The probe's decision, with every live capability injected.
    ///
    /// Pure in the sense that matters: it reads no global state, so a test can
    /// drive every branch — including the two grant failures — without a
    /// frontmost app, an Accessibility grant, or a socket.
    static func summarize(
        accessibilityTrusted: Bool,
        frontmostTarget: TerminalScreenTarget?,
        hasLiveSessions: () -> Bool,
        resolve: (TerminalScreenTarget) async -> ClaudeSessionJoin?
    ) async -> ClaudeSessionJoinSummary {
        // Refused before resolving, not after. Without the grant the window
        // identity is unknowable, so a resolve would spend real Apple events to
        // arrive at an answer whose abstentions would all be misattributed to
        // the arms rather than to the missing permission.
        guard accessibilityTrusted else {
            return abstained(.accessibilityNotGranted)
        }
        guard let target = frontmostTarget else {
            return abstained(.noFrontmostApplication)
        }
        guard TerminalScreenAllowlist.isSupported(target.bundleID)
            || BrowserTabAllowlist.isSupported(target.bundleID)
        else {
            // The resolver returns nil for an unlisted bundle without noting a
            // cause, and "no reason at all" is the least useful thing a
            // diagnostic can print.
            return abstained(.unsupportedSurface)
        }

        let (join, abstentions) = await ClaudeJoinAbstentionTap.collecting {
            // Noted FIRST so it reads as the frame around everything after it.
            if !hasLiveSessions() {
                ClaudeJoinAbstentionTap.note(ProbeAbstention.noLiveSessions.rawValue)
            }
            return await resolve(target)
        }
        return ClaudeSessionJoinSummary.summarize(join: join, abstentions: abstentions)
    }

    private static func abstained(_ reason: ProbeAbstention) -> ClaudeSessionJoinSummary {
        ClaudeSessionJoinSummary.summarize(join: nil, abstentions: [reason.rawValue])
    }

    /// 0 an arm joined, 1 no arm joined. Split so a shell assertion does not
    /// have to parse JSON to ask the only question it usually has.
    static func exitCode(for summary: ClaudeSessionJoinSummary) -> Int32 {
        summary.arm == "none" ? 1 : 0
    }
}
