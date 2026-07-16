import AppKit
import ClaudeContextWire
import SwiftUI

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
    /// Customized-but-outdated config files awaiting the user's
    /// update-or-keep decision; held here while onboarding is on screen.
    private var pendingConfigDefaultsPromptFileNames: [String]?

    override init() {
        let settings = SettingsStore()
        let manager = BackendManager(
            polishingModelProvider: { settings.resolvedManagedLLMPolishingModel }
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
        // The bundled polishd helper replaced the uv-installed mlx-lm tool
        // (2026-07); sweep the orphaned install off existing user Macs.
        Task.detached(priority: .utility) {
            LegacyMLXLMCleanup().run()
        }
        startClaudeContextBroker()
        reconcileBundledConfigDefaults()
        guard !settingsStore.onboardingCompleted else { return }
        presentOnboarding()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Unlinks the socket, so a publisher from a surviving Claude Code
        // session fails open (silent exit 0) instead of blocking on a path
        // nothing is accepting on.
        claudeContextBroker?.stop()
        claudeContextBroker = nil
        TerminalScreenRawAttachmentPolicy.configure(authorizer: nil)
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
        let broker = ClaudeContextBroker(socketPath: socketPath, registry: claudeSessionRegistry)
        do {
            try broker.start()
            claudeContextBroker = broker
            // The join gate for raw terminal screen attachment. Installed only
            // now: without a running broker there are no markers to resolve, and
            // an authorizer over an empty registry would answer `.unknown` to
            // everything anyway — but making the dependency explicit is what
            // keeps "no broker ⇒ no raw attachment" true by construction rather
            // than by coincidence.
            TerminalScreenRawAttachmentPolicy.configure(
                authorizer: TerminalScreenClaudeJoinAuthorizer(registry: claudeSessionRegistry)
            )
        } catch {
            Log.claudeContext.error(
                "Claude context broker failed to start: \(String(describing: error), privacy: .public)"
            )
        }
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
