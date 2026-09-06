import AppKit
import ApplicationServices
import Foundation
import Synchronization

/// The live half of `--probe-surface`: builds the read-only resolver, runs it
/// once under a hard deadline, prints, and hands back an exit status.
///
/// Deliberately thin, and deliberately the only untested file in this feature.
/// Everything it decides lives in `ClaudeSurfaceProbe.summarize` behind
/// injected seams; what remains here is the wiring itself — which capabilities
/// are handed to the resolver and which are withheld — and that is a diff to
/// read, not an assertion to write.
@MainActor
enum ClaudeSurfaceProbeCommand {
    /// The resolver spends Apple events, a socket dial, and possibly an
    /// `ssh -G`. Any of them can block: an Automation consent sheet blocks
    /// until answered, and a wedged socket blocks until the kernel gives up. A
    /// diagnostic that hangs is worse than one that abstains, so the whole
    /// resolve is bounded and a timeout is reported as a named cause.
    static let deadline: TimeInterval = 25

    /// - Returns: the process exit status. 0 an arm joined, 1 no arm joined.
    static func run(options: ClaudeSurfaceProbe.Options) -> Int32 {
        let summary = resolveWithinDeadline()
        print(options.json ? summary.jsonLine : summary.textLines)
        return ClaudeSurfaceProbe.exitCode(for: summary)
    }

    /// Runs the async probe from synchronous top-level code by pumping the main
    /// run loop, the same shape `AppDelegate.drainRemoteForwardTeardowns` uses
    /// — blocking the main thread on a semaphore instead would deadlock the
    /// main-actor task it is waiting for.
    private static func resolveWithinDeadline() -> ClaudeSessionJoinSummary {
        let answer = Mutex<ClaudeSessionJoinSummary?>(nil)
        Task { @MainActor in
            let summary = await probe()
            answer.withLock { $0 = summary }
        }
        let expiry = Date().addingTimeInterval(deadline)
        while answer.withLock({ $0 }) == nil, Date() < expiry {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return answer.withLock { $0 } ?? ClaudeSessionJoinSummary.summarize(
            join: nil,
            abstentions: [ClaudeSurfaceProbe.ProbeAbstention.timedOut.rawValue]
        )
    }

    private static func probe() async -> ClaudeSessionJoinSummary {
        let registry = ClaudeSessionRegistry()
        let resolver = makeResolver(registry: registry)
        return await ClaudeSurfaceProbe.summarize(
            // Never `AXIsProcessTrustedWithOptions`: a diagnostic must report
            // the permission state, not change it by raising the grant sheet.
            accessibilityTrusted: AXIsProcessTrusted(),
            frontmostTarget: frontmostTarget(),
            hasLiveSessions: { registry.hasLiveSessions() },
            resolve: { await resolver.resolve(target: $0) }
        )
    }

    /// The frontmost app as a target. Not `TerminalScreenContextSource`'s
    /// version, which self-excludes by pid so a dictation never captures our
    /// own overlay: this process has no window, so the frontmost app is the
    /// terminal the verb was typed into, and excluding ourselves would only
    /// hide a surface we do want to describe.
    private static func frontmostTarget() -> TerminalScreenTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else { return nil }
        return TerminalScreenTarget(pid: app.processIdentifier, bundleID: bundleID)
    }

    /// Every capability decision this feature makes, in one place.
    ///
    /// WIRED, all reads: the AppleScript focused-pane tty, the herdr client
    /// process-table binding, a local herdr socket's `pane.current` /
    /// `pane.process_info`, the AX window title and window identity, the
    /// process-table ssh probe, and enrolled-host matching (including the
    /// `ssh -G` canonicalization, which resolves config and opens no
    /// connection).
    ///
    /// WITHHELD, and each for its own reason:
    ///
    /// * `remoteHerdrForwards` / `herdrPanelMetadata` — the forward and the
    ///   panel nonce. Nil is the resolver's documented "this arm can never
    ///   spawn anything" configuration, so the probe cannot open an `ssh -L`
    ///   that outlives it or leave a `lv-mic-…` stamp in someone's agents
    ///   panel. There is no flag that turns these on.
    /// * `cmuxSurfaces` / `cmuxJoinEnabled` — the cmux arm reads a Keychain
    ///   password and talks to another app's control socket behind a user
    ///   opt-in. A diagnostic must not raise a keychain prompt.
    /// * `focusedBrowserTabURL` — a tab URL is a page the user is looking at.
    ///   The browser arm abstains here rather than have a debug verb read the
    ///   address bar.
    /// * `readFocusedGrid` — screen text, and only the panel-nonce match ever
    ///   needed it. The probe reads no screen content at all.
    private static func makeResolver(registry: ClaudeSessionRegistry) -> ClaudeSessionJoinResolver {
        let ttyReader = AppleScriptTerminalTTYReader()
        // Read-only: `init` parses the enrollment file and every query used
        // here is a pure lookup over the parsed value. An unreadable or absent
        // file means no candidates, which is the same as no enrollment.
        let hosts = try? ClaudeRemoteHostRegistry()
        let canonicalizer = SSHDestinationCanonicalizer.live()
        return ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { await ttyReader.focusedTerminalTTY(bundleID: $0) },
            herdrClientProbe: { HerdrClientTTYProbe.isHerdrClient(onTTYDevicePath: $0) },
            herdrPanes: HerdrSocketClient(),
            sshDestinationProbe: { SSHDestinationTTYProbe.connection(onTTYDevicePath: $0) },
            enrolledHosts: { hosts?.hosts(matchingSSHDestination: $0) ?? [] },
            canonicalizedEnrolledHosts: { destination in
                guard let enrolled = hosts?.hosts() else { return [] }
                return await canonicalizer.matchingHosts(
                    destination: destination,
                    enrolledHosts: enrolled
                )
            },
            proxyJumpShape: { await canonicalizer.proxyJumpShape(for: $0) },
            speculativeHosts: { hosts?.hosts() ?? [] }
        )
    }
}
