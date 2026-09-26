import AppKit
import ClaudeContextWire
import SwiftUI
import Synchronization

// No `@main`: `Sources/localvoxtral/main.swift` is the entry point, so
// `--probe-surface` can answer and exit before any scene is constructed.
struct localvoxtralApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverView(
                viewModel: appDelegate.viewModel, navigator: appDelegate.settingsNavigator)
        } label: {
            // The label is the one view that exists from launch, so it is
            // where the app can be handed SwiftUI's own way to open the
            // window — see `SettingsOpenerHandoff`.
            SettingsOpenerHandoff { appDelegate.settingsOpener = $0 }
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
                                    ? "localvoxtral, dictation failed recently"
                                    : "localvoxtral, dictation backend not ready"
                            )
                        }
                        return (
                            idleIcon,
                            .template,
                            "realtime-failed",
                            viewModel.realtimeSessionIndicatorState == .recentFailure
                                ? "localvoxtral, dictation failed recently"
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
                navigator: appDelegate.settingsNavigator,
                loginItem: appDelegate.loginItemController
            )
            // Fixed width, resizable height: the two-column layout has a fixed
            // 208pt sidebar and dense right-hand rows, so horizontal resizing
            // only ever makes the panes worse. Height stays free because pane
            // content differs by hundreds of points.
            //
            // Deliberately NOT `.windowResizability(.contentSize)` — that makes
            // the window snap to whichever pane is showing, so switching tabs
            // resizes the window under the pointer.
            .frame(width: 780)
            .frame(minHeight: 480, idealHeight: 560, maxHeight: .infinity)
            // Declared to SwiftUI rather than only set on the NSWindow: on
            // macOS 26 SwiftUI re-asserts its own titlebar and paints an opaque
            // strip over the sidebar (PR #310 hand-check), which AppKit flags
            // alone did not survive.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // Puts the app in the Dock and the app switcher while this window
            // is open, so it can be switched back to without going through the
            // menu bar item.
            .background {
                DockIconWindowRegistrar(policy: appDelegate.dockIconPolicy)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 780, height: 560)
        .restorationBehavior(.disabled)
    }
}

/// Hands the app delegate SwiftUI's `openSettings` action.
///
/// The delegate has to open the window at launch ("Open the window at launch",
/// #449) and is not a view, so the action has to be captured by one. The menu
/// bar item's label is the only view alive at launch — it is rendered into the
/// status item before anything else exists — and it renders nothing itself.
struct SettingsOpenerHandoff: View {
    @Environment(\.openSettings) private var openSettings
    let hand: @MainActor (@escaping @MainActor () -> Void) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { hand { openSettings() } }
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
    /// "Open localvoxtral at login". Built here so the pane reads the login
    /// item once per launch rather than on every view update.
    let loginItemController = LoginItemController()
    /// SwiftUI's own `openSettings`, handed over by the menu bar label
    /// (`SettingsOpenerHandoff`). Nil until the label has appeared.
    var settingsOpener: (@MainActor () -> Void)?
    let dockIconPolicy = DockIconPolicy(apply: AppDelegate.applyActivationPolicy)

    private var onboardingController: OnboardingWindowController?
    private let appConfigStore = AppConfigStore()

    /// Claude Code session context. The registry is the app's memory of live
    /// sessions; the broker is the socket that feeds it.
    ///
    /// Owned HERE rather than by `DictationViewModel` because the hooks fire on
    /// Claude Code's schedule, not on dictation's: a session's tty, pane and
    /// cwd are published while the user is typing, long before they press the
    /// hotkey.
    /// A broker that only listened during a dictation session would miss the very
    /// records it exists to collect.
    private let claudeSessionRegistry: ClaudeSessionRegistry
    private var claudeContextBroker: ClaudeContextBroker?
    private var terminalConsentPrewarmObserver:
        TerminalAutomationConsentPrewarmSettingsObserver?
    /// The browser half of the same pre-warm, kept separate because it is armed
    /// by a NARROWER setting: only the Claude session/repo context feature can
    /// use a browser tab join.
    private var browserConsentPrewarmObserver:
        TerminalAutomationConsentPrewarmSettingsObserver?
    /// Remote (SSH) Claude Code sessions. The host registry loads before the
    /// session cache so restore can reject revoked hosts. The listener remains
    /// optional, and a user with no active host has no port bound.
    private var claudeRemoteHosts: ClaudeRemoteHostRegistry?
    /// Owns the listener and the bind/unbind decision. Settings reconciles
    /// through it on every enroll/revoke, so the port follows enrollment without
    /// a relaunch.
    private var claudeRemoteListenerCoordinator: ClaudeRemoteListenerCoordinator?
    /// Owns the opt-in app-held `ssh -N -R` forwards. Started only after the
    /// listener binds, and torn down before the app exits so no orphan ssh
    /// outlives the process that spawned it.
    private var claudeRemoteForwards: ClaudeRemoteForwardCoordinator?
    /// Shared lifecycle for both remote-hook `-R` and remote-herdr `-L`
    /// children: one ledger/reaper sees every app-held SSH process.
    private let claudeRemoteForwardPidLedger = ClaudeRemoteForwardPidLedger()
    /// Shared by the remote listener and the forward supervisors: one mints
    /// ownership-probe nonces, the other reports the ones that arrive. It lives
    /// here because both are rebuilt independently and neither may own it.
    private let claudeRemoteForwardProbes = ClaudeRemoteForwardProbeWitness()
    private lazy var claudeRemoteHerdrForwards = ClaudeRemoteHerdrForwardService(
        spawner: ClaudeRemoteHerdrForwardSpawner(),
        workspaces: ClaudeRemoteHerdrForwardWorkspaces(),
        pidLedger: claudeRemoteForwardPidLedger,
        orphanReapInitiallyComplete: false,
        hostIDForAlias: { [weak self] alias in
            guard let matches = self?.claudeRemoteHosts?.hosts(
                matchingSSHDestination: alias
            ), matches.count == 1 else { return nil }
            return matches[0].id
        }
    )
    /// Customized-but-outdated config files awaiting the user's
    /// update-or-keep decision; held here while onboarding is on screen.
    private var pendingConfigDefaultsPromptFileNames: [String]?

    #if LOCALVOXTRAL_DOGFOOD
    /// The dogfood-only local control socket and the service behind it.
    ///
    /// Owned here for the same reason the broker is: the socket answers
    /// questions about the registry and the resolver, both of which live at
    /// this level, and it must be stopped on the app's own terminate path so no
    /// listener outlives the process that bound it.
    private var dogfoodControlSocket: DogfoodControlSocket?
    private var dogfoodControlService: DogfoodControlService?
    #endif

    override init() {
        let settings = SettingsStore()
        let remoteHosts: ClaudeRemoteHostRegistry?
        do {
            remoteHosts = try ClaudeRemoteHostRegistry()
        } catch {
            Log.claudeContext.error(
                "Claude remote host registry unreadable: \(String(describing: error), privacy: .public)"
            )
            remoteHosts = nil
        }
        let activeRemoteChannels = Set(
            (remoteHosts?.hosts() ?? [])
                .filter { !$0.isRevoked }
                .map { ClaudeRemoteSessionScope.channel(hostID: $0.id) }
        )
        claudeSessionRegistry = ClaudeSessionRegistry(
            store: ClaudeSessionFileStore(),
            allowedRemoteChannels: activeRemoteChannels
        )
        claudeRemoteHosts = remoteHosts
        // The one-time-per-launch terminal_apps.toml import (owner decision,
        // 2026-09-07): the file is read HERE and never written — Settings →
        // Terminals owns the list from then on. Runs before anything that
        // consults the user-added list (the session verdict, the agent polish
        // profile), so those read settings only.
        //
        // Transactional by design: the stored list is persisted FIRST and the
        // imported-ids ledger SECOND, so a crash between the two writes
        // re-imports on the next launch instead of silently dropping apps
        // the ledger already claims.
        let terminalAppsImport = UserTerminalAppsMigrator.planImport(
            tomlBundleIDs: appConfigStore.loadTerminalAppBundleIDs(),
            storedApps: settings.userTerminalApps,
            defaults: .standard
        )
        if !terminalAppsImport.isEmpty {
            settings.userTerminalApps += terminalAppsImport.additions
            UserTerminalAppsMigrator.record(terminalAppsImport, defaults: .standard)
        }
        let manager = BackendManager(
            polishingModelProvider: { settings.resolvedManagedLLMPolishingModel },
            speechModelProvider: { settings.resolvedManagedSpeechModel },
            speechdCacheLimitProvider: { settings.speechdCacheLimit.megabytes }
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
        maintainLocalClaudePlugin()
        #if LOCALVOXTRAL_DOGFOOD
        // After the broker, because the control service's `surface probe` uses
        // the resolver the broker installs on the view model.
        startDogfoodControlSocket()
        #endif
        reconcileBundledConfigDefaults()
        viewModel.engines.preflightConfiguredLocalNetworkEndpoints()
        switch LaunchWindowPolicy.decide(
            onboardingCompleted: settingsStore.onboardingCompleted,
            opensWindowAtLaunch: settingsStore.opensWindowAtLaunch
        ) {
        case .onboarding:
            presentOnboarding()
        case .window:
            openWindow(on: .history)
        case .nothing:
            break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if LOCALVOXTRAL_DOGFOOD
        // First: `stop()` does not return until the accept loop has unlinked
        // the socket, so nothing that follows can race a client connecting to
        // an app that is halfway through quitting. The service's bounded
        // auto-stop is released with it.
        dogfoodControlSocket?.stop()
        dogfoodControlSocket = nil
        dogfoodControlService?.shutdown()
        dogfoodControlService = nil
        #endif
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
        claudeRemoteHerdrForwards.stopAllForQuit()
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
        viewModel.context.claudeSessionJoinResolver = nil
        viewModel.context.claudeSessionJoin = nil
        claudeSessionRegistry.flushPersistence()
        // Drop any dictation leases after the app-owned service has stopped all
        // persistent `ssh -L` children. During polish the join has already been
        // consumed, so the explicit service owner is what makes quit complete.
        viewModel.context.closeRemoteHerdrForwards()
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
        let teardowns = (claudeRemoteForwards?.drainingTeardowns ?? [])
            + claudeRemoteHerdrForwards.drainingTeardowns
        guard !teardowns.isEmpty else {
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

    #if LOCALVOXTRAL_DOGFOOD
    /// Binds the dogfood-only control socket, if the owner armed it.
    ///
    /// Two gates, both required, exactly like the capture: this file is only
    /// compiled under `LOCALVOXTRAL_DOGFOOD`, and even then the socket binds
    /// only when `debug.dogfood_control_socket_enabled` is set. A shipped build
    /// contains none of this.
    ///
    /// Failure is non-fatal and LOUD (AGENTS: keep new paths loud). Nothing the
    /// app does for the user depends on this socket; an operator who cannot
    /// reach it needs to know why, and a bind refused because the directory is
    /// not private is precisely the case that must never be papered over.
    private func startDogfoodControlSocket() {
        guard settingsStore.dogfoodControlSocketEnabled else {
            Log.claudeContext.info(
                "Dogfood control socket disarmed (debug.dogfood_control_socket_enabled)"
            )
            return
        }
        let service = DogfoodControlService(
            viewModel: viewModel,
            liveSessions: { [claudeSessionRegistry] in claudeSessionRegistry.liveSessions() },
            hasLiveSessions: { [claudeSessionRegistry] in claudeSessionRegistry.hasLiveSessions() },
            accessibilityTrusted: { [weak viewModel] in
                viewModel?.isAccessibilityTrusted ?? false
            },
            // The context source's version, not the probe verb's: this process
            // HAS windows (the overlay), and a dictation must never ground
            // itself in our own panel — so the same self-exclusion the real
            // dictation path uses applies here.
            frontmostTarget: { TerminalScreenContextSource.frontmostTarget() },
            // Read at call time, not captured: the resolver is installed by
            // `startClaudeContextBroker` and is nil when the broker never
            // bound. And deliberately the app's FULL-capability resolver —
            // unlike `--probe-surface`, which withholds the forward and the
            // panel nonce because a one-shot process is a bad owner for
            // either. This process is the owner: the forward service is
            // supervised and reaped at quit, and the nonce lease is cleared.
            // Withholding them here would make the probe answer a different
            // question from the one a dictation asks, which is the whole
            // reason this verb exists.
            resolveSurface: { [weak viewModel] target in
                guard let resolver = viewModel?.context.claudeSessionJoinResolver else { return nil }
                return await resolver.resolve(target: target)
            }
        )
        dogfoodControlService = service
        let socket = DogfoodControlSocket(
            socketPath: DogfoodControlSocket.defaultSocketPath(),
            handler: { line in
                switch DogfoodControlProtocol.parse(request: line) {
                case .failure(let error):
                    return DogfoodControlProtocol.reply(
                        command: nil,
                        result: nil,
                        error: error.rawValue
                    )
                case .success(let command):
                    let outcome = await service.execute(command)
                    switch outcome {
                    case .success(let result):
                        return DogfoodControlProtocol.reply(
                            command: command,
                            result: result,
                            error: nil
                        )
                    case .failure(let refusal):
                        return DogfoodControlProtocol.reply(
                            command: command,
                            result: nil,
                            error: refusal.rawValue
                        )
                    }
                }
            }
        )
        do {
            try socket.start()
            dogfoodControlSocket = socket
        } catch {
            dogfoodControlService = nil
            Log.claudeContext.error(
                "Dogfood control socket failed to start: \(String(describing: error), privacy: .public)"
            )
        }
    }
    #endif

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
            registry: claudeSessionRegistry
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
            let desktopSessionReader = AXClaudeDesktopSessionURLReader()
            let herdrClient = HerdrSocketClient()
            // The cmux password is read from the Keychain lazily, per query, so
            // a user who never enables the arm is never prompted for keychain
            // access and the secret is not held in memory between dictations.
            let cmuxPasswords = CmuxSocketPasswordStore()
            let sshDestinationCanonicalizer = SSHDestinationCanonicalizer.live()
            let resolver = ClaudeSessionJoinResolver(
                registry: claudeSessionRegistry,
                focusedTerminalTTY: { await ttyReader.focusedTerminalTTY(bundleID: $0) },
                focusedBrowserTabURL: { await browserTabReader.focusedTabURL(bundleID: $0) },
                focusedDesktopSessionURL: {
                    await desktopSessionReader.focusedSessionURL(applicationPID: $0)
                },
                focusedWindowID: { TerminalScreenAXReader.focusedWindowIdentity(applicationPID: $0) },
                herdrClientProbe: {
                    HerdrClientTTYProbe.isHerdrClient(onTTYDevicePath: $0)
                },
                herdrFederation: { HerdrMachineFederationReader.live().federation() },
                herdrClientSurfaceCount: { HerdrClientTTYProbe.clientSurfaceCount() },
                herdrPanes: herdrClient,
                cmuxSurfaces: CmuxSocketClient(
                    password: { cmuxPasswords.password() },
                    bundleIDOfRunningPID: { CmuxSocketClient.runningBundleID(ofPID: $0) }
                ),
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
                canonicalizedEnrolledHosts: { [weak self] destination in
                    guard let hosts = self?.claudeRemoteHosts?.hosts() else { return [] }
                    return await sshDestinationCanonicalizer.matchingHosts(
                        destination: destination,
                        enrolledHosts: hosts
                    )
                },
                proxyJumpShape: { destination in
                    await sshDestinationCanonicalizer.proxyJumpShape(for: destination)
                },
                speculativeHosts: { [weak self] in
                    self?.claudeRemoteHosts?.hosts() ?? []
                },
                remoteHerdrForwards: claudeRemoteHerdrForwards,
                herdrPanelMetadata: herdrClient,
                readFocusedGrid: { target in
                    TerminalScreenContextSource.readVisibleScreen(target: target)?.text
                }
            )
            viewModel.context.claudeSessionJoinResolver = resolver
            // Correction learning compares each submitted prompt with the
            // dictation the app inserted into that session. The registry
            // calls this on the ingesting socket thread.
            claudeSessionRegistry.setSubmittedPromptObserver { [weak viewModel] sessionID, prompt in
                Task { @MainActor in
                    viewModel?.promptSubmitted(sessionID: sessionID, prompt: prompt)
                }
            }
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
            // now: without a running broker there are no sessions to resolve, and
            // an authorizer over an empty registry would answer `.unknown` to
            // everything anyway — but making the dependency explicit is what
            // keeps "no broker ⇒ no raw attachment" true by construction rather
            // than by coincidence.
            TerminalScreenRawAttachmentPolicy.configure(
                authorizer: TerminalScreenClaudeJoinAuthorizer(
                    resolver: resolver,
                    currentJoin: { [weak viewModel] in viewModel?.context.claudeSessionJoin }
                )
            )
        } catch {
            Log.claudeContext.error(
                "Claude context broker failed to start: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Keeps an installed local Claude Code plugin working without a click:
    /// repoints the publisher link at this app, wherever it now lives, and
    /// updates a plugin older than the one bundled. Never installs a plugin
    /// that is not there.
    ///
    /// CI launches of the packaged app on the owner's Mac are skipped: they
    /// run a temporary copy, and pointing the owner's plugin at it would leave
    /// the link dangling once the run deletes it.
    private func maintainLocalClaudePlugin() {
        guard !StartupPermissionSuppression.loginKeychainIsDisabled() else {
            Log.claudeContext.info("Claude plugin maintenance skipped for a CI launch")
            return
        }
        if let publisher = ClaudePluginAssets.publisherURL() {
            do {
                if case .updated(let previous) = try ClaudePublisherPointer.refresh(publisher: publisher) {
                    Log.claudeContext.info(
                        "Claude publisher link now names \(publisher.path, privacy: .public) (was \(previous ?? "absent", privacy: .public))"
                    )
                }
            } catch {
                Log.claudeContext.error(
                    "Claude publisher link refresh failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        if let bundled = ClaudePluginAssets.marketplaceURL() {
            do {
                let outcome = try ClaudeMarketplaceMirror.refresh(source: bundled)
                if outcome != .unchanged {
                    Log.claudeContext.info(
                        "Claude marketplace mirror \(String(describing: outcome), privacy: .public) from \(bundled.path, privacy: .public)"
                    )
                }
            } catch {
                Log.claudeContext.error(
                    "Claude marketplace mirror refresh failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        guard let settings = viewModel.claudeIntegrationSettings else { return }
        Task {
            // Order matters: the registration is re-pointed at the mirror
            // refreshed above BEFORE the version check, so an update lands in
            // a marketplace Claude Code can actually read.
            await settings.repairMarketplaceRegistrationAtLaunch()
            await settings.updateOutdatedPluginAtLaunch()
        }
        Task { await settings.updateOutdatedVibeHooksAtLaunch() }
    }

    /// Binds the remote (SSH) hook listener, but only for a user who has
    /// actually enrolled a host.
    ///
    /// "No enrollment ⇒ no open port" is the point: everyone else's Mac gets
    /// exactly what it had before, with nothing listening on 8473. The host
    /// registry was loaded during app initialization so session restore could
    /// filter remote entries before the broker starts.
    ///
    /// Failure is non-fatal and loud, matching the local broker. The coordinator
    /// — not this method — owns the bind/unbind decision from here on, so
    /// enrolling the first host in Settings binds the port immediately and
    /// revoking the last one closes it. There is no relaunch step.
    private func startClaudeRemoteListener() {
        let registry = claudeRemoteHosts

        let coordinator = registry.map { hosts in
            ClaudeRemoteListenerCoordinator(
                hosts: hosts,
                sessions: claudeSessionRegistry,
                forwardProbes: claudeRemoteForwardProbes,
                onRemoteHerdrActivity: { [weak self] hostID, remoteSocketPath in
                    Task { @MainActor [weak self] in
                        guard let self,
                              let host = self.claudeRemoteHosts?.host(id: hostID),
                              !host.isRevoked,
                              let alias = host.sshHostAlias
                        else { return }
                        await self.claudeRemoteHerdrForwards.prepare(
                            hostID: hostID,
                            alias: alias,
                            remoteSocketPath: remoteSocketPath
                        )
                    }
                }
            )
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
        let forwardOrphanReaper = ClaudeRemoteForwardOrphanReaper(
            ledger: claudeRemoteForwardPidLedger
        )
        let forwards = registry.map { hosts in
            ClaudeRemoteForwardCoordinator(
                hosts: hosts,
                remoteForwardPort: remoteForwardPort,
                isListenerBound: { coordinator?.isListening ?? false },
                // Turns "the remote refused our bind" from one verdict into
                // two: a stranger holds the port, or our own forward is already
                // up because the user has an ssh session to that host. Only the
                // nonce round-trip can tell them apart, and without it every
                // refusal stays the pessimistic reading.
                ownershipProbe: ClaudeRemoteForwardOwnershipCheck.live(
                    witness: claudeRemoteForwardProbes
                ),
                pidLedger: claudeRemoteForwardPidLedger,
                reapOrphans: { [weak self] in
                    await forwardOrphanReaper.reap()
                    await MainActor.run { self?.claudeRemoteHerdrForwards.markOrphanReapComplete() }
                },
                reconcileHerdrEnrollment: { [weak self] activeHostIDs in
                    self?.claudeRemoteHerdrForwards.reconcileEnrollment(
                        activeHostIDs: activeHostIDs
                    )
                }
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
            forwards: forwards,
            // Read once per pane refresh, not cached at launch: a `chsh` while
            // the app runs would otherwise write the wrong shell's syntax.
            loginShell: {
                ClaudeShellKind.detect(
                    loginShellPath: ClaudeLoginShellReader.loginShellPath()
                )
            },
            shellRCWriter: { shell in
                ClaudeShellRCWriter(
                    fileSystem: LiveClaudeShellRCFileSystem(
                        relativePath: ClaudeShellRCSetup.relativeRCPath(for: shell) { relative in
                            FileManager.default.fileExists(
                                atPath: FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent(relative).path
                            )
                        }
                    )
                )
            },
            // The app-visible half of the setup step: has a session actually
            // arrived carrying the value. Reads the registry, never a file.
            liveLocalTTYReport: { [weak claudeSessionRegistry] in
                guard let sessions = claudeSessionRegistry?.liveSessions(),
                      !sessions.isEmpty
                else { return .noSessions }
                let remote = sessions.filter { $0.remoteSessionEnvironment != nil }
                guard !remote.isEmpty else { return .noSessions }
                return remote.contains { $0.remoteSessionEnvironment?.localTTY != nil }
                    ? .seen : .notSeen
            },
            // Off the main actor: `claude plugin list` shells out.
            fetchPluginListOutput: {
                await Task.detached(priority: .userInitiated) {
                    try? ClaudePluginInstallService.live().pluginListOutput()
                }.value
            },
            // Off the main actor for the same reason as the listing above.
            fetchMarketplaceListOutput: {
                await Task.detached(priority: .userInitiated) {
                    try? ClaudePluginInstallService.live().marketplaceListOutput()
                }.value
            },
            // Read at repair time, not now: this model is built before the
            // launch maintenance that creates the mirror.
            desiredMarketplacePath: { ClaudeMarketplaceMirror.usableURL()?.path },
            bundledPluginVersion: ClaudePluginAssets.localPluginVersion(),
            statuslineService: {
                ClaudeStatuslineInstallService(
                    fileSystem: LiveClaudeStatuslineFileSystem(),
                    scriptFileSystem: LiveClaudeStatuslineFileSystem(
                        relativePath: ClaudeStatuslineCombine.scriptRelativePath
                    )
                )
            },
            // The same publisher the plugin shim execs, in `--statusline`
            // mode. Nil when the binary is not where this build put it — the
            // row then reports it cannot install rather than writing a path
            // that prints nothing.
            statuslineHookCommand: {
                guard let publisher = ClaudePluginAssets.publisherURL() else { return nil }
                // Quoted when it must be: an app under `~/My Apps` would
                // otherwise split into two words.
                return "\(ClaudeStatuslineCombine.shellWord(publisher.path)) --statusline"
            },
            opencodeService: {
                OpencodePluginInstallService(
                    bundledPluginData: {
                        guard let url = ClaudePluginAssets.opencodePluginURL() else { return nil }
                        return try? Data(contentsOf: url)
                    },
                    fileSystem: LiveOpencodePluginFileSystem()
                )
            },
            vibeService: {
                VibeHooksInstallService(
                    bundledShimData: {
                        ClaudePluginAssets.vibeFileURL(named: ClaudePluginAssets.vibeShimFileName)
                            .flatMap { try? Data(contentsOf: $0) }
                    },
                    bundledHooksBlock: {
                        ClaudePluginAssets.vibeFileURL(named: ClaudePluginAssets.vibeHooksBlockFileName)
                            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                    },
                    fileSystem: LiveVibeHooksFileSystem()
                )
            },
            vibeRemoteFiles: { VibeRemoteHooksFiles.bundled() },
            // A binary on this Mac: a synchronous PATH scan, decided at model
            // construction so the row paints on first paint.
            herdrBinaryAvailable: {
                ClaudeHerdrAvailability.isHerdrBinaryAvailable()
            },
            // Any live session — local or remote — reporting a herdr pane.
            // Reads the registry, never the screen. Refreshes with the pane.
            herdrPresenceReport: { [weak claudeSessionRegistry] in
                guard let sessions = claudeSessionRegistry?.liveSessions() else { return false }
                return sessions.contains { snapshot in
                    snapshot.process?.herdrPaneID != nil
                        || snapshot.remoteSessionEnvironment?.herdrPaneID != nil
                }
            },
            // The enrolled hosts whose live REMOTE sessions report a herdr
            // pane, for the herdr pane's host list. A local herdr pane
            // belongs to no enrolled host and is never listed.
            herdrPaneReportingHostIDs: { [weak claudeSessionRegistry] in
                guard let sessions = claudeSessionRegistry?.liveSessions() else { return [] }
                return sessions.compactMap { snapshot in
                    guard snapshot.remoteSessionEnvironment?.herdrPaneID != nil else {
                        return nil
                    }
                    return ClaudeRemoteSessionScope.hostID(
                        fromScopedSessionID: snapshot.sessionID
                    )
                }
            },
            // The live herdr catalog: wired here, not defaulted in the model,
            // so the filesystem-reading reader stays out of the model's
            // public signature.
            herdrMachineCatalogReading: {
                HerdrMachineFederationReader.live().catalog()
            },
            // The federated panel row is offered only when the live catalog
            // has an enabled machine. Read at refresh, never cached at launch:
            // machines can be added, removed, enabled, or disabled while the
            // app runs.
            hasEnabledHerdrMachineReport: {
                switch HerdrMachineFederationReader.live().catalog() {
                case .catalog(let catalog):
                    return !catalog.enabledProfiles.isEmpty
                case .absent, .unreadable:
                    return false
                }
            }
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
        // No ellipsis: it reveals the files in Finder, with no dialog to
        // fill in. The macOS rule, which the app's buttons follow: "…" only
        // when pressing asks for more input or a confirmation first.
        alert.addButton(withTitle: "Show Files")

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

    /// Moves the process between menu-bar-only and Dock-and-app-switcher, and
    /// reports whether it took.
    ///
    /// Going `.regular` gives the process a Dock tile, an app switcher entry
    /// and a main menu, but does not by itself bring it forward — without the
    /// activation the window it was opened for can end up behind whatever was
    /// frontmost. `activate` is a no-op when the app is already active, which
    /// it usually is, since the window that triggered this was just opened.
    private static func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        guard NSApp.setActivationPolicy(policy) else {
            Log.diagnostics.error(
                "Activation policy change to \(String(describing: policy), privacy: .public) was refused."
            )
            return false
        }
        // One line per transition, not per window: the transitions are the
        // whole behavior, and this is the only place an outside observer can
        // read which one the app believes it is in.
        Log.diagnostics.notice(
            "Activation policy is now \(policy == .regular ? "regular (Dock icon shown)" : "accessory (menu bar only)", privacy: .public)."
        )
        if policy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
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
            dockIconPolicy: dockIconPolicy,
            openEndpointsSettings: { [weak self] in self?.openWindow(on: .endpoints) }
        )
        controller.onFinished = { [weak self] in
            self?.onboardingController = nil
            // First launch skips the eager warmup (the wizard owns bootstrap);
            // once the wizard is done — finished or skipped — start whatever
            // required managed backends it didn't already start.
            self?.viewModel.engines.warmUpManagedBackendsAtLaunchIfNeeded()
            self?.presentPendingConfigDefaultsPromptIfNeeded()
        }
        onboardingController = controller
        controller.present()
    }

    /// Brings up the app's one window on `tab`. The Settings scene hosts it,
    /// History and Insights included, so this is also how the window opens on
    /// a pane that is not a settings pane.
    private func openWindow(on tab: SettingsTab) {
        settingsNavigator.selectedTab = tab
        Task { @MainActor in
            let opener = AppWindowOpener(
                show: { [weak self] in self?.askForTheWindow() },
                isOnScreen: { AppDelegate.windowIsOnScreen() },
                sleepFor: { try? await Task.sleep(for: $0) }
            )
            guard let attempt = await opener.open() else {
                Log.diagnostics.error(
                    """
                    The localvoxtral window never opened; showSettingsWindow: was answered \
                    but no window appeared. Windows now: \
                    \(AppDelegate.windowSummary(), privacy: .public)
                    """
                )
                return
            }
            if attempt > 1 {
                Log.diagnostics.notice(
                    "The localvoxtral window opened on attempt \(attempt, privacy: .public)."
                )
            }
        }
    }

    /// Asks for the window, by the two routes the app has, the one that works
    /// at launch first.
    ///
    /// `NSApp.sendAction(showSettingsWindow:)` — the route the onboarding
    /// Engines link has always used — is ACCEPTED at launch and opens nothing
    /// (#449, measured on the packaged build over eight asks in 1.75 s, and
    /// not for want of the main menu: it fails with the Dock icon up too).
    /// SwiftUI's own `openSettings` is what the menu bar item's Settings…
    /// uses, and that one works; the label hands it over at launch.
    ///
    /// The send stays behind it, addressed through the main menu's own item
    /// when the app has one, since `to: nil` walks a responder chain that
    /// answers without acting.
    private func askForTheWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let settingsOpener {
            settingsOpener()
            return
        }
        let selector = Selector(("showSettingsWindow:"))
        if let item = AppDelegate.mainMenuItem(for: selector) {
            NSApp.sendAction(selector, to: item.target, from: item)
            return
        }
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    /// A main-menu item by its action. There is a main menu only while the
    /// process is `.regular` — AppKit synthesizes none for an accessory app.
    private static func mainMenuItem(for action: Selector) -> NSMenuItem? {
        for top in NSApp.mainMenu?.items ?? [] {
            for item in top.submenu?.items ?? [] where item.action == action {
                return item
            }
        }
        return nil
    }

    /// Every window the process has, for the one log line that has to explain
    /// why the window the user asked for is not on screen.
    private static func windowSummary() -> String {
        let windows = NSApp.windows.map { window in
            "\(window.title.isEmpty ? "<untitled>" : window.title)"
                + "[\(type(of: window)) visible=\(window.isVisible)]"
        }
        return windows.isEmpty ? "none" : windows.joined(separator: ", ")
    }

    /// The scene's window, by the title `SettingsWindowChromeView` keeps on it.
    /// Hidden-title chrome does not clear `window.title`, precisely so the AX
    /// drills — and this — can find it.
    private static func windowIsOnScreen() -> Bool {
        NSApp.windows.contains {
            $0.title == SettingsWindowChromeView.windowTitle && $0.isVisible
        }
    }

}

@MainActor
private enum MenuBarIconAsset {
    static let idleIcon: NSImage? = loadIcon(candidates: [
        "MicIconTemplate@2x",
        "MicIconTemplate",
    ], asTemplate: true)

    static let connectedIcon: NSImage? = adaptiveIcon(coloredCandidates: [
        "MicIconTemplate_connected",
        "MicIconTemplate@2x_connected",
    ])

    static let failureIcon: NSImage? = adaptiveIcon(coloredCandidates: [
        "MicIconTemplate_failure",
        "MicIconTemplate@2x_failure",
    ])

    private static func adaptiveIcon(coloredCandidates: [String]) -> NSImage? {
        guard let template = idleIcon,
              let colored = loadIcon(candidates: coloredCandidates, asTemplate: false)
        else {
            return nil
        }
        return MenuBarStatusIcon.appearanceAdaptive(template: template, colored: colored)
    }

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
