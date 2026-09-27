import Foundation
@testable import localvoxtralCore
import localvoxtralTestSupport
import XCTest

/// The host installs the plugin this app ships, whatever GitHub's main holds
/// (#836). The setup scripts run for real under `/bin/sh` against a fake
/// `claude` that models the CLI behaviour measured on 2.1.283: `marketplace
/// add` replaces a name's source and keeps the installed plugin, `plugin
/// update` installs whatever the marketplace offers (older included), and a
/// GitHub marketplace offers main's head.
final class ClaudeRemotePluginPinningTests: XCTestCase {
    private static let mainHead = "1.99.0"

    private static let fakeClaude = """
        #!/bin/sh
        S="$HOME/fake-claude"
        mkdir -p "$S"
        offered() {
          src=$(cat "$S/source" 2>/dev/null || true)
          case "$src" in
            github) echo \(mainHead) ;;
            /*) sed -n 's/^ *"version": *"\\([0-9.]*\\)".*/\\1/p' "$src/plugins/localvoxtral-remote/.claude-plugin/plugin.json" | head -n 1 ;;
            *) exit 1 ;;
          esac
        }
        case "$1 $2 ${3-}" in
          "plugin list --json")
            printf '['
            [ ! -f "$S/installed" ] || printf '{"id":"localvoxtral-remote@localvoxtral","version":"%s","scope":"user"}' "$(cat "$S/installed")"
            printf ']\\n' ;;
          "plugin marketplace add")
            case "$4" in /*) echo "$4" >"$S/source" ;; *) echo github >"$S/source" ;; esac ;;
          "plugin marketplace update") [ -f "$S/source" ] ;;
          "plugin marketplace remove") rm -f "$S/source" "$S/installed" "$S/token" ;;
          "plugin update "*) [ -f "$S/installed" ] && offered >"$S/installed.new" && mv "$S/installed.new" "$S/installed" ;;
          "plugin install "*)
            [ -f "$S/installed" ] || { offered >"$S/installed.new" && mv "$S/installed.new" "$S/installed"; }
            for a in "$@"; do case "$a" in token=*) echo "${a#token=}" >"$S/token" ;; esac; done ;;
          *) exit 2 ;;
        esac
        """

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lvx-pinning-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try Self.fakeClaude.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// A host enrolled from the GitHub marketplace at `installed`, token set.
    private func enrollFromGitHub(installed: String) throws {
        let state = home.appendingPathComponent("fake-claude")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try "github\n".write(to: state.appendingPathComponent("source"), atomically: true, encoding: .utf8)
        try "\(installed)\n".write(to: state.appendingPathComponent("installed"), atomically: true, encoding: .utf8)
        try "host-token\n".write(to: state.appendingPathComponent("token"), atomically: true, encoding: .utf8)
    }

    private func state(_ name: String) -> String? {
        (try? String(contentsOf: home.appendingPathComponent("fake-claude/\(name)"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `ssh <alias> /bin/sh -s`, minus the ssh: the script runs here, in the
    /// fake host's HOME.
    private func localShellService() -> ClaudeRemoteEnrollmentService {
        let home = home.path
        return ClaudeRemoteEnrollmentService(runner: { invocation in
            let scratch = URL(fileURLWithPath: home).appendingPathComponent("run-\(UUID().uuidString)")
            try invocation.standardInput.write(to: scratch.appendingPathExtension("sh"))
            let exitCode = try SpawnAndWait.run(
                "/bin/sh",
                arguments: ["-s"],
                environment: ["HOME": home, "PATH": "/usr/bin:/bin"],
                standardInput: scratch.appendingPathExtension("sh").path,
                output: scratch.appendingPathExtension("out").path
            )
            let output = (try? String(contentsOf: scratch.appendingPathExtension("out"), encoding: .utf8)) ?? ""
            return .init(exitCode: exitCode, message: output)
        })
    }

    func testAHostOnAnOlderPluginGetsTheAppsVersionWhileMainIsAhead() throws {
        try enrollFromGitHub(installed: "1.4.0")
        XCTAssertEqual(
            try localShellService().setupRemotePlugin(sshHostAlias: "builder", token: nil, remoteForwardPort: 28_511),
            .updated
        )
        XCTAssertEqual(state("installed"), ClaudeRemoteEnrollmentService.remotePluginVersion)
        XCTAssertEqual(state("token"), "host-token", "an update keeps the stored token")
    }

    func testAHostAheadOfTheAppComesBackToTheAppsVersion() throws {
        try enrollFromGitHub(installed: Self.mainHead)
        XCTAssertEqual(
            try localShellService().setupRemotePlugin(sshHostAlias: "builder", token: nil, remoteForwardPort: 28_511),
            .updated
        )
        XCTAssertEqual(state("installed"), ClaudeRemoteEnrollmentService.remotePluginVersion)
        XCTAssertEqual(state("token"), "host-token", "going back keeps the stored token")
    }

    func testAFreshInstallUsesTheAppsCopyAndLeavesItOnTheHost() throws {
        XCTAssertEqual(
            try localShellService().setupRemotePlugin(sshHostAlias: "builder", token: "t0k", remoteForwardPort: 28_511),
            .installed
        )
        XCTAssertEqual(state("installed"), ClaudeRemoteEnrollmentService.remotePluginVersion)
        XCTAssertEqual(state("token"), "t0k")

        // The source is the copy, byte for byte, and nothing else is left
        // beside it.
        let directory = home.appendingPathComponent(".local/share/localvoxtral/claude-marketplace")
        XCTAssertEqual(state("source"), directory.path)
        let bundled = try XCTUnwrap(ClaudeRemoteMarketplaceFiles.bundled())
        XCTAssertEqual(
            try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .filter { path in
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(path).path, isDirectory: &isDirectory
                    )
                    return !isDirectory.boolValue
                }
                .sorted(),
            bundled.files.map(\.relativePath).sorted()
        )
        for file in bundled.files {
            let url = directory.appendingPathComponent(file.relativePath)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), file.content, file.relativePath)
            XCTAssertEqual(FileManager.default.isExecutableFile(atPath: url.path), file.executable, file.relativePath)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.deletingLastPathComponent().path
            ),
            ["claude-marketplace"],
            "no staging tree survives the swap"
        )
    }

    func testABuildWhoseCopyCarriesAnotherVersionChangesNothing() throws {
        try enrollFromGitHub(installed: "1.4.0")
        var marketplace = try XCTUnwrap(ClaudeRemoteMarketplaceFiles.bundled())
        let manifest = try XCTUnwrap(marketplace.files.firstIndex {
            $0.relativePath == "plugins/localvoxtral-remote/.claude-plugin/plugin.json"
        })
        marketplace.files[manifest].content = marketplace.files[manifest].content.replacingOccurrences(
            of: "\"\(ClaudeRemoteEnrollmentService.remotePluginVersion)\"", with: "\"0.0.1\""
        )
        XCTAssertThrowsError(
            try localShellService().setupRemotePlugin(
                sshHostAlias: "builder", token: nil, remoteForwardPort: 28_511, marketplace: marketplace
            )
        ) { error in
            guard case ClaudeRemoteEnrollmentService.ServiceError.commandFailed(_, _, 47, _) = error else {
                return XCTFail("expected exit 47, got \(error)")
            }
        }
        XCTAssertEqual(state("installed"), "1.4.0")
        XCTAssertEqual(state("source"), "github")
    }
}
