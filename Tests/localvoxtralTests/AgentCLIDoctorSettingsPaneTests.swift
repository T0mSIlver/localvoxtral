import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

/// Every `Settings > <pane>` a `doctor` fix names is a pane in the Settings
/// sidebar: an agent that follows the fix, or reads it to the user, must find
/// it. Covers the Mac's checks in every state and the host's doctor.sh.
@MainActor
final class AgentCLIDoctorSettingsPaneTests: XCTestCase {
    func testEveryPaneAFixNamesIsInTheSidebar() throws {
        let panes = Set(SettingsTab.allKnownPanes.map(\.title))
        var fixes = Self.everyMacFix()
        XCTAssertGreaterThan(fixes.count, 25, "the fixtures stopped reaching the fixes")
        let doctorScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("integrations/claude-code/plugins/localvoxtral-remote/hooks/doctor.sh")
        fixes.append(try String(contentsOf: doctorScript, encoding: .utf8))

        var named: Set<String> = []
        for fix in fixes { named.formUnion(Self.paneNames(in: fix)) }
        XCTAssertTrue(named.isSuperset(of: ["Engines", "Claude Code", "Codex", "opencode", "Mistral Vibe",
                                            "Remote hosts", "General", "About"]), "\(named.sorted())")
        XCTAssertEqual(named.subtracting(panes).sorted(), [], "fixes name panes the sidebar does not have")
    }

    func testPaneNamesStopAtTheFirstSeparator() {
        XCTAssertEqual(
            Self.paneNames(in: "System Settings > Privacy & Security > Microphone: on. Settings > Claude Code > Update, "
                + "then Settings > Engines: paste a key, or Keep the tunnel open in Settings > Remote hosts."),
            ["Claude Code", "Engines", "Remote hosts"]
        )
    }

    /// The pane after each `Settings > `, up to ` >`, `:`, `,`, `.` or `…`.
    /// macOS's own "System Settings" is not ours.
    static func paneNames(in text: String) -> Set<String> {
        var names: Set<String> = []
        var rest = Substring(text)
        while let range = rest.range(of: "Settings > ") {
            let before = rest[..<range.lowerBound]
            rest = rest[range.upperBound...]
            guard !before.hasSuffix("System ") else { continue }
            let end = rest.firstIndex { ":,.…".contains($0) } ?? rest.endIndex
            var name = rest[..<end]
            if let arrow = name.range(of: " >") { name = name[..<arrow.lowerBound] }
            names.insert(name.trimmingCharacters(in: .whitespaces))
        }
        return names
    }

    /// Each check in each of its states.
    static func everyMacFix() -> [String] {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let engines: [AgentCLIDoctorFacts.Engine] = [
            .off, .externalURL, .mistralAPI(keySet: false), .mistralAPI(keySet: true),
            .managed(.ready), .managed(.starting), .managed(.stopped),
            .managed(.preparingModel(progress: ModelDownloadProgress(downloadedBytes: 1, totalBytes: 2))),
            .managed(.pausedModelDownload(progress: ModelDownloadProgress(downloadedBytes: 1, totalBytes: 2))),
            .managed(.failed(summary: "exited", detail: "")),
        ]
        let claude: [ClaudePluginStatus] = [
            .unknown, .notInstalled, .installed(version: "2.4.0"),
            .updateAvailable(installed: "2.3.0", bundled: "2.4.0"), .failedToLoad(version: "2.4.0"),
        ]
        let codex: [CodexPluginInstallService.Status] = [.unknown, .notInstalled, .disabled, .installed, .updateAvailable]
        let opencode: [OpencodePluginInstallService.Status] = [
            .notInstalled, .listedMissing, .installedUnlisted, .installed, .updateAvailable, .unknown,
        ]
        let vibe: [VibeHooksInstallService.Status] = [
            .notInstalled, .hooksWithoutShim, .shimWithoutHooks, .installed, .updateAvailable, .conflictingHooks, .unknown,
        ]
        let notes: [DictationNoteInstallService.Status] = [
            .notAdded, .added(path: "a"), .differs(path: "a"), .needsManualFix(path: "a", .symlink), .unknown,
        ]
        let links: [AgentCLIInstallState] = [.notInstalled, .installed, .otherCopy, .foreign]
        let hosts: [AgentCLIDoctorFacts.RemoteHost] = [
            .init(label: "a", sshHostAlias: "a", lastSeenAt: nil, pluginNeedsUpdate: false),
            .init(label: "b", sshHostAlias: nil, lastSeenAt: nil, pluginNeedsUpdate: false, forwardFailure: "x"),
            .init(label: "c", lastSeenAt: now, pluginNeedsUpdate: true),
            .init(label: "d", lastSeenAt: now.addingTimeInterval(-200_000), pluginNeedsUpdate: false),
            .init(label: "e", lastSeenAt: now.addingTimeInterval(-200_000), pluginNeedsUpdate: false, keepsTunnelOpen: true),
            .init(label: "f", lastSeenAt: nil, pluginNeedsUpdate: false, keepsTunnelOpen: true),
        ]
        let permissions: [AgentCLIDoctorFacts.Permission] = [.granted, .denied, .restricted, .notAsked]
        let count = [engines.count, claude.count, codex.count, opencode.count, vibe.count, notes.count, links.count,
                     permissions.count].max() ?? 0
        var fixes: [String] = []
        for index in 0..<count {
            let facts = AgentCLIDoctorFacts(
                appVersion: "1", appBundlePath: "/Applications/localvoxtral.app",
                commandLink: .init(state: links[index % links.count]),
                microphone: permissions[index % permissions.count],
                accessibilityTrusted: index % 2 == 0,
                speech: engines[index % engines.count],
                polish: engines[(index + 3) % engines.count],
                claudePlugin: claude[index % claude.count],
                codexPlugin: codex[index % codex.count],
                codexHookHeard: index % 2 == 1,
                opencodePlugin: opencode[index % opencode.count],
                vibeHooks: vibe[index % vibe.count],
                dictationNotes: Dictionary(uniqueKeysWithValues: DictationNoteAgent.allCases.map {
                    ($0, notes[index % notes.count])
                }),
                remoteHosts: hosts,
                recentJoins: [.init(at: now, line: index % 2 == 0 ? "arm=none origin=none causes=x" : "arm=tty")],
                now: now
            )
            let checks = AgentCLIDoctorChecks.checks(facts) + AgentCLIDoctorChecks.hostChecks(facts, hostIndex: 0)
            fixes += checks.compactMap(\.fix)
        }
        return fixes
    }
}
