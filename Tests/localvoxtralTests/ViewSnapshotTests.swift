import AppKit
import ClaudeContextWire
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

    /// Insights with the usage ledger holding a call of every feature, on
    /// every kind of backend: the Usage by feature group at the end (#837).
    func testInsightsUsageByFeature() async throws {
        var insights: DictationInsightsModel?
        try await recordSettings(pane: .insights, name: "settings-insights-usage", setUp: false) { viewModel in
            let ledger = UsageLedger(fileURL: nil)
            let now = Date()
            func add(_ count: Int, _ entry: UsageEntry) {
                for _ in 0..<count { ledger.record(entry) }
            }
            add(40, UsageEntry(date: now, feature: .dictation, backend: .mistral,
                               model: "voxtral-mini-realtime-latest", audioSeconds: 37, costEUR: 0.0033))
            add(30, UsageEntry(date: now, feature: .polish, backend: .mistral, model: "zai-glm-5-3", costEUR: 0.001))
            add(12, UsageEntry(date: now, feature: .polish, backend: .bundledHelper, model: "local"))
            add(31, UsageEntry(date: now, feature: .secondPass, backend: .mistral,
                               model: "voxtral-mini-latest", audioSeconds: 37, costEUR: 0.0016))
            add(1, UsageEntry(date: now, feature: .termSuggestions, backend: .mistral, model: "zai-glm-5-3",
                              costEUR: 0.08))
            add(2, UsageEntry(date: now, feature: .projectTerms, backend: .claudeCode, model: "sonnet",
                              agentCostUSD: 0.1))
            add(5, UsageEntry(date: now, feature: .quickCaptureRouting, backend: .jev, model: "jev-latest"))
            add(5, UsageEntry(date: now, feature: .quickCaptureDrafting, backend: .claudeCode, model: "sonnet",
                              agentCostUSD: 0.099))
            add(1, UsageEntry(date: now, feature: .quickCaptureDrafting, backend: .vibe, model: "default"))
            viewModel.installUsageLedger(ledger)
            let model = DictationInsightsModel(viewModel: viewModel)
            model.reloadUsage(now: now)
            insights = model
        } insightsModel: { insights }
    }

    private func recordSettings(
        pane: SettingsTab, name: String, setUp: Bool,
        appearance: NSAppearance.Name = .aqua,
        configure: ((DictationViewModel) throws -> Void)? = nil,
        insightsModel: (() -> DictationInsightsModel?)? = nil
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
            loginItem: LoginItemController(registrar: FakeLoginItemRegistrar(state: .disabled)),
            insightsModel: insightsModel?()
        )
        .environment(\.shortcutRecorderStandIn, true)
        try record(
            view, name: name,
            width: Self.settingsSize.width, height: Self.settingsSize.height, growToFit: true,
            appearance: appearance)
    }

    /// The Inbox with a drafted capture that has a follow-up and extends an
    /// issue (#965), one no project took, and one filed (#725). Made-up
    /// words: the artifacts are public.
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
            drafted.followUps = [.init(
                id: UUID(), capturedAt: now.addingTimeInterval(-120),
                text: "also when a display is unplugged and plugged back", historyRecordID: nil, draftBefore: nil
            )]
            drafted.relation = .extends
            drafted.relatedIssue = 8
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

    /// Projects (#939), light and dark: the table, with a fork waiting for
    /// a choice, a project with no GitHub repository and the "No project"
    /// entry (#972), and Import… and Export… under it (#999); then one
    /// project's sheet with its whole term list and the "No project" sheet.
    /// Made-up projects and hosts: the artifacts are public.
    func testProjectsPane() async throws {
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await recordSettings(
                pane: .projects, name: "settings-projects-\(theme)", setUp: false, appearance: appearance
            ) { viewModel in
                viewModel.installQuickCaptureInbox(try self.projectsInbox(viewModel.settings))
                // Export… shows only when the store holds terms (#999).
                let store = LearnedTermStore(fileURL: nil)
                store.importProjects(self.projectsLearnedTerms().projects) { _ in }
                store.waitForPendingWrites()
                viewModel.learnedTermStore = store
            }
            let (settings, viewModel) = makeViewModel()
            let inbox = try projectsInbox(settings)
            try record(
                ProjectDetailSheet(
                    projectKey: "/work/demo", settings: settings, viewModel: viewModel, inbox: inbox,
                    dictationProjectKeys: Array(repeating: "/work/demo", count: 142) + ["remote:demo", nil],
                    openInbox: {}, onDone: {})
                // A sheet draws on its window's background; the snapshot
                // window has none.
                .background(Color(nsColor: .windowBackgroundColor)),
                name: "projects-sheet-\(theme)",
                width: 560, height: 760, growToFit: false, appearance: appearance)
            try record(
                UnlistedTermsSheet(viewModel: viewModel, inbox: inbox, onDone: {})
                    .background(Color(nsColor: .windowBackgroundColor)),
                name: "projects-no-project-sheet-\(theme)",
                width: 560, height: 480, growToFit: false, appearance: appearance)
        }
    }

    /// The polish prompt's sizes (#1007): Global terms with a count and
    /// tokens, and the instructions under Advanced for both profiles, at the
    /// ratio twenty measured Mistral requests give.
    func testTextProcessingPromptSizes() async throws {
        try await recordSettings(pane: .textProcessing, name: "settings-textProcessing-prompt-sizes", setUp: false) {
            viewModel in
            let settings = viewModel.settings
            settings.polishSpeakerTerms = [
                "Qwen", "Claude Code", "vLLM", "Ghostty", "SwiftPM", "herdr", "Voxtral", "MLX",
                "Tailscale", "PostgreSQL", "Kubernetes", "OpenTelemetry",
            ]
            settings.agentPolishProfileEnabled = true
            settings.polishingBackendMode = .mistralAPI
            let ledger = UsageLedger(fileURL: nil)
            for _ in 0..<20 {
                ledger.record(UsageEntry(
                    date: Date(), feature: .polish, backend: .mistral, model: "zai-glm-5-3",
                    promptTokens: 1_949, promptCharacters: 9_100))
            }
            viewModel.installUsageLedger(ledger)
        }
    }

    /// A History row opened: its details line ends with the prompt tokens
    /// the polish request sent (#1007). Made-up words.
    func testHistoryEntryDetails() async throws {
        let (settings, viewModel) = makeViewModel()
        let store = try XCTUnwrap(DictationSessionStore(inMemory: true))
        let dictation = DictationSessionRecord(
            startedAt: Date().addingTimeInterval(-120), finishedAt: Date().addingTimeInterval(-110),
            rawText: "the mac queue is stuck again, check the runner",
            polishedText: "The Mac queue is stuck again; check the runner.",
            polishingDurationSeconds: 0.84, provider: "mistral", model: "zai-glm-5-3",
            outputMode: "overlay_buffer", targetAppBundleID: "com.mitchellh.ghostty", status: .completed,
            commitSucceeded: true, polishProfile: PolishPromptProfile.agent.rawValue)
        dictation.polishPromptTokens = 1_949
        await store.save(dictation).value
        viewModel.sessionStore = store
        let model = DictationHistoryModel(store: { store })
        await model.reload()
        model.expandedEntryID = dictation.id
        try record(
            HistorySettingsPane(settings: settings, viewModel: viewModel, model: model),
            name: "settings-history-entry-details",
            width: Self.settingsSize.width, height: Self.settingsSize.height, growToFit: true)
    }

    private func projectsLearnedTerms() -> LearnedTerms {
        let now = Date()
        func term(_ spelling: String, _ dictations: Int, sources: [String] = ["repo"], pinned: Bool? = nil) -> LearnedTerm {
            LearnedTerm(
                term: spelling, sources: sources, dictations: dictations, firstSeen: now, lastSeen: now,
                applied: dictations > 4 ? dictations - 2 : nil, lastApplied: dictations > 4 ? now.addingTimeInterval(-3_600) : nil,
                pinned: pinned)
        }
        func project(
            _ key: String, _ name: String, ago hours: Double, terms: [LearnedTerm] = [],
            repository: String? = nil, github: GitHubRepositoryFacts? = nil, hosts: [String]? = nil
        ) -> LearnedTermProject {
            var project = LearnedTermProject(key: key, name: name, terms: terms, lastSeen: now.addingTimeInterval(-hours * 3_600))
            project.reportedAsRepository = key.hasPrefix("remote:") ? true : nil
            project.repository = repository
            project.github = github
            project.hostIDs = hosts
            return project
        }
        let demoFacts = GitHubRepositoryFacts(
            description: "Turns talks into timestamped, citable notes for agents: an MCP server, a web app and a worker",
            topics: ["mcp"], parent: nil)
        return LearnedTerms(projects: [
            project(
                "/work/demo", "demo", ago: 0.2,
                terms: [term("demo", 9), term("job-status", 7), term("worker", 6), term("Vespa", 5, pinned: true),
                        term("shelf", 4), term("youtu.be", 4), term("receipt", 3), term("ghcr.io", 3),
                        term("citable", 3), term("MCP", 3), term("timestamped", 2), term("transcript-id", 2),
                        term("fetch_video", 1), term("inkwell", 0, sources: [ProjectTermProposal.Agent.claude.source])],
                repository: "example/demo", github: demoFacts),
            project("remote:demo", "demo", ago: 2, terms: [term("reindex", 3)], repository: "example/demo",
                    github: demoFacts, hosts: ["h1"]),
            project("remote:glossator", "glossator", ago: 20, repository: "example/glossator", hosts: ["h1"]),
            project("remote:working-set", "working-set", ago: 50, repository: "example/working-set", hosts: ["h2"]),
            project(
                "/work/mlx-audio-swift", "mlx-audio-swift", ago: 74, repository: "example/mlx-audio-swift",
                github: GitHubRepositoryFacts(description: "Speech on Apple silicon", topics: [], parent: "upstream-org/mlx-audio-swift")),
            project("/work/scratch-notes", "scratch-notes", ago: 196),
            // Outside every project: the "No project" entry.
            project(LearnedTermProjectResolver.shared.key, LearnedTermProjectResolver.shared.name, ago: 30,
                    terms: [term("Qwen", 6), term("Ghostty", 3)]),
            // A remote label no host named.
            LearnedTermProject(
                key: "remote:bold-bose-fac585", name: "bold-bose-fac585", terms: [term("speechd", 2)],
                lastSeen: now.addingTimeInterval(-90 * 3_600)),
        ])
    }

    private func projectsInbox(_ settings: SettingsStore) throws -> QuickCaptureInboxViewModel {
        let now = Date()
        let learned = projectsLearnedTerms()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("projects-snapshot-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("quick-captures.json")
        func capture(_ key: String, _ state: QuickCaptureItem.State) -> QuickCaptureItem {
            var item = QuickCaptureItem(capturedAt: now, text: "a note")
            item.projectKey = key
            item.state = state
            return item
        }
        try QuickCaptureInboxFile.save(QuickCaptureInbox(items: [
            capture("/work/demo", .ready), capture("/work/demo", .ready), capture("remote:demo", .drafting),
            capture("/work/demo", .filed), capture("/work/demo", .filed),
            capture("remote:working-set", .ready), capture("/work/mlx-audio-swift", .ready),
        ]), to: fileURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inbox = QuickCaptureInboxViewModel(
            settings: settings, learnedTerms: { learned }, fileURL: fileURL, applicationSupport: directory)
        inbox.enrolledHosts = { [(id: "h1", name: "devbox"), (id: "h2", name: "buildbox")] }
        let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
        var claude = ClaudeSessionSnapshot(sessionID: "s1", origin: local, firstSeen: now)
        claude.workspace = .make(rawCwd: "/work/demo", origin: local)
        var opencode = ClaudeSessionSnapshot(sessionID: "s2", origin: .remote(channel: "ssh:h1"), firstSeen: now)
        opencode.agent = .opencode
        opencode.workspace = .make(rawCwd: "/home/me/demo", origin: .remote(channel: "ssh:h1"))
        inbox.liveSessions = { [claude, opencode] }
        return inbox
    }

    /// Dictation → Output → Send phrases (#839): the saved
    /// list, and a refused one with its reason under the row.
    func testSendPhrasesRow() throws {
        let (settings, _) = makeViewModel()
        settings.spokenSendTriggerPhrases = ["ship it", "over and out"]
        let refusal = SendTriggerPhrases.Refusal.commonWord("done").message
        for (name, draft, message) in [("saved", nil, nil), ("refused", "ship it, done", refusal)] as [(String, String?, String?)] {
            try record(
                SettingsGroup(title: "Output") {
                    SendPhrasesRow(settings: settings, draft: draft, refusal: message)
                }
                .padding(20),
                name: "settings-send-phrases-\(name)",
                width: 600, height: 160, growToFit: false)
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

    // MARK: - Failure log

    /// The failure alert's Show Log window after a polish timeout, and when
    /// `log show` cannot be read (#1072).
    func testFailureLogWindow() throws {
        let lines = """
            2026-09-29 14:02:11 [Polishing] LLM polishing request sent [endpoint: http://127.0.0.1:8090/v1]
            2026-09-29 14:02:41 [Polishing] error: LLM polishing connection failure [endpoint: http://127.0.0.1:8090/v1] Polishing timed out.
            2026-09-29 14:02:41 [Backends] error: polish request failed: <private>

            """
        let states: [(String, FailureLogModel)] = [
            ("loaded", FailureLogModel(details: "The request timed out. (NSURLErrorDomain -1001)", lines: .loaded(lines))),
            ("unreadable", FailureLogModel(details: nil, lines: .unreadable("Could not read the log: /usr/bin/log exited with 64."))),
        ]
        for (name, model) in states {
            try record(FailureLogView(model: model), name: "failure-log-\(name)", width: 760, height: 460, growToFit: false)
        }
    }

    // MARK: - Menu bar icon

    /// The needs-you marks beside the idle mic, on a light and a dark menu
    /// bar: at the size the menu bar draws them, and enlarged to 4 pt a
    /// cell without smoothing, so the pixel grid shows.
    func testMenuBarAttentionMarks() throws {
        let template = try MenuBarIconFixture.template()
        let icons: [(name: String, image: NSImage)] =
            [("idle", Self.tinted(template))]
            + AgentAttentionMark.allCases.map {
                ($0.displayName, MenuBarStatusIcon.withAttentionMark(template: template, mark: $0))
            }
        for (theme, appearance, bar) in [
            ("light", NSAppearance.Name.aqua, Color(white: 0.9)),
            ("dark", NSAppearance.Name.darkAqua, Color(white: 0.15)),
        ] {
            let renders = try icons.map { icon in
                let rep = try MenuBarIconFixture.render(icon.image, appearance: appearance)
                let image = NSImage(size: rep.size)
                image.addRepresentation(rep)
                return (name: icon.name, image: image)
            }
            let view = HStack(alignment: .top, spacing: 20) {
                ForEach(renders.indices, id: \.self) { index in
                    let icon = renders[index]
                    VStack(spacing: 8) {
                        // The label's frame in `localvoxtralApp`.
                        Image(nsImage: icon.image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 13, height: 16)
                            .frame(height: 24)
                        Image(nsImage: icon.image)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 88, height: 88)
                        Text(icon.name)
                            .font(.caption)
                    }
                }
            }
            .padding(16)
            .background(bar)
            .environment(\.colorScheme, theme == "light" ? .light : .dark)
            try record(view, name: "menu-bar-marks-\(theme)", width: 520, height: 200, growToFit: false)
        }
    }

    /// The template as the menu bar tints it: in the text color of the
    /// appearance it is drawn under.
    private static func tinted(_ template: NSImage) -> NSImage {
        NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    // MARK: - Overlay panel

    func testOverlayPanelStates() throws {
        let metrics = OverlayLayoutMetrics(bodyFontSize: OverlayLayoutMetrics.defaultBodyFontSize)
        let sample = "Rename the retry helper and run the unit tests again."
        // What polish landed on (#1074): the raw words, then the polished.
        let raw = "so um rename the retry helper to retry with back off and run the unit test again"
        let polishedText = "Rename the retry helper to retryWithBackoff and run the unit tests again."
        let speaking = OverlayMicLevel()
        for level in [0.35, 0.95, 0.6, 0.8] { speaking.push(level) }
        let states: [(name: String, view: DictationOverlayView)] = [
            ("ready", DictationOverlayView(
                phase: .idle, text: "", errorMessage: nil, secureInputActive: false,
                metrics: metrics)),
            ("listening", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics, micLevel: speaking, motion: .frozen)),
            ("listening-silent", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics, micLevel: OverlayMicLevel(), motion: .frozen)),
            ("listening-reduce-motion", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics, micLevel: speaking, motion: .reduced)),
            ("listening-joined", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics, claudeJoin: .joined(label: "localvoxtral"))),
            ("listening-unjoined", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics, claudeJoin: .unjoined)),
            ("draft-review", DictationOverlayView(
                phase: .buffering, text: "", errorMessage: nil, secureInputActive: false,
                metrics: metrics, draftReview: Self.draft)),
            ("draft-review-change", DictationOverlayView(
                phase: .buffering, text: "Make it only the popover part", errorMessage: nil,
                secureInputActive: false, metrics: metrics, draftReview: Self.draft)),
            ("secure-input", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: true,
                metrics: metrics)),
            ("finalizing", DictationOverlayView(
                phase: .finalizing, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics)),
            ("polishing", DictationOverlayView(
                phase: .finalizing, text: raw, errorMessage: nil, secureInputActive: false,
                metrics: metrics, polishing: true, motion: .frozen)),
            ("polishing-reduce-motion", DictationOverlayView(
                phase: .finalizing, text: raw, errorMessage: nil, secureInputActive: false,
                metrics: metrics, polishing: true, motion: .reduced)),
            ("polished", DictationOverlayView(
                phase: .finalizing, text: polishedText, errorMessage: nil, secureInputActive: false,
                metrics: metrics, polished: true, polishedFrom: raw, motion: .frozen)),
            // "Color for polished words" set to the system accent.
            ("polishing-accent", DictationOverlayView(
                phase: .finalizing, text: raw, errorMessage: nil, secureInputActive: false,
                metrics: metrics, polishing: true, motion: .frozen,
                polishColor: OverlayPolishColor.systemAccent.color)),
            ("polished-accent", DictationOverlayView(
                phase: .finalizing, text: polishedText, errorMessage: nil, secureInputActive: false,
                metrics: metrics, polished: true, polishedFrom: raw, motion: .frozen,
                polishColor: OverlayPolishColor.systemAccent.color)),
            ("commit-failed", DictationOverlayView(
                phase: .commitFailed, text: sample,
                errorMessage: "Couldn't insert. Copied for manual paste.",
                secureInputActive: false, metrics: metrics)),
        ]
        // Where the words go (#1015), with 1, 3 and 10 agents waiting: the
        // list closed on the second agent, then open on it.
        let destinations = [1, 3, 10].flatMap { waiting in
            [false, true].map { open in
                (name: "destinations-\(waiting)-\(open ? "open" : "closed")",
                 view: DictationOverlayView(
                    phase: .buffering, text: sample, errorMessage: nil, secureInputActive: false,
                    metrics: metrics, destinations: Self.strip(waiting: waiting, open: open)))
            }
        }
        // The #1074 states on a dark desktop too: the marks, the band and
        // the tints must read on both.
        let darkNames: Set = [
            "listening", "polishing", "polished", "polished-accent", "destinations-3-open", "destinations-3-closed",
        ]
        let renders: [(String, DictationOverlayView, NSAppearance.Name)] = (states + destinations).map { ($0.name, $0.view, .aqua) }
            + (states + destinations).filter { darkNames.contains($0.name) }.map { ("\($0.name)-dark", $0.view, .darkAqua) }
        for (name, overlay, appearance) in renders {
            let height = metrics.contentHeight(
                text: overlay.text, errorMessage: overlay.errorMessage, draftReview: overlay.draftReview,
                destinations: overlay.destinations)
            // A flat backdrop stands in for the desktop the panel floats over.
            let inset: CGFloat = 16
            let view = overlay
                .frame(width: metrics.panelWidth, height: height)
                .padding(inset)
                .background(Color(white: appearance == .darkAqua ? 0.22 : 0.55))
            try record(
                view, name: "overlay-\(name)",
                width: metrics.panelWidth + 2 * inset, height: height + 2 * inset, growToFit: false,
                appearance: appearance)
        }
    }

    /// A ready draft under spoken review (#927).
    private static let draft = QuickCaptureDraftSnapshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000927")!,
        projectName: "localvoxtral",
        title: "Show drafting progress in the Inbox row",
        body: """
        ## Problem
        A capture shows "Drafting" with a spinner for minutes and never says which step it is on.

        ## Scope
        The Inbox row names the drafting step. The popover is unchanged.
        """
    )

    /// Made-up session names as long as real ones: worktree folders, and
    /// Claude Desktop titles, which run to about 70 characters (#1013).
    private static let sessionNames = [
        "Fix test-remote-doctor.sh broken-pipe flake in the harness scripts",
        "history-store-own-file-a41c2e",
        "Polish prompt token sizes in Settings and History",
        "quick-capture-polish-before-routing",
        "Voice memos keep follow-up recordings",
        "overlay-destination-list-1015",
        "Learned terms import and export move to Projects",
        "remote-join-diagnosis-3b9d10",
        "Boost the user's terms while Nemotron decodes",
        "eval-e2e-scheduled-run-guard-874",
    ]

    /// The overlay's destinations (#840) with `waiting` sessions waiting,
    /// the first of them picked: the second Tab.
    private static func strip(waiting: Int, open: Bool) -> OverlayDestinationStrip {
        let ids = (0..<waiting).map { "s\($0)" }
        return OverlayDestinationStrip(
            list: DictationDestinationList(
                waitingSessionIDs: ids, focusedSessionID: nil, selected: .session(id: ids[0])),
            focusedAppLabel: "ci-speed-optimizations-7ffef0",
            focusedAppJoined: true,
            sessionName: { id in sessionNames[Int(id.dropFirst())!] },
            isOpen: open
        )
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
        _ view: V, name: String, width: CGFloat, height: CGFloat, growToFit: Bool,
        appearance: NSAppearance.Name = .aqua
    ) throws {
        let url = try ViewSnapshot.record(
            view, name: name, width: width, height: height, growToFit: growToFit, appearance: appearance)
        // The hosting view sizes its window to the content, so the image is
        // the view's own size, not necessarily the one asked for.
        let image = try XCTUnwrap(NSImage(contentsOf: url), "\(name).png does not read back")
        XCTAssertGreaterThan(image.size.width, 0, name)
        XCTAssertGreaterThan(image.size.height, 0, name)
    }
}
