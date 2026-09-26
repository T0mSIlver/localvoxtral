import ClaudeContextWire
import Foundation
import Observation

#if canImport(Darwin)
import Darwin
import Synchronization
#endif

/// Settings-pane state for both Claude Code integrations.
///
/// `@MainActor @Observable`, per repo convention for stateful UI controllers.
/// Every dependency is injected: no singleton reaches through this type to a
/// real process, a real port, or a real host.
///
/// The division of labour with the view is deliberate. Failures, port
/// conflicts, and short consent text are decided here, where they have tests.
/// The view renders those strings without exposing generated configuration.
@MainActor
@Observable
public final class ClaudeIntegrationSettingsModel {
    // MARK: - Observable state

    public internal(set) var hosts: [HostRow] = []
    /// Saved herdr machines as enrollment sources, derived with `hosts` so an
    /// import (or a host removal) re-derives the rows on the same refresh.
    public internal(set) var herdrMachines: HerdrMachineImportSection = .absent
    public internal(set) var listenerStatus: ListenerStatus = .idle
    /// One short sentence when connections have been rejected since launch, nil
    /// otherwise. See `rejectionHint(for:)`.
    public internal(set) var rejectionHint: String?
    /// Short result copy for the local plugin action, e.g. "Installed." Cleared
    /// when a new action starts.
    public internal(set) var pluginResult: String?
    public internal(set) var isPerformingPluginAction = false
    public internal(set) var presentedPlan: EnrollmentPresentation?
    /// The update plan for the host whose automated setup panel is open.
    public internal(set) var presentedPluginUpdate: PluginUpdatePresentation?
    public internal(set) var enrollmentConfirmation: EnrollmentConfirmation?
    public internal(set) var isPerformingEnrollmentAction = false
    /// Step 3's verdicts. Empty until the user presses Check Setup — a check
    /// nobody asked for would spawn ssh on opening a sheet.
    public internal(set) var verificationChecks: [ClaudeRemoteEnrollmentService.VerificationCheck] = []
    public internal(set) var isPerformingVerification = false
    public internal(set) var setupRun: RemoteHostSetupRun?
    public internal(set) var setupManualInstructions: String?
    var setupCancellationRequested = false
    var setupSummaries: [String: String] = [:]
    public var alert: DetailAlert?

    /// One busy flag for the sheet, so no two actions can interleave: a setup
    /// run, a local panel edit, and a check all drive the same seams.
    public var isEnrollmentBusy: Bool { isPerformingEnrollmentAction || isPerformingVerification }

    /// Whether THIS Mac currently holds the listener port.
    ///
    /// `.listening` and nothing else: `.portConflict` and `.failed` both mean
    /// the port is not ours, which is exactly the case a forwarded 401 must not
    /// pass. Read at two different moments by `runVerification`, so it is one
    /// property rather than two copies of the same expression.
    var listenerIsBound: Bool {
        guard let listener, listener.isListening else { return false }
        return listenerStatus == .listening(port: listener.boundPort)
    }

    /// What the cmux control socket last told us, as one short sentence in the
    /// pane. Written by the join resolver on every attempt, so a user who
    /// dictates and sees no cmux context can read WHY here instead of in the
    /// log. `.ok` renders nothing — a working feature says nothing.
    var cmuxStatus: CmuxSocketStatus = .ok

    /// Whether the live herdr machine catalog has an enabled machine. The
    /// federated panel row is offered only in that state; refreshed with the
    /// rest of the pane.
    public internal(set) var hasEnabledHerdrMachine = false
    /// The local panel-row action's one-line outcome. Set only after the
    /// action runs; cleared when a new local panel offer is requested.
    public internal(set) var localHerdrPanelResult: String?
    /// What this Mac's herdr config holds, refreshed with the rest of the
    /// pane and after the local panel action.
    public internal(set) var localHerdrPanelStatus: ClaudeRemoteEnrollmentService.LocalHerdrPanelStatus = .unknown
    /// The plain-ssh join's setup step, refreshed with the rest of the pane.
    var shellSetupStatus = ClaudeShellSetupStatus()

    // MARK: - Integrations rows (Settings → Integrations)

    /// The local plugin's install state, refreshed with the rest of the pane
    /// and after every plugin action. Starts unknown: nothing has probed yet.
    public internal(set) var localPluginStatus: ClaudePluginStatus = .unknown
    /// The status line's state, refreshed with the rest of the pane.
    public internal(set) var statuslineStatus: ClaudeStatuslineInstallService.Status = .unknown
    /// Short outcome of the last statusline action, e.g. "Installed.".
    public internal(set) var statuslineResult: String?
    public internal(set) var isPerformingStatuslineAction = false
    /// The opencode plugin's state, refreshed with the rest of the pane.
    public internal(set) var opencodeStatus: OpencodePluginInstallService.Status = .unknown
    /// Short outcome of the last opencode action, e.g. "Installed.".
    public internal(set) var opencodeResult: String?
    public internal(set) var isPerformingOpencodeAction = false
    /// The Mistral Vibe hooks' state, refreshed with the rest of the pane.
    public internal(set) var vibeStatus: VibeHooksInstallService.Status = .unknown
    /// Short outcome of the last Vibe action, e.g. "Installed.".
    public internal(set) var vibeResult: String?
    public internal(set) var isPerformingVibeAction = false
    /// Whether the herdr row is shown at all. Refreshed with the rest of the
    /// pane; hidden until something reports herdr.
    public internal(set) var isHerdrDetected = false
    /// Enrolled-host labels whose live sessions currently report a herdr pane,
    /// refreshed with the rest of the pane. The herdr pane lists these names;
    /// empty when no enrolled host reports one (a LOCAL herdr pane is never
    /// listed — it belongs to no enrolled host).
    public internal(set) var herdrPaneHostLabels: [String] = []

    /// The herdr row's one status sentence. A constant: the row is
    /// status-only, and presence is the whole fact.
    public static let herdrDetectedSentence = "Found; panes join automatically."

    /// The password field's live text. Never seeded from the Keychain: the
    /// stored secret is not shown back to anyone, and an empty field on a
    /// machine that HAS a password must not read as "no password set" — which
    /// is what `hasCmuxPassword` is for.
    var cmuxPasswordField = ""

    /// Whether a password is stored, refreshed after every save. A Bool, never
    /// the value or its length.
    var hasCmuxPassword = false

    /// One short line under the cmux row: the socket's last word, or the setup
    /// state when it has not spoken yet.
    var cmuxStatusText: String {
        if let message = cmuxStatus.message { return message }
        return hasCmuxPassword ? "Password saved." : "No password saved."
    }

    /// Enrollment form. Free-form because the user is typing; validated on
    /// submit, not on every keystroke — a field that shouts while you are still
    /// typing the second character is hostile.
    public var enrollLabel = ""
    public var enrollSSHAlias = ""

    public var canEnroll: Bool {
        !ClaudeRemoteHostRegistry.sanitizeLabel(enrollLabel).isEmpty
            && ClaudeRemoteEnrollmentService.isValidHostAlias(enrollSSHAlias)
    }

    // MARK: - Dependencies

    let registry: ClaudeRemoteHostRegistry?
    /// The user's login shell, or nil for one this app will not write for.
    /// Injected so no test spawns `dscl`.
    let loginShell: @Sendable () -> ClaudeShellKind?
    /// Reads and writes the rc block for a shell. Nil disables the whole
    /// setup step — which is what a test that forgets to inject must get, so
    /// nothing can touch a real `~/.zshrc`.
    let shellRCWriter: @Sendable (ClaudeShellKind) -> ClaudeShellRCWriter?
    /// Does any live remote session report a local tty? Nil means "no way to
    /// ask", which reports as no sessions rather than as a failure.
    let liveLocalTTYReport: @Sendable () -> ClaudeShellSetupStatus.CrossingState
    /// stdout of `claude plugin list`, or nil when the listing is
    /// unavailable. Async because the listing shells out; injected so tests
    /// drive the status derivation from fixtures.
    let fetchPluginListOutput: @Sendable () async -> String?
    /// stdout of `claude plugin marketplace list --json`. Same shape and same
    /// reason as the listing above: it shells out, so it is async and injected.
    let fetchMarketplaceListOutput: @Sendable () async -> String?
    /// The marketplace path this app wants Claude Code to hold — its own
    /// mirror (`ClaudeMarketplaceMirror`). Nil where nothing models it, which
    /// makes the launch repair decide "no" rather than guess.
    ///
    /// A CLOSURE, read when the repair runs. This model is built during app
    /// startup, BEFORE the launch maintenance that creates the mirror; a value
    /// captured then is nil for the whole of the first launch after an update,
    /// which is precisely the launch that has a rotting registration to take
    /// over (review, 2026-09-21).
    let desiredMarketplacePath: @Sendable () -> String?
    /// The bundled local plugin's `plugin.json` version, for the update
    /// comparison. Nil when the bundled manifest could not be read.
    let bundledPluginVersion: String?
    /// Reads and writes the `statusLine` key. Nil disables the row's actions.
    let statuslineService: @Sendable () -> ClaudeStatuslineInstallService?
    /// The hook command the statusline entry points at, e.g.
    /// `/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook
    /// --statusline`. Nil when the publisher binary cannot be located — the
    /// row then cannot offer Install.
    let statuslineHookCommand: @Sendable () -> String?
    /// Copies the bundled opencode plugin and edits `tui.json`. Nil disables
    /// the row's actions.
    let opencodeService: @Sendable () -> OpencodePluginInstallService?
    /// Copies the bundled Vibe shim and edits `~/.vibe/hooks.toml`. Nil
    /// disables the row's actions.
    let vibeService: @Sendable () -> VibeHooksInstallService?
    /// The files the setup run writes onto a host that has Vibe. Nil skips
    /// that step, which is what a test that injects nothing gets.
    let vibeRemoteFiles: @Sendable () -> VibeRemoteHooksFiles?
    /// Hosts whose last setup run, this app session, found no Vibe. Not
    /// persisted, like the plugin version report: after a relaunch the run is
    /// offered again, which is also how a Vibe installed later gets its hooks.
    var hostsWithoutVibe: Set<String> = []
    /// The same for Claude Code: a host set up for Vibe alone never reports a
    /// plugin version, and without this its row would offer the run forever.
    var hostsWithoutClaude: Set<String> = []
    /// Whether a herdr binary is on this Mac's PATH. Synchronous and fast,
    /// so the row's visibility is reserved at construction instead of
    /// popping in after the first async refresh.
    let herdrBinaryAvailable: @Sendable () -> Bool
    /// Whether any live session — local or remote — reports a herdr pane.
    /// Refreshed with the rest of the pane. Injected so tests pin row
    /// visibility without a herdr install.
    let herdrPresenceReport: @Sendable () -> Bool
    /// Host ids whose live REMOTE sessions report a herdr pane, for the
    /// herdr pane's host-name list. Injected for the same reason; the model
    /// maps ids to the enrolled labels it already renders.
    let herdrPaneReportingHostIDs: @Sendable () -> [String]
    /// herdr's saved-machine catalog, re-read with the enrolled hosts so the
    /// candidate rows stay true to both. A `HerdrMachineFederationReader`-
    /// shaped seam: injected so tests pin candidates without herdr state on
    /// disk; production passes the live reader's `catalog()` at the
    /// construction site, and the default is absent (no machines).
    let herdrMachineCatalogReading: @Sendable () -> HerdrMachineCatalogReading
    /// Whether the live herdr machine catalog currently has an enabled
    /// machine. Injected so tests pin the federated row's visibility without
    /// reading herdr's state files.
    let hasEnabledHerdrMachineReport: @Sendable () -> Bool
    let listener: (any ClaudeRemoteListenerControlling)?
    let pluginService: @Sendable () -> any ClaudePluginInstalling
    let enrollmentService: ClaudeRemoteEnrollmentService
    /// Runs one plugin action and returns its failure, or nil.
    ///
    /// Off the main actor by default: `claude plugin install` fetches, and 60s
    /// of beachball is not a UI. Injected so tests run it synchronously — the
    /// production hop would make every assertion a race.
    let performAsync:
        @Sendable (@escaping @Sendable () throws -> Void) async -> ClaudePluginActionFailure?
    let performEnrollmentAsync:
        @Sendable (@escaping @Sendable () throws -> [ClaudeRemoteEnrollmentService.ExecutionStep]) async
            -> ClaudeEnrollmentActionAttempt
    let performVerificationAsync:
        @Sendable (@escaping @Sendable () throws -> [ClaudeRemoteEnrollmentService.VerificationCheck]) async
            -> ClaudeVerificationAttempt
    /// Injected wall clock, read once per refresh to age the host rows. No
    /// `Date()` in the view, and no timer: the rows are rebuilt when the pane
    /// appears and after every action that touches a host.
    let now: @Sendable () -> Date
    /// This Mac's allocated port on the remote side of the tunnel
    /// (`ClaudeRemoteForwardPort`), passed in rather than read here so the pane
    /// has no opinion about where it comes from — and so a test can pin it.
    /// Every generated artifact that names a remote port takes it from this one
    /// value: the ssh block, the install command, the verify probe, the
    /// update/migration commands.
    let remoteForwardPort: UInt16
    /// Keychain-backed cmux password storage. Nil in previews and in tests that
    /// do not exercise the cmux row — the row then reports that it cannot save,
    /// rather than silently pretending it did.
    let cmuxPasswords: (any CmuxPasswordStoring)?
    /// Owns the app-held ssh forwards. Optional for the same reason `listener`
    /// is: previews and plugin-only tests have none, and the pane then simply
    /// does not offer the toggle.
    let forwards: ClaudeRemoteForwardCoordinator?

    /// - Parameters:
    ///   - registry: nil when the host file could not be read at launch. The
    ///     pane then shows the remote surface as unavailable rather than
    ///     offering an Enroll button that cannot work.
    ///   - listener: nil in previews and in tests that only exercise the plugin
    ///     half.
    public init(
        registry: ClaudeRemoteHostRegistry?,
        listener: (any ClaudeRemoteListenerControlling)?,
        pluginService: @escaping @Sendable () -> any ClaudePluginInstalling,
        enrollmentService: ClaudeRemoteEnrollmentService = ClaudeRemoteEnrollmentService(),
        performAsync: @escaping @Sendable (@escaping @Sendable () throws -> Void) async -> ClaudePluginActionFailure? = { body in
            await Task.detached(priority: .userInitiated) {
                do {
                    try body()
                    return nil
                } catch {
                    return ClaudePluginActionFailure(error)
                }
            }.value
        },
        performEnrollmentAsync: @escaping @Sendable (
            @escaping @Sendable () throws -> [ClaudeRemoteEnrollmentService.ExecutionStep]
        ) async -> ClaudeEnrollmentActionAttempt = { body in
            await Task.detached(priority: .userInitiated) {
                do {
                    return ClaudeEnrollmentActionAttempt(steps: try body(), failure: nil)
                } catch {
                    return ClaudeEnrollmentActionAttempt(
                        steps: [],
                        failure: ClaudeEnrollmentActionFailure(error)
                    )
                }
            }.value
        },
        performVerificationAsync: @escaping @Sendable (
            @escaping @Sendable () throws -> [ClaudeRemoteEnrollmentService.VerificationCheck]
        ) async -> ClaudeVerificationAttempt = { body in
            await Task.detached(priority: .userInitiated) {
                do {
                    return ClaudeVerificationAttempt(checks: try body(), failure: nil)
                } catch {
                    return ClaudeVerificationAttempt(
                        checks: [],
                        failure: ClaudeEnrollmentActionFailure(error)
                    )
                }
            }.value
        },
        now: @escaping @Sendable () -> Date = { Date() },
        // Defaults to the legacy shared port: a caller that has not been taught
        // about per-Mac allocation describes exactly the pre-#215 setup, which
        // still works. Production passes the allocation.
        remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort,
        cmuxPasswords: (any CmuxPasswordStoring)? = nil,
        forwards: ClaudeRemoteForwardCoordinator? = nil,
        loginShell: @escaping @Sendable () -> ClaudeShellKind? = { nil },
        shellRCWriter: @escaping @Sendable (ClaudeShellKind) -> ClaudeShellRCWriter? = { _ in nil },
        liveLocalTTYReport: @escaping @Sendable () -> ClaudeShellSetupStatus.CrossingState = {
            .noSessions
        },
        fetchPluginListOutput: @escaping @Sendable () async -> String? = { nil },
        fetchMarketplaceListOutput: @escaping @Sendable () async -> String? = { nil },
        desiredMarketplacePath: @escaping @Sendable () -> String? = { nil },
        bundledPluginVersion: String? = nil,
        statuslineService: @escaping @Sendable () -> ClaudeStatuslineInstallService? = { nil },
        statuslineHookCommand: @escaping @Sendable () -> String? = { nil },
        opencodeService: @escaping @Sendable () -> OpencodePluginInstallService? = { nil },
        vibeService: @escaping @Sendable () -> VibeHooksInstallService? = { nil },
        vibeRemoteFiles: @escaping @Sendable () -> VibeRemoteHooksFiles? = { nil },
        herdrBinaryAvailable: @escaping @Sendable () -> Bool = { false },
        herdrPresenceReport: @escaping @Sendable () -> Bool = { false },
        herdrPaneReportingHostIDs: @escaping @Sendable () -> [String] = { [] },
        herdrMachineCatalogReading: @escaping @Sendable () -> HerdrMachineCatalogReading = {
            .absent
        },
        hasEnabledHerdrMachineReport: @escaping @Sendable () -> Bool = { false }
    ) {
        self.loginShell = loginShell
        self.shellRCWriter = shellRCWriter
        self.liveLocalTTYReport = liveLocalTTYReport
        self.fetchPluginListOutput = fetchPluginListOutput
        self.fetchMarketplaceListOutput = fetchMarketplaceListOutput
        self.desiredMarketplacePath = desiredMarketplacePath
        self.bundledPluginVersion = bundledPluginVersion
        self.statuslineService = statuslineService
        self.statuslineHookCommand = statuslineHookCommand
        self.opencodeService = opencodeService
        self.vibeService = vibeService
        self.vibeRemoteFiles = vibeRemoteFiles
        self.herdrBinaryAvailable = herdrBinaryAvailable
        self.herdrPresenceReport = herdrPresenceReport
        self.herdrPaneReportingHostIDs = herdrPaneReportingHostIDs
        self.herdrMachineCatalogReading = herdrMachineCatalogReading
        self.hasEnabledHerdrMachineReport = hasEnabledHerdrMachineReport
        hasEnabledHerdrMachine = hasEnabledHerdrMachineReport()
        // m8: reserve the herdr row's visibility synchronously — the binary
        // check is a fast PATH scan, so herdr machines paint the row on
        // first paint instead of gaining it one beat late. The session half
        // still refreshes below.
        isHerdrDetected = herdrBinaryAvailable()
        self.registry = registry
        self.listener = listener
        self.pluginService = pluginService
        self.enrollmentService = enrollmentService
        self.performAsync = performAsync
        self.performEnrollmentAsync = performEnrollmentAsync
        self.performVerificationAsync = performVerificationAsync
        self.now = now
        self.remoteForwardPort = remoteForwardPort
        self.cmuxPasswords = cmuxPasswords
        self.forwards = forwards
        refreshHosts()
        refreshListenerStatus()
        // A presence check, not a read into any field: this is the one place
        // the stored secret is touched at construction, and only to answer
        // "is one set".
        hasCmuxPassword = cmuxPasswords?.password() != nil
        // The pane renders COPIES of the rows, so without this the tunnel
        // status is whatever it happened to be when Settings appeared: the
        // first "Connecting…" snapshot, frozen, while the real supervisor goes
        // on to forward, retry, or fail where nobody can see it. Every
        // transition now patches its row in place.
        forwards?.onStateChange = { [weak self] hostID in
            self?.applyForwardState(hostID: hostID)
        }
    }

    /// Patch one row's forward fields from the coordinator.
    ///
    /// Deliberately NOT `refreshHosts()`: that re-reads the registry file and
    /// re-derives every row's age text, which is a lot of work to do on a
    /// transition that changed one string — and it would move the "last seen"
    /// times under the user mid-read for a reason they never asked for.
    private func applyForwardState(hostID: String) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        let state = forwards?.states[hostID]
        hosts[index].forwardStatusText = state?.text
        hosts[index].forwardIsFailure = state?.isFailure ?? false
    }
}
