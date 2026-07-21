import Foundation
import XCTest
@testable import localvoxtral

/// Validates the in-repo Claude Code marketplace as an artifact.
///
/// These assertions are cheap and catch the class of breakage that is otherwise
/// only visible when a user runs `claude plugin install` and it fails: a typo'd
/// hook event, a plugin source that does not exist, a hook command that lost its
/// `${CLAUDE_PLUGIN_ROOT}` prefix and silently resolves to nothing.
final class ClaudePluginManifestTests: XCTestCase {
    private var marketplace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        marketplace = try XCTUnwrap(
            ClaudePluginAssets.developmentMarketplaceURL(),
            "the repo checkout must contain integrations/claude-code"
        )
    }

    private func json(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every string that appears as a KEY or VALUE anywhere in a parsed JSON
    /// tree. Lets a check assert on the manifest's actual content rather than
    /// its raw file text — a structural read that cannot be fooled by, or trip
    /// over, formatting.
    private static func jsonStrings(in object: Any) -> [String] {
        switch object {
        case let string as String:
            return [string]
        case let array as [Any]:
            return array.flatMap { jsonStrings(in: $0) }
        case let dictionary as [String: Any]:
            return dictionary.flatMap { key, value in [key] + jsonStrings(in: value) }
        default:
            return []
        }
    }

    private var marketplaceManifest: URL {
        marketplace.appendingPathComponent(".claude-plugin/marketplace.json")
    }

    private var pluginRoot: URL {
        marketplace.appendingPathComponent("plugins/localvoxtral")
    }

    private var remotePluginRoot: URL {
        marketplace.appendingPathComponent("plugins/\(ClaudePluginAssets.remotePluginName)")
    }

    // MARK: Marketplace

    func testMarketplaceIsRecognisedAsAMarketplace() {
        XCTAssertTrue(ClaudePluginAssets.isMarketplace(marketplace))
    }

    func testMarketplaceManifestIsValidJSONWithRequiredFields() throws {
        let manifest = try json(at: marketplaceManifest)
        XCTAssertEqual(manifest["name"] as? String, ClaudePluginAssets.marketplaceName)
        XCTAssertNotNil(manifest["owner"] as? [String: Any])
        let plugins = try XCTUnwrap(manifest["plugins"] as? [[String: Any]])
        XCTAssertEqual(
            plugins.compactMap { $0["name"] as? String },
            [ClaudePluginAssets.pluginName, ClaudePluginAssets.remotePluginName]
        )
    }

    func testEveryMarketplacePluginSourceResolvesToARealDirectory() throws {
        let manifest = try json(at: marketplaceManifest)
        let plugins = try XCTUnwrap(manifest["plugins"] as? [[String: Any]])
        for plugin in plugins {
            let source = try XCTUnwrap(plugin["source"] as? String)
            let resolved = marketplace.appendingPathComponent(source).standardizedFileURL
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                "plugin source \(source) does not exist"
            )
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: resolved.appendingPathComponent(".claude-plugin/plugin.json").path
                ),
                "plugin source \(source) has no manifest"
            )
        }
    }

    // MARK: Root marketplace (what a remote host installs from)

    /// A remote host has no app bundle to register a directory from, so it runs
    /// `claude plugin marketplace add T0mSIlver/localvoxtral` — which resolves
    /// `.claude-plugin/marketplace.json` at the repository ROOT. Two manifests
    /// that must never drift apart, hence this test rather than trust.
    func testRootMarketplaceMirrorsTheBundledOne() throws {
        let root = try XCTUnwrap(ClaudePluginAssets.rootMarketplaceURL())
        XCTAssertTrue(
            ClaudePluginAssets.isMarketplace(root),
            "the repo root must be a marketplace: a remote host installs from the GitHub repo"
        )
        let rootManifest = try json(at: root.appendingPathComponent(".claude-plugin/marketplace.json"))
        let bundled = try json(at: marketplaceManifest)
        XCTAssertEqual(
            rootManifest["name"] as? String,
            bundled["name"] as? String,
            "both manifests must name the same marketplace, or the plugin reference differs by machine"
        )
        let rootPlugins = try XCTUnwrap(rootManifest["plugins"] as? [[String: Any]])
        let bundledPlugins = try XCTUnwrap(bundled["plugins"] as? [[String: Any]])
        XCTAssertEqual(
            rootPlugins.compactMap { $0["name"] as? String },
            bundledPlugins.compactMap { $0["name"] as? String }
        )
    }

    func testRootMarketplacePluginSourcesResolveFromTheRepoRoot() throws {
        let root = try XCTUnwrap(ClaudePluginAssets.rootMarketplaceURL())
        let manifest = try json(at: root.appendingPathComponent(".claude-plugin/marketplace.json"))
        let plugins = try XCTUnwrap(manifest["plugins"] as? [[String: Any]])
        XCTAssertFalse(plugins.isEmpty)
        for plugin in plugins {
            let source = try XCTUnwrap(plugin["source"] as? String)
            // The root manifest is one directory tree up from the bundled one,
            // so its sources must be rewritten for that depth. A copy-paste of
            // "./plugins/..." would resolve to nothing and only fail on a
            // remote host, at install time.
            XCTAssertTrue(
                source.hasPrefix("./\(ClaudePluginAssets.repositoryRelativePath)/"),
                "root marketplace source must be repo-root relative: \(source)"
            )
            let resolved = root.appendingPathComponent(source).standardizedFileURL
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: resolved.appendingPathComponent(".claude-plugin/plugin.json").path
                ),
                "root marketplace source \(source) does not resolve"
            )
        }
    }

    func testNoUserFacingManifestURLPointsAtTheOldOwner() throws {
        // The repo moved to T0mSIlver; a stale owner in a manifest is a link
        // users click and a marketplace reference that resolves to nothing.
        //
        // Structural, not a raw-text grep: parse each manifest and inspect every
        // string it actually declares (keys and values, recursively). That both
        // proves the file is valid JSON and — matching case-insensitively —
        // catches a `TomVaucourt`/`tomvaucourt` a case-sensitive substring scan
        // would miss, so it is strictly stronger than the old text search.
        let root = try XCTUnwrap(ClaudePluginAssets.rootMarketplaceURL())
        let manifests = [
            marketplaceManifest,
            root.appendingPathComponent(".claude-plugin/marketplace.json"),
            pluginRoot.appendingPathComponent(".claude-plugin/plugin.json"),
            remotePluginRoot.appendingPathComponent(".claude-plugin/plugin.json"),
        ]
        for manifest in manifests {
            for string in Self.jsonStrings(in: try json(at: manifest)) {
                XCTAssertFalse(
                    string.lowercased().contains("tomvaucourt"),
                    "\(manifest.lastPathComponent) still points at the old repo owner via \"\(string)\""
                )
            }
        }
    }

    // MARK: Plugin

    func testPluginManifestIsValidAndLeavesTheStandardHooksFileImplicit() throws {
        let manifest = try json(at: pluginRoot.appendingPathComponent(".claude-plugin/plugin.json"))
        XCTAssertEqual(manifest["name"] as? String, ClaudePluginAssets.pluginName)
        XCTAssertNotNil(manifest["description"] as? String)
        XCTAssertNotNil(manifest["version"] as? String)
        // Claude Code loads hooks/hooks.json by convention and rejects a
        // manifest that names it again as a duplicate hooks file — the plugin
        // installs but lands "failed to load" (field bug, #150 hand test).
        // manifest.hooks may only reference ADDITIONAL hook files.
        XCTAssertNil(manifest["hooks"], "naming the standard hooks file makes the CLI refuse to load the plugin")
    }

    func testPluginDeclaresNoTokenConsumingSurfaces() throws {
        // The plugin is a data channel, not a Claude feature: a skill, command,
        // or agent would put tokens (and latency) on the user's turn for
        // something they never asked Claude to do. `statusLine` is in the list
        // for the same reason and a sharper one — it runs on EVERY turn — and
        // because the remote plugin's guard already covers it: the two manifests
        // make the same promise, so they must be held to the same list.
        let manifest = try json(at: pluginRoot.appendingPathComponent(".claude-plugin/plugin.json"))
        for key in ["skills", "commands", "agents", "mcpServers", "statusLine"] {
            XCTAssertNil(manifest[key], "the plugin must not declare \(key)")
        }
        for directory in ["skills", "commands", "agents"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent(directory).path),
                "the plugin must not ship a \(directory)/ directory"
            )
        }
    }

    // MARK: Hooks

    private func hooksByEvent() throws -> [String: [[String: Any]]] {
        let manifest = try json(at: pluginRoot.appendingPathComponent("hooks/hooks.json"))
        return try XCTUnwrap(manifest["hooks"] as? [String: [[String: Any]]])
    }

    /// Every `command` string across every event.
    private func allCommands() throws -> [String] {
        try hooksByEvent().values.flatMap { matchers in
            matchers.flatMap { matcher -> [String] in
                let entries = matcher["hooks"] as? [[String: Any]] ?? []
                return entries.compactMap { $0["command"] as? String }
            }
        }
    }

    func testDeclaresEveryRequiredEvent() throws {
        let events = Set(try hooksByEvent().keys)
        XCTAssertEqual(
            events,
            [
                "SessionStart", "UserPromptSubmit", "CwdChanged",
                "PostToolUse", "Stop", "SessionEnd",
            ]
        )
    }

    func testDeclaresNoFileChangedHookWithoutWatchPaths() throws {
        // Claude Code only fires FileChanged for a hook that declares
        // watchPaths. We declare none, so the hook would never fire — a dead
        // entry that reads like working coverage. PostToolUse already reports
        // every file the model touches.
        let hooks = try hooksByEvent()
        XCTAssertNil(hooks["FileChanged"])
        for (_, matchers) in hooks {
            for matcher in matchers {
                XCTAssertNil(matcher["watchPaths"], "no hook declares watchPaths today")
            }
        }
    }

    func testEveryHookCommandUsesPluginRootAndTheShim() throws {
        let commands = try allCommands()
        XCTAssertEqual(commands.count, 6, "one command per event")
        for command in commands {
            // QUOTED (F7): hook commands run through a shell, and the plugin
            // root lives under "~/.claude" today but is an implementation
            // detail — an unquoted ${CLAUDE_PLUGIN_ROOT} word-splits on any
            // space in the path (e.g. an "Application Support" install) and
            // the hook dies silently.
            XCTAssertTrue(
                command.hasPrefix("\"${CLAUDE_PLUGIN_ROOT}/hooks/publish.sh\" "),
                "hook command must resolve through a QUOTED ${CLAUDE_PLUGIN_ROOT}: \(command)"
            )
        }
    }

    func testEachHookPassesItsOwnEventName() throws {
        for (event, matchers) in try hooksByEvent() {
            let commands = matchers.flatMap { matcher -> [String] in
                let entries = matcher["hooks"] as? [[String: Any]] ?? []
                return entries.compactMap { $0["command"] as? String }
            }
            for command in commands {
                XCTAssertTrue(
                    command.hasSuffix(" \(event)"),
                    "\(event) hook must pass its event name, got: \(command)"
                )
            }
        }
    }

    func testEveryHookIsACommandTypeWithAShortTimeout() throws {
        for (_, matchers) in try hooksByEvent() {
            for matcher in matchers {
                let entries = try XCTUnwrap(matcher["hooks"] as? [[String: Any]])
                for entry in entries {
                    XCTAssertEqual(entry["type"] as? String, "command")
                    let timeout = try XCTUnwrap(entry["timeout"] as? Int)
                    XCTAssertLessThanOrEqual(timeout, 5, "a hook must never stall a turn")
                    XCTAssertGreaterThan(timeout, 0)
                }
            }
        }
    }

    func testPostToolUseMatchesOnlyFileBearingTools() throws {
        let matchers = try XCTUnwrap(try hooksByEvent()["PostToolUse"])
        let matcher = try XCTUnwrap(matchers.first?["matcher"] as? String)
        for tool in ["Read", "Edit", "Write", "NotebookEdit"] {
            XCTAssertTrue(matcher.contains(tool), "matcher should cover \(tool)")
        }
        // Bash carries a command string, not a file path — subscribing to it
        // would wake the publisher on every shell call for nothing.
        XCTAssertFalse(matcher.contains("Bash"))
        // MultiEdit is deprecated in Claude Code; Edit carries batches now.
        XCTAssertFalse(matcher.contains("MultiEdit"))
    }

    // MARK: userConfig

    func testPluginDeclaresPublisherPathUserConfig() throws {
        // This is what lets the shim find a publisher outside the two paths it
        // hardcodes — an app in ~/Applications, a dev build, a mounted volume.
        let manifest = try json(at: pluginRoot.appendingPathComponent(".claude-plugin/plugin.json"))
        let userConfig = try XCTUnwrap(manifest["userConfig"] as? [String: Any])
        let publisherPath = try XCTUnwrap(
            userConfig[ClaudePluginInstallService.publisherPathConfigKey] as? [String: Any]
        )
        XCTAssertEqual(publisherPath["type"] as? String, "string")
        XCTAssertNotNil(publisherPath["description"] as? String)
    }

    func testShimReadsThePublisherPathConfigEnvironmentVariable() throws {
        // Claude Code exposes userConfig to hooks as CLAUDE_PLUGIN_OPTION_<KEY>.
        // The declared key and the variable the shim reads must agree, or the
        // config silently does nothing.
        let source = try String(
            contentsOf: pluginRoot.appendingPathComponent("hooks/publish.sh"), encoding: .utf8
        )
        let expected = "CLAUDE_PLUGIN_OPTION_"
            + ClaudePluginInstallService.publisherPathConfigKey.uppercased()
        XCTAssertTrue(source.contains(expected), "shim must read \(expected)")
    }

    func testEventsThatCarryNoToolUseDeclareNoMatcher() throws {
        for event in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"] {
            let matchers = try XCTUnwrap(try hooksByEvent()[event])
            XCTAssertNil(matchers.first?["matcher"], "\(event) needs no tool matcher")
        }
    }

    // MARK: Shim

    func testShimIsExecutableAndFailsOpen() throws {
        let shim = pluginRoot.appendingPathComponent("hooks/publish.sh")
        // Mode bits: Claude Code execs this directly; without +x every hook errors.
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: shim.path),
            "Claude Code executes this directly; without +x every hook errors"
        )
        // Shebang anchored to the exact first line, not a loose substring that a
        // stray `#!/bin/sh` in a later comment could satisfy.
        let firstLine = try String(contentsOf: shim, encoding: .utf8)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)
        XCTAssertEqual(firstLine, "#!/bin/sh", "must be POSIX sh, not bash")

        // Beyond reading the source: RUN the shim and prove the exit contract.
        // `LOCALVOXTRAL_CLAUDE_HOOK_BIN` is candidate #1 in the shim's search, so
        // injecting a fake publisher through it both selects our stub before any
        // host path and proves that documented override actually works — a
        // stronger check than `source.contains("LOCALVOXTRAL_CLAUDE_HOOK_BIN")`.
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }

        // (1) A publisher that FAILS must not fail the hook: the shim runs it as a
        // child (never exec) precisely so it can swallow this and still exit 0.
        let failing = try writeExecutable(
            "#!/bin/sh\nexit 7\n", named: "failing-publisher", in: temporary
        )
        XCTAssertEqual(
            try runShim(shim, hookBin: failing.path, event: "SessionStart").exitCode, 0,
            "the shim must exit 0 even when the publisher exits non-zero"
        )

        // (2) The publisher is invoked as a child and receives `--event <Event>`.
        let argumentsFile = temporary.appendingPathComponent("args")
        let recorder = try writeExecutable(
            "#!/bin/sh\nprintf '%s' \"$*\" > \(argumentsFile.path)\nexit 0\n",
            named: "recording-publisher", in: temporary
        )
        let run = try runShim(shim, hookBin: recorder.path, event: "Stop")
        XCTAssertEqual(run.exitCode, 0, "the shim always exits 0")
        XCTAssertEqual(
            try String(contentsOf: argumentsFile, encoding: .utf8), "--event Stop",
            "the shim must pass the event through to the publisher as --event <Event>"
        )
    }

    // MARK: Shim execution helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(_ contents: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Runs the shim under `/bin/sh` with a chosen publisher and event, returning
    /// its exit code. stdin is /dev/null so the shim's stdin drain never blocks;
    /// stdout/stderr are captured and discarded (Claude Code parses stdout, so
    /// the shim's own paths must stay silent — not asserted here, but kept off
    /// the test's console).
    private func runShim(_ shim: URL, hookBin: String, event: String) throws -> (exitCode: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [shim.path, event]
        var environment = ProcessInfo.processInfo.environment
        environment["LOCALVOXTRAL_CLAUDE_HOOK_BIN"] = hookBin
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testShimRunsPublisherAsAChildSoExecFailureStillFailsOpen() throws {
        // `exec` replaces the shell, so a publisher that cannot start (Exec
        // format error, missing dyld dep, quarantine) would surface ITS failure
        // as the hook's exit code — a visible error on the user's turn. Running
        // it as a child keeps us alive to swallow that and exit 0.
        let source = try String(
            contentsOf: pluginRoot.appendingPathComponent("hooks/publish.sh"), encoding: .utf8
        )
        XCTAssertFalse(
            source.contains("exec \"$BIN\""),
            "must not exec the publisher — an exec failure would escape as a hook error"
        )
        let lines = source.split(separator: "\n").map(String.init)
        let invocation = try XCTUnwrap(lines.firstIndex { $0.contains("\"$BIN\" --event") })
        XCTAssertTrue(
            lines[invocation].hasPrefix("LOCALVOXTRAL_CLAUDE_PPID="),
            "the child must receive Claude Code's stable parent pid, not the short-lived shim pid"
        )
        let remainder = lines[invocation...].joined(separator: "\n")
        XCTAssertTrue(
            remainder.contains("exit 0"),
            "the shim must exit 0 regardless of the publisher's status"
        )
    }
}
