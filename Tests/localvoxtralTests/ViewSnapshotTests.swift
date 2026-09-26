import AppKit
import SwiftUI
import XCTest

@testable import localvoxtral

/// Pictures of the app's views, one PNG per view and state, for an agent that
/// has to show the owner a view: `scripts/view-snapshots.sh` renders them on a
/// hosted runner (docs/agent/view-snapshots.md). Record-only: nothing is
/// compared against a stored image. `build-test` runs them too, so a view
/// that stops rendering fails there.
///
/// Every model is built here from fakes over throwaway defaults, so no image
/// holds anything from the machine that ran it: no transcripts, no paths, no
/// device names. The artifacts are public.
@MainActor
final class ViewSnapshotTests: XCTestCase {
    /// `SettingsScene`'s default size.
    private static let settingsSize = CGSize(width: 780, height: 560)

    // MARK: - Settings

    func testSettingsPanes() async throws {
        let panes: [SettingsTab] =
            SettingsTab.historySidebarItems
            + SettingsTab.primarySidebarItems
            + [SettingsTab.terminal(TerminalAppCatalog.builtIn[0])]
        for pane in panes {
            try await recordSettings(pane: pane, name: "settings-\(pane.rawValue)", setUp: false)
        }
    }

    /// Each harness pane twice: before anything is set up, and with the
    /// plugin, hooks, status line, dictation note and herdr panel installed
    /// and one host enrolled. The model reads all of it through the doubles
    /// below.
    func testIntegrationPanes() async throws {
        for pane in SettingsTab.integrationsSidebarItems {
            for setUp in [false, true] {
                try await recordSettings(
                    pane: pane,
                    name: "settings-\(pane.rawValue)-\(setUp ? "set-up" : "not-set-up")",
                    setUp: setUp)
            }
        }
    }

    private func recordSettings(
        pane: SettingsTab, name: String, setUp: Bool,
        configure: ((DictationViewModel) throws -> Void)? = nil
    ) async throws {
        let (settings, viewModel) = makeViewModel()
        try configure?(viewModel)
        let claude = try makeClaudeIntegrationModel(setUp: setUp)
        // What the pane's onAppear starts, finished before the render so the
        // first frame is not "Checking…".
        await claude.refreshIntegrationsStatuses()
        viewModel.claudeIntegrationSettings = claude
        let navigator = SettingsNavigator()
        navigator.selectedTab = pane
        let view = SettingsView(
            settings: settings,
            viewModel: viewModel,
            backendManager: BackendManager(),
            navigator: navigator,
            loginItem: LoginItemController(registrar: FakeLoginItemRegistrar(state: .disabled))
        )
        .environment(\.shortcutRecorderStandIn, true)
        try record(
            view, name: name,
            width: Self.settingsSize.width, height: Self.settingsSize.height, growToFit: true)
    }

    /// The Inbox with a drafted capture, one no project took, and one filed
    /// (#725). Made-up words: the artifacts are public.
    func testInboxWithCaptures() async throws {
        try await recordSettings(pane: .inbox, name: "settings-inbox-captures", setUp: false) { viewModel in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("inbox-snapshot-\(UUID().uuidString)")
            let fileURL = directory.appendingPathComponent("quick-captures.json")
            let now = Date()
            var drafted = QuickCaptureItem(
                capturedAt: now.addingTimeInterval(-300),
                text: "the overlay should remember its size per display, not just its position")
            drafted.state = .ready
            drafted.projectKey = "/work/demo"
            drafted.projectName = "demo"
            drafted.repository = "example/demo"
            drafted.title = "Remember the overlay's size per display"
            drafted.body = "## Scope\nStore the overlay's size with its position, per display.\n\n## Proof\nA test that restores both."
            var unplaced = QuickCaptureItem(capturedAt: now.addingTimeInterval(-3_600), text: "renew the passport before December")
            unplaced.state = .ready
            unplaced.note = "Not routed to a project. Move it to one."
            var filed = QuickCaptureItem(capturedAt: now.addingTimeInterval(-7_200), text: "add a dark mode to the settings window")
            filed.state = .filed
            filed.title = "Dark mode for the settings window"
            filed.repository = "example/demo"
            filed.filedURL = "https://github.com/example/demo/issues/12"
            try QuickCaptureInboxFile.save(QuickCaptureInbox(items: [drafted, unplaced, filed]), to: fileURL)
            self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let learned = LearnedTerms(projects: [
                LearnedTermProject(key: "/work/demo", name: "demo", terms: [], lastSeen: now),
            ])
            viewModel.installQuickCaptureInbox(QuickCaptureInboxViewModel(
                settings: viewModel.settings,
                learnedTerms: { learned },
                fileURL: fileURL,
                applicationSupport: directory
            ))
        }
    }

    /// Advanced → Terms learned from polishing → Show: empty, which is where
    /// a new machine imports (#523), and with terms, where Export… shows,
    /// agent proposals (#609) included.
    func testLearnedTermsSheet() throws {
        let frozen = Date(timeIntervalSince1970: 1_790_000_000)
        for filled in [false, true] {
            let (_, viewModel) = makeViewModel()
            let store = LearnedTermStore(fileURL: nil, now: { frozen })
            if filled {
                store.importProjects([
                    LearnedTermProject(key: "/work/demo", name: "demo", terms: [
                        LearnedTerm(
                            term: "speechd", sources: ["repo"], dictations: 4,
                            firstSeen: frozen, lastSeen: frozen),
                        LearnedTerm(
                            term: "Voxtral", sources: ["repo"], dictations: 2,
                            firstSeen: frozen, lastSeen: frozen),
                        // What a new project's agents proposed (#609).
                        LearnedTerm(
                            term: "inkwell", sources: [ProjectTermProposal.Agent.claude.source],
                            dictations: 0, firstSeen: frozen, lastSeen: frozen),
                        LearnedTerm(
                            term: "GlyphAtlasCache", sources: [ProjectTermProposal.Agent.vibe.source],
                            dictations: 1, firstSeen: frozen, lastSeen: frozen),
                    ], lastSeen: frozen),
                ]) { _ in }
                store.waitForPendingWrites()
            }
            viewModel.learnedTermStore = store
            try record(
                LearnedTermsSheet(viewModel: viewModel, onDone: {}),
                name: "learned-terms-\(filled ? "filled" : "empty")",
                width: 520, height: 440, growToFit: false)
        }
    }

    // MARK: - Status popover

    /// The menu bar item's content. The app shows it as an `NSMenu`
    /// (`.menuBarExtraStyle(.menu)`); hosted in a window it draws as the
    /// controls it is made of, which still shows each row and whether it is
    /// enabled.
    func testStatusPopoverStates() throws {
        let states: [(name: String, apply: (DictationViewModel) -> Void)] = [
            ("idle", { _ in }),
            ("connecting", {
                $0.isConnectingRealtimeSession = true
                $0.statusText = DictationViewModel.StatusStrings.connectingRealtimeBackend
            }),
            ("dictating", {
                $0.isDictating = true
                $0.statusText = "Listening"
            }),
            ("finalizing", {
                $0.isFinalizingStop = true
                $0.statusText = DictationViewModel.StatusStrings.polishing
            }),
            ("connection-refused", {
                $0.statusText = "Connection refused."
                $0.lastError = "Connection refused."
            }),
        ]
        for state in states {
            let (_, viewModel) = makeViewModel()
            state.apply(viewModel)
            let view = StatusPopoverView(viewModel: viewModel, navigator: SettingsNavigator())
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
            try record(view, name: "popover-\(state.name)", width: 304, height: 420, growToFit: false)
        }
    }

    // MARK: - Overlay panel

    func testOverlayPanelStates() throws {
        let metrics = OverlayLayoutMetrics(bodyFontSize: OverlayLayoutMetrics.defaultBodyFontSize)
        let sample = "Rename the retry helper and run the unit tests again."
        let states: [(name: String, view: DictationOverlayView)] = [
            ("ready", DictationOverlayView(
                phase: .idle, text: "", errorMessage: nil, secureInputActive: false,
                metrics: metrics)),
            ("listening", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics)),
            ("listening-joined", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics, claudeJoin: .joined(label: "localvoxtral"))),
            ("listening-unjoined", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics, claudeJoin: .unjoined)),
            ("secure-input", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: true,
                metrics: metrics)),
            ("finalizing", DictationOverlayView(
                phase: .finalizing, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics)),
            ("polished", DictationOverlayView(
                phase: .finalizing, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics, polished: true)),
            ("commit-failed", DictationOverlayView(
                phase: .commitFailed, text: sample,
                errorMessage: "Couldn't insert. Copied for manual paste.",
                secureInputActive: false, metrics: metrics)),
        ]
        for state in states {
            let height = metrics.contentHeight(text: state.view.text, errorMessage: state.view.errorMessage)
            // A flat backdrop stands in for the desktop the panel floats over.
            let inset: CGFloat = 16
            let view = state.view
                .frame(width: metrics.panelWidth, height: height)
                .padding(inset)
                .background(Color(white: 0.55))
            try record(
                view, name: "overlay-\(state.name)",
                width: metrics.panelWidth + 2 * inset, height: height + 2 * inset, growToFit: false)
        }
    }

    // MARK: - Support

    private func makeViewModel() -> (SettingsStore, DictationViewModel) {
        let settings = makeSettings()
        let microphone = FakeMicrophoneCaptureService()
        microphone.configureDevices(
            [MicrophoneInputDevice(id: "snapshot-mic", name: "Built-in Microphone", channelCount: 1)],
            defaultInputDeviceID: "snapshot-mic")
        let viewModel = DictationViewModel(
            settings: settings,
            backendManager: OnboardingTestBackendManager(),
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false,
            dependencies: .init(microphone: { microphone }, clock: ManualSessionClock().clock)
        )
        viewModel.appConfigStore = MockAppConfigStore()
        retainForTestProcessLifetime(viewModel)
        return (settings, viewModel)
    }

    /// The Claude Code integrations' model over in-memory doubles: no home
    /// directory, keychain, process or port. `setUp` picks every probe's
    /// answer at once.
    private func makeClaudeIntegrationModel(setUp: Bool) throws -> ClaudeIntegrationSettingsModel {
        let frozen = Date(timeIntervalSince1970: 1_790_000_000)
        let registry = try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/nonexistent/lvx-snapshot/hosts.json"),
            io: MemoryClaudeRemoteHostStore(),
            now: { frozen }
        )
        if setUp {
            _ = try registry.enroll(label: "build-host", sshHostAlias: "build-host")
        }

        let pluginVersion = "1.3.0"
        let pluginList =
            setUp
            ? "[{\"id\":\"localvoxtral@localvoxtral\",\"version\":\"\(pluginVersion)\",\"scope\":\"user\",\"enabled\":true}]"
            : "[]"

        let statuslineHook = "/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline"
        let statuslineState =
            setUp
            ? ClaudeStatuslineState(
                fileExists: true,
                data: ClaudeStatuslineInstallService.updatedSettingsData(
                    existing: nil, hookCommand: statuslineHook))
            : ClaudeStatuslineState(fileExists: false)
        let statusline = ClaudeStatuslineInstallService(
            fileSystem: StubStatuslineFileSystem(state: statuslineState),
            isExecutableFile: { _ in true })

        let opencodePlugin = Data("// localvoxtral opencode plugin\n".utf8)
        let opencodeState =
            setUp
            ? OpencodePluginState(
                pluginFileExists: true, pluginData: opencodePlugin, tuiFileExists: true,
                tuiData: try JSONSerialization.data(
                    withJSONObject: ["plugin": [OpencodePluginInstallService.tuiPluginEntry]]))
            : OpencodePluginState()
        let opencode = OpencodePluginInstallService(
            bundledPluginData: { opencodePlugin },
            fileSystem: StubOpencodeFileSystem(state: opencodeState))

        let vibeShim = Data("#!/bin/sh\n".utf8)
        let vibeBlock = """
            # >>> localvoxtral >>>
            [[hooks]]
            name = "localvoxtral-turn"
            type = "post_agent"
            command = "sh \\"$HOME/.vibe/localvoxtral/publish.sh\\""
            # <<< localvoxtral <<<

            """
        let vibeState =
            setUp
            ? VibeHooksState(
                shimFileExists: true, shimData: vibeShim, shimPermissions: 0o700,
                hooksFileExists: true, hooksData: Data(vibeBlock.utf8), hooksPermissions: 0o644)
            : VibeHooksState()
        let vibe = VibeHooksInstallService(
            bundledShimData: { vibeShim }, bundledHooksBlock: { vibeBlock },
            fileSystem: StubVibeHooksFileSystem(state: vibeState))

        // Set up: the note is in CLAUDE.md, which opencode also reads, and
        // in Vibe's AGENTS.md.
        let dictationNotes = MemoryDictationNoteFileSystem(
            files: setUp
                ? [
                    ".claude/CLAUDE.md": DictationNoteInstallService.snippet + "\n",
                    ".vibe/AGENTS.md": DictationNoteInstallService.snippet + "\n",
                ]
                : [:])

        let herdrConfig = StubLocalHerdrConfigFileSystem(
            state: ClaudeLocalHerdrConfigState(
                directoryExists: setUp,
                configData: setUp ? Data(ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet.utf8) : nil,
                configPermissions: setUp ? 0o644 : nil))

        // The app's coordinator reconciles on enrollment; without it the
        // pane reads "not listening" next to an enrolled host.
        let listener = StubClaudeRemoteListener(hosts: registry)
        try listener.reconcile()
        let herdrMachines: HerdrMachineCatalogReading =
            setUp
            ? .catalog(HerdrMachineCatalog(
                profiles: [HerdrMachineProfile(
                    id: "build-host", label: "build-host", target: "build-host",
                    session: "default", enabled: true)],
                selectedProfileID: nil))
            : .absent

        return ClaudeIntegrationSettingsModel(
            registry: registry,
            listener: listener,
            pluginService: { StubClaudePluginService() },
            enrollmentService: ClaudeRemoteEnrollmentService(
                localHerdrConfigFileSystem: herdrConfig),
            now: { frozen },
            fetchPluginListOutput: { pluginList },
            bundledPluginVersion: pluginVersion,
            statuslineService: { statusline },
            statuslineHookCommand: { statuslineHook },
            opencodeService: { opencode },
            vibeService: { vibe },
            dictationNoteService: { DictationNoteInstallService(agent: $0, fileSystem: dictationNotes) },
            herdrBinaryAvailable: { setUp },
            herdrPresenceReport: { setUp },
            herdrMachineCatalogReading: { herdrMachines },
            hasEnabledHerdrMachineReport: { setUp }
        )
    }

    private func record<V: View>(
        _ view: V, name: String, width: CGFloat, height: CGFloat, growToFit: Bool
    ) throws {
        let url = try ViewSnapshot.record(
            view, name: name, width: width, height: height, growToFit: growToFit)
        // The hosting view sizes its window to the content, so the image is
        // the view's own size, not necessarily the one asked for.
        let image = try XCTUnwrap(NSImage(contentsOf: url), "\(name).png does not read back")
        XCTAssertGreaterThan(image.size.width, 0, name)
        XCTAssertGreaterThan(image.size.height, 0, name)
    }
}
