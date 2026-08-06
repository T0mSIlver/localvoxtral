import AppKit
import ClaudeContextWire
import SwiftUI
import Synchronization

@main
struct localvoxtralApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverView(viewModel: appDelegate.viewModel)
        } label: {
            let viewModel = appDelegate.viewModel
            let state = viewModel.menuBarIndicatorState
            if let idleIcon = MenuBarIconAsset.idleIcon {
                let iconConfiguration: (
                    icon: NSImage,
                    renderingMode: Image.TemplateRenderingMode,
                    id: String,
                    label: String
                ) = {
                    switch state {
                    case .idle:
                        return (idleIcon, .template, "realtime-idle", "localvoxtral")
                    case .connected:
                        if let connectedIcon = MenuBarIconAsset.connectedIcon {
                            return (
                                connectedIcon,
                                .original,
                                "realtime-connected",
                                "localvoxtral, realtime session active"
                            )
                        }
                        return (
                            idleIcon,
                            .template,
                            "realtime-connected",
                            "localvoxtral, realtime session active"
                        )
                    case .secureInputWarning:
                        if let failureIcon = MenuBarIconAsset.failureIcon {
                            return (
                                failureIcon,
                                .original,
                                "secure-input-warning",
                                "localvoxtral, Secure Keyboard Entry is blocking dictation typing"
                            )
                        }
                        return (
                            idleIcon,
                            .template,
                            "secure-input-warning",
                            "localvoxtral, Secure Keyboard Entry is blocking dictation typing"
                        )
                    case .failure:
                        if let failureIcon = MenuBarIconAsset.failureIcon {
                            return (
                                failureIcon,
                                .original,
                                "realtime-failed",
                                viewModel.realtimeSessionIndicatorState == .recentFailure
                                    ? "localvoxtral, realtime connection failed recently"
                                    : "localvoxtral, dictation backend not ready"
                            )
                        }
                        return (
                            idleIcon,
                            .template,
                            "realtime-failed",
                            viewModel.realtimeSessionIndicatorState == .recentFailure
                                ? "localvoxtral, realtime connection failed recently"
                                : "localvoxtral, dictation backend not ready"
                        )
                    }
                }()

                Image(nsImage: iconConfiguration.icon)
                    .resizable()
                    .renderingMode(iconConfiguration.renderingMode)
                    .scaledToFit()
                    .frame(width: 13, height: 16)
                    .id(iconConfiguration.id)
                    .accessibilityLabel(iconConfiguration.label)
            } else {
                switch state {
                case .idle:
                    Label("localvoxtral", systemImage: "waveform.circle")
                case .connected:
                    Label("localvoxtral", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure:
                    Label("localvoxtral", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .secureInputWarning:
                    Label("localvoxtral", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                settings: appDelegate.settingsStore,
                viewModel: appDelegate.viewModel,
                backendManager: appDelegate.backendManager,
                navigator: appDelegate.settingsNavigator
            )
            .frame(minWidth: 560, idealWidth: 580, minHeight: 380, idealHeight: 420)
        }
        .defaultSize(width: 580, height: 420)
        .restorationBehavior(.disabled)
    }
}

/// Owns the shared model graph and presents the first-launch onboarding wizard.
/// A menu-bar (LSUIElement) app has no launch window scene, so the wizard is
/// shown here from `applicationDidFinishLaunching`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore: SettingsStore
    let backendManager: BackendManager
    let viewModel: DictationViewModel
    let settingsNavigator = SettingsNavigator()

    private var onboardingController: OnboardingWindowController?
    private let appConfigStore = AppConfigStore()

    /// Claude Code session context. The registry is the app's memory of live
    /// sessions; the broker is the socket that feeds it.
    ///
    /// Owned HERE rather than by `DictationViewModel` because the hooks fire on
    /// Claude Code's schedule, not on dictation's: a session's marker and cwd
    /// are published while the user is typing, long before they press the hotkey.
    /// A broker that only listened during a dictation session would miss the very
    /// records it exists to collect.
    private let claudeSessionRegistry = ClaudeSessionRegistry()
    private var claudeContextBroker: ClaudeContextBroker?
    private var terminalConsentPrewarmObserver:
        TerminalAutomationConsentPrewarmSettingsObserver?
    /// The browser half of the same pre-warm, kept separate because it is armed
    /// by a NARROWER setting: only the Claude session/repo context feature can
    /// use a browser tab join.
    private var browserConsentPrewarmObserver:
        TerminalAutomationConsentPrewarmSettingsObserver?
    /// Remote (SSH) Claude Code sessions. Both the host registry and the
    /// listener are lazy and optional: a user who has never enrolled a host has
    /// no file to read and no port bound.
    private var claudeRemoteHosts: ClaudeRemoteHostRegistry?
    /// Owns the listener and the bind/unbind decision. Settings reconciles
    /// through it on every enroll/revoke, so the port follows enrollment without
    /// a relaunch.
    private var claudeRemoteListenerCoordinator: ClaudeRemoteListenerCoordinator?
    /// Owns the opt-in app-held `ssh -N -R` forwards. Started only after the
    /// listener binds, and torn down before the app exits so no orphan ssh
    /// outlives the process that spawned it.
    private var claudeRemoteForwards: ClaudeRemoteForwardCoordinator?
    /// Customized-but-outdated config files awaiting the user's
    /// update-or-keep decision; held here while onboarding is on screen.
    private var pendingConfigDefaultsPromptFileNames: [String]?

    override init() {
        let settings = SettingsStore()
        let manager = BackendManager(
            polishingModelProvider: { settings.resolvedManagedLLMPolishingModel },
            speechdCacheLimitProvider: { settings.speechdCacheLimit.megabytes },
            speechdStepCadenceProvider: { settings.speechdStepCadence.milliseconds }
        )
        settingsStore = settings
        backendManager = manager
        viewModel = DictationViewModel(settings: settings, backendManager: manager)
        super.init()
        viewModel.onRequestReRunOnboarding = { [weak self] in
            self?.presentOnboarding()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sweep both retired Python backend installs off existing user Macs.
        Task.detached(priority: .utility) {
            LegacyMLXLMCleanup().run()
            LegacyVoxmlxCleanup().run()
        }
        startClaudeContextBroker()
        startClaudeRemoteListener()
        reconcileBundledConfigDefaults()
        viewModel.preflightConfiguredLocalNetworkEndpoints()
        guard !settingsStore.onboardingCompleted else { return }
        presentOnboarding()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Unlinks the socket, so a publisher from a surviving Claude Code
        // session fails open (silent exit 0) instead of blocking on a path
        // nothing is accepting on.
        claudeContextBroker?.stop()
        claudeContextBroker = nil
        terminalConsentPrewarmObserver = nil
        browserConsentPrewarmObserver = nil
        // Closes the port, so a hook from a surviving remote session gets a
        // connection refused through the tunnel and fails open. Quitting says
        // nothing about enrollment — the hosts stay enrolled for next launch.
        // Forwards first, listener second — the mirror of startup order.
        claudeRemoteForwards?.stopAll()
        // `stopAll` only STARTS each SIGTERM→SIGKILL escalation. Returning
        // here without it finishing is how an ssh that is slow to die outlives
        // the app: reparented to launchd, still holding the remote bind, and
        // no longer reachable by anything that could kill it — so the next
        // launch finds its own port taken. The wait is bounded and short; a
        // quit must never hang on a wedged network.
        drainRemoteForwardTeardowns(within: 3.0)
        claudeRemoteForwards = nil
        claudeRemoteListenerCoordinator?.shutdown()
        claudeRemoteListenerCoordinator = nil
        viewModel.claudeIntegrationSettings = nil
        TerminalScreenRawAttachmentPolicy.configure(authorizer: nil)
        // The resolver holds the registry; the view model must not keep
        // resolving joins against sessions nothing is feeding any more.
        viewModel.claudeSessionJoinResolver = nil
        viewModel.claudeSessionJoin = nil
        // Quitting mid-dictation must take every remote herdr `ssh -L` with us.
        // Asked of the view model, which OWNS them: during polish the join has
        // already been consumed, so a quit that reached the child only through
        // `claudeSessionJoin` found nil and left the ssh running past app exit
        // (review finding 4).
        viewModel.closeRemoteHerdrForwards()
    }

    /// Spin the run loop until every forward teardown has finished, or the
    /// deadline passes.
    ///
    /// `applicationWillTerminate` is synchronous and cannot await, but the
    /// escalation it just started is asynchronous — so this pumps the main run
    /// loop, which is what lets those tasks make progress while we wait. The
    /// deadline is the point: a wedged ssh must cost the user a bounded pause
    /// at quit, never a hang, and the escalation's own SIGKILL means the
    /// ordinary case finishes far inside it.
    private func drainRemoteForwardTeardowns(within seconds: TimeInterval) {
        guard let teardowns = claudeRemoteForwards?.drainingTeardowns, !teardowns.isEmpty else {
            return
        }
        let deadline = Date().addingTimeInterval(seconds)
        let finished = Mutex(false)
        Task { @MainActor in
            for teardown in teardowns { await teardown.value }
            finished.withLock { $0 = true }
        }
        while !finished.withLock({ $0 }), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if !finished.withLock({ $0 }) {
            Log.claudeContext.error(
                "Claude remote forward teardown did not finish before quit; an ssh may survive this process"
            )
        }
    }

    /// Binds the hook socket and installs the pane authorizer that depends on it.
    ///
    /// Failure is non-fatal by design: the app's own dictation does not need the
    /// broker, and a user who never installed the plugin should not see an error
    /// about it. But it is LOUD in the log (AGENTS: a silent failure path is how
    /// the ensureReady bug cost an hour of remote probing), and the authorizer is
    /// only installed on success — so a build where the broker never bound
    /// degrades to vocabulary-only screen context rather than to an unguarded
    /// attachment.
    private func startClaudeContextBroker() {
        guard let socketPath = ClaudeHookSocketPath.resolve() else {
            Log.claudeContext.error("Claude context broker not started: no socket path (HOME unset)")
            return
        }
        let broker = ClaudeContextBroker(
            socketPath: socketPath,
            registry: claudeSessionRegistry,
            shouldEmitLocalTitleMarker:
                settingsStore.makeClaudeLocalTitleMarkerFallbackProvider()
        )
        do {
            try broker.start()
            claudeContextBroker = broker
            // ONE resolver, shared by the view model (which resolves the join at
            // dictation start) and the attachment authorizer (which consults
            // that join at commit). Sharing it is what makes the screen excerpt,
            // the session's prior prompt, and the repository context describe the
            // same session — three resolvers would each answer honestly about a
            // different moment.
            // The tty/herdr seams are wired here, not defaulted: sending Apple
            // events, reading the process table, and connecting to a user's
            // local socket are live capabilities, so only the app — never a
            // test that forgot to inject — constructs them.
            let ttyReader = AppleScriptTerminalTTYReader()
            let browserTabReader = AppleScriptFocusedBrowserTabURLReader()
            // The cmux password is read from the Keychain lazily, per query, so
            // a user who never enables the arm is never prompted for keychain
            // access and the secret is not held in memory between dictations.
            let cmuxPasswords = CmuxSocketPasswordStore()
            let resolver = ClaudeSessionJoinResolver(
                registry: claudeSessionRegistry,
                focusedTerminalTTY: { await ttyReader.focusedTerminalTTY(bundleID: $0) },
                focusedBrowserTabURL: { await browserTabReader.focusedTabURL(bundleID: $0) },
                herdrClientProbe: {
                    HerdrClientTTYProbe.isHerdrClient(onTTYDevicePath: $0)
                },
                herdrPanes: HerdrSocketClient(),
                cmuxSurfaces: CmuxSocketClient(password: { cmuxPasswords.password() }),
                cmuxJoinEnabled: { [weak viewModel] in
                    viewModel?.settings.cmuxSurfaceJoinEnabled ?? false
                },
                reportCmuxStatus: { [weak viewModel] status in
                    viewModel?.claudeIntegrationSettings?.cmuxStatus = status
                },
                sshDestinationProbe: {
                    SSHDestinationTTYProbe.connection(onTTYDevicePath: $0)
                },
                // Read through the property rather than captured: the host
                // registry is built later in launch than this resolver (and not
                // at all for a user with no enrolled host), so the lookup has
                // to be asked at dictation time, not wired at launch time. No
                // registry ⇒ no candidates ⇒ the remote herdr arm never runs.
                enrolledHosts: { [weak self] destination in
                    self?.claudeRemoteHosts?.hosts(matchingSSHDestination: destination) ?? []
                },
                remoteHerdrForwards: ClaudeRemoteHerdrForwardService(
                    spawner: ClaudeRemoteHerdrForwardSpawner(),
                    workspaces: ClaudeRemoteHerdrForwardWorkspaces()
                )
            )
            viewModel.claudeSessionJoinResolver = resolver
            // Pre-warm the Automation consent sheet OFF the dictation-start
            // path: the first Apple event to a terminal blocks in TCC until
            // the user answers, and that freeze must not land mid-dictation.
            // One pre-warm per supported terminal (each is its own TCC pair),
            // firing only while that terminal is running. Only for users who
            // opted into a context feature — the pre-warm is itself the
            // consent prompt, and an opted-out user must never see it.
            let settings = viewModel.settings
            let prewarmObserver = TerminalAutomationConsentPrewarmSettingsObserver(
                settings: settings,
                prewarm: {
                    // Apple-event terminals only: cmux is joinable but has no
                    // scripting dictionary, so pre-warming it would raise a
                    // consent prompt for something we never ask it.
                    for bundleID in TerminalScreenAllowlist.appleEventBundleIDs.sorted() {
                        TerminalAutomationConsentPrewarm.fireOnceWhenTerminalIsAvailable(
                            bundleID: bundleID,
                            isStillEnabled: { [weak settings] in
                                settings?.terminalScreenContextEnabled == true
                                    || settings?.claudeRepoContextEnabled == true
                            }
                        )
                    }
                },
                // Turning both context features off disarms whatever is still
                // waiting for a terminal to launch: consent is only ever asked
                // for a feature that is ON.
                disarm: {
                    for bundleID in TerminalScreenAllowlist.supportedBundleIDs.sorted() {
                        TerminalAutomationConsentPrewarm.cancelPendingPrewarm(bundleID: bundleID)
                    }
                }
            )
            terminalConsentPrewarmObserver = prewarmObserver
            prewarmObserver.start()
            // The same pre-warm for the browsers a Claude Code "Remote
            // Control" tab can live in — each is its own TCC Automation pair,
            // and the consent sheet dies with the 1 s read that raised it, so
            // without this the browser join could never become grantable.
            // Armed by the session-context setting ALONE: a browser join
            // authorizes no screen read, so a user who enabled only screen
            // context is never asked to let us automate their browser.
            let browserPrewarmObserver = TerminalAutomationConsentPrewarmSettingsObserver(
                settings: settings,
                prewarm: {
                    for bundleID in BrowserTabAllowlist.supportedBundleIDs.sorted() {
                        TerminalAutomationConsentPrewarm.fireOnceWhenTerminalIsAvailable(
                            bundleID: bundleID,
                            // Re-read when the sheet would actually be raised.
                            // A browser that launches days after the user
                            // turned the feature back off must not be asked.
                            isStillEnabled: { [weak settings] in
                                settings?.claudeRepoContextEnabled == true
                            }
                        )
                    }
                },
                disarm: {
                    for bundleID in BrowserTabAllowlist.supportedBundleIDs.sorted() {
                        TerminalAutomationConsentPrewarm.cancelPendingPrewarm(bundleID: bundleID)
                    }
                },
                enablement: { $0.claudeRepoContextEnabled }
            )
            browserConsentPrewarmObserver = browserPrewarmObserver
            browserPrewarmObserver.start()
            // The join gate for raw terminal screen attachment. Installed only
            // now: without a running broker there are no markers to resolve, and
            // an authorizer over an empty registry would answer `.unknown` to
            // everything anyway — but making the dependency explicit is what
            // keeps "no broker ⇒ no raw attachment" true by construction rather
            // than by coincidence.
            TerminalScreenRawAttachmentPolicy.configure(
                authorizer: TerminalScreenClaudeJoinAuthorizer(
                    resolver: resolver,
                    currentJoin: { [weak viewModel] in viewModel?.claudeSessionJoin }
                )
            )
        } catch {
            Log.claudeContext.error(
                "Claude context broker failed to start: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Binds the remote (SSH) hook listener, but only for a user who has
    /// actually enrolled a host.
    ///
    /// "No enrollment ⇒ no open port" is the point: everyone else's Mac gets
    /// exactly what it had before, with nothing listening on 8473. That is also
    /// why the host registry is constructed here rather than as a stored
    /// property — reading (and failing to read) a file nobody has is not
    /// something to do at init.
    ///
    /// Failure is non-fatal and loud, matching the local broker. The coordinator
    /// — not this method — owns the bind/unbind decision from here on, so
    /// enrolling the first host in Settings binds the port immediately and
    /// revoking the last one closes it. There is no relaunch step.
    private func startClaudeRemoteListener() {
        let registry: ClaudeRemoteHostRegistry?
        do {
            registry = try ClaudeRemoteHostRegistry()
        } catch {
            // The list exists but is unreadable — a state the user must be able
            // to SEE, not just one we log. The Settings row says the list could
            // not be read rather than offering an Enroll button that would
            // silently fail.
            Log.claudeContext.error(
                "Claude remote host registry unreadable: \(String(describing: error), privacy: .public)"
            )
            registry = nil
        }
        claudeRemoteHosts = registry

        let coordinator = registry.map { hosts in
            ClaudeRemoteListenerCoordinator(hosts: hosts, sessions: claudeSessionRegistry)
        }
        claudeRemoteListenerCoordinator = coordinator

        // The per-Mac remote listen port (issue #215). Read once, here, so
        // every generated artifact in this launch agrees; reading it is also
        // what mints the install identity on a first run, and it must not be
        // minted lazily inside a sheet that a test could reach.
        let remoteForwardPort = viewModel.settings.claudeRemoteForwardPort
        Log.claudeContext.info(
            "Claude remote forward port allocated: \(remoteForwardPort, privacy: .public)"
        )

        // App-held ssh forwards, for hosts that opted in. Constructed with the
        // listener coordinator's bind state as its gate: a forward into an
        // unbound port is worse than no forward (silent fail-open on the remote,
        // plus ssh noise in the user's terminal), so it refuses to run without
        // one. The listener is reconciled FIRST, below.
        // Every spawned forward ssh is recorded here, and orphans a previous
        // run left holding the remote port (crash, force-quit, a teardown that
        // outran the quit drain) are killed before this run's forwards dial —
        // otherwise the fresh forward is refused its own port and the pane
        // reports "Port held" terminally at this Mac's own leftover.
        let forwardPidLedger = ClaudeRemoteForwardPidLedger()
        let forwardOrphanReaper = ClaudeRemoteForwardOrphanReaper(ledger: forwardPidLedger)
        let forwards = registry.map { hosts in
            ClaudeRemoteForwardCoordinator(
                hosts: hosts,
                remoteForwardPort: remoteForwardPort,
                isListenerBound: { coordinator?.isListening ?? false },
                pidLedger: forwardPidLedger,
                reapOrphans: { await forwardOrphanReaper.reap() }
            )
        }
        claudeRemoteForwards = forwards

        viewModel.claudeIntegrationSettings = ClaudeIntegrationSettingsModel(
            registry: registry,
            listener: coordinator,
            pluginService: { ClaudePluginInstallService.live() },
            enrollmentService: ClaudeRemoteEnrollmentService.live(),
            remoteForwardPort: remoteForwardPort,
            cmuxPasswords: CmuxSocketPasswordStore(),
            forwards: forwards
        )

        // Route launch through the same model that owns the Settings status.
        // Calling the coordinator directly would bind successfully while the
        // pane stayed at `.idle`, and would make a launch-time port conflict
        // log-only with no Retry action.
        viewModel.claudeIntegrationSettings?.synchronizeListenerAtLaunch()
    }

    /// Brings existing installs up to date with this build's bundled config
    /// defaults: unedited stale seeds are refreshed silently; customized files
    /// are never touched without asking. When onboarding is still due (a
    /// pre-onboarding install upgrading, or a wizard never finished), the
    /// prompt is held until the wizard closes so the modal never stacks on
    /// top of it.
    private func reconcileBundledConfigDefaults() {
        let outcome = appConfigStore.reconcileBundledDefaults()
        guard !outcome.customizedOutdatedFileNames.isEmpty else { return }
        pendingConfigDefaultsPromptFileNames = outcome.customizedOutdatedFileNames
        guard settingsStore.onboardingCompleted else { return }

        // Defer past launch so the alert never blocks
        // applicationDidFinishLaunching.
        Task { @MainActor in
            self.presentPendingConfigDefaultsPromptIfNeeded()
        }
    }

    private func presentPendingConfigDefaultsPromptIfNeeded() {
        guard let fileNames = pendingConfigDefaultsPromptFileNames else { return }
        pendingConfigDefaultsPromptFileNames = nil
        promptToUpdateCustomizedConfigFiles(fileNames: fileNames)
    }

    private func promptToUpdateCustomizedConfigFiles(fileNames: [String]) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Updated default config files"
        let fileList = fileNames.map { "•  \($0)" }.joined(separator: "\n")
        let single = fileNames.count == 1
        alert.informativeText = """
        This version of localvoxtral improves the default content of:

        \(fileList)

        You've edited \(single ? "this file" : "these files"), so \(single ? "it was" : "they were") left untouched.

        Update replaces \(single ? "it" : "them") with the new defaults and saves your \(single ? "version" : "versions") alongside as .backup files. Keep Mine won't ask again until the defaults next change.
        """
        alert.addButton(withTitle: "Update (Keep Backups)")
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Show Files…")

        decision: while true {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let backups = appConfigStore.adoptBundledDefaults(fileNames: fileNames)
                Log.config.notice(
                    "User adopted new bundled defaults for \(fileNames.joined(separator: ", "), privacy: .public); backups: \(backups.joined(separator: ", "), privacy: .public)"
                )
                break decision
            case .alertSecondButtonReturn:
                appConfigStore.recordKeptCustomizedDefaults(fileNames: fileNames)
                Log.config.notice(
                    "User kept customized config files \(fileNames.joined(separator: ", "), privacy: .public)"
                )
                break decision
            default:
                // Show Files: reveal the files in Finder and re-present the
                // alert so Update/Keep Mine stay available — Finder is a
                // separate app, so the user can inspect the files while the
                // alert waits. Quitting instead still re-prompts next launch.
                NSWorkspace.shared.activateFileViewerSelecting(
                    fileNames.map { appConfigStore.configDirectoryURL().appendingPathComponent($0) }
                )
            }
        }
    }

    private func presentOnboarding() {
        if let onboardingController {
            onboardingController.present()
            return
        }
        let controller = OnboardingWindowController(
            settings: settingsStore,
            viewModel: viewModel,
            backendManager: backendManager,
            openEndpointsSettings: { [weak self] in self?.openEndpointsSettings() }
        )
        controller.onFinished = { [weak self] in
            self?.onboardingController = nil
            // First launch skips the eager warmup (the wizard owns bootstrap);
            // once the wizard is done — finished or skipped — start whatever
            // required managed backends it didn't already start.
            self?.viewModel.warmUpManagedBackendsAtLaunchIfNeeded()
            self?.presentPendingConfigDefaultsPromptIfNeeded()
        }
        onboardingController = controller
        controller.present()
    }

    private func openEndpointsSettings() {
        settingsNavigator.selectedTab = .endpoints
        NSApp.activate(ignoringOtherApps: true)
        // AppKit entry point for the SwiftUI `Settings` scene on macOS 14+.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

@MainActor
private enum MenuBarIconAsset {
    static let idleIcon: NSImage? = loadIcon(candidates: [
        "MicIconTemplate@2x",
        "MicIconTemplate",
    ], asTemplate: true)

    static let connectedIcon: NSImage? = loadIcon(candidates: [
        "MicIconTemplate_connected",
        "MicIconTemplate@2x_connected",
    ], asTemplate: false)

    static let failureIcon: NSImage? = loadIcon(candidates: [
        "MicIconTemplate_failure",
        "MicIconTemplate@2x_failure",
    ], asTemplate: false)

    private static func loadIcon(candidates: [String], asTemplate: Bool) -> NSImage? {
        let bundle = Bundle.main
        for candidate in candidates {
            guard let iconURL = bundle.url(forResource: candidate, withExtension: "png"),
                  let image = NSImage(contentsOf: iconURL)
            else {
                continue
            }
            // Plain `@2x` filenames are already point-size normalized by AppKit.
            // Custom-suffixed variants (for example `@2x_connected`) are not.
            if candidate.contains("@2x"), !candidate.hasSuffix("@2x") {
                image.size = NSSize(width: image.size.width / 2.0, height: image.size.height / 2.0)
            }
            image.isTemplate = asTemplate
            return image
        }
        return nil
    }
}
