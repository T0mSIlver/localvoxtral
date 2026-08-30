import Foundation
import Synchronization
import XCTest

#if canImport(Darwin)

/// Support for the `integration-herdr` lane: enablement, the live fixture's
/// lifecycle, and the one thing in that lane that is NOT production code —
/// reading the focused surface.
///
/// The lane's whole point is that everything below the surface is real, so
/// this file deliberately contains no stand-ins for herdr, ssh, or the app's
/// own types. It starts the fixture, reads what a real herdr client painted,
/// and gets out of the way.

// MARK: - Enablement

/// Why the lane could not run. Never an `XCTSkip`: a lane that quietly does
/// nothing is indistinguishable from a lane that passed, and this one exists
/// precisely to catch external drift.
enum HerdrLaneError: Error, CustomStringConvertible {
    case notEnabled(String)
    case fixtureFailed(String)
    case timedOut(String)

    var description: String {
        switch self {
        case .notEnabled(let message): return message
        case .fixtureFailed(let message): return "herdr fixture failed: \(message)"
        case .timedOut(let message): return "timed out waiting for \(message)"
        }
    }
}

struct HerdrLaneEnablement {
    /// nil ⇒ the hermetic loopback fixture (its own sshd, its own keys).
    /// A value aims the same lane at a real second host the caller has
    /// already configured.
    let destination: String?

    static let enableEnvironmentKey = "HERDR_INTEGRATION_TEST_ENABLE"
    static let destinationEnvironmentKey = "HERDR_INTEGRATION_TEST_DESTINATION"
    static let markerFileName = ".herdr-integration-enable.json"

    private struct Marker: Decodable {
        let destination: String?
    }

    static func resolve(repoRoot: URL) throws -> HerdrLaneEnablement {
        let environment = ProcessInfo.processInfo.environment
        if environment[enableEnvironmentKey] == "1" {
            let destination = environment[destinationEnvironmentKey]
            return HerdrLaneEnablement(
                destination: destination?.isEmpty == false ? destination : nil
            )
        }
        let markerURL = repoRoot.appendingPathComponent(markerFileName)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            throw HerdrLaneError.notEnabled(
                """
                The live herdr integration lane is not enabled, so it cannot report \
                anything about herdr. Enable it with \(enableEnvironmentKey)=1 \
                (optionally \(destinationEnvironmentKey)=<ssh destination>), or run \
                ./scripts/remote-build.sh integration-herdr [ssh-destination] from the \
                dev box. Every other lane skips this suite by name.
                """
            )
        }
        let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        return HerdrLaneEnablement(
            destination: marker.destination?.isEmpty == false ? marker.destination : nil
        )
    }
}

// MARK: - Process helper

enum HerdrLaneProcess {
    struct Result {
        let status: Int32
        let standardOutput: String
        let standardError: String
        var succeeded: Bool { status == 0 }
    }

    /// Output is collected through FILES, never inherited pipes. The fixture
    /// starts long-lived daemons that inherit whatever descriptors they are
    /// given, so a parent reading a shared pipe to EOF would block until the
    /// fixture itself exits — which is never.
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> Result {
        let base = NSTemporaryDirectory() + "lvx-herdr-lane-" + UUID().uuidString.prefix(8)
        let outPath = base + ".out"
        let errPath = base + ".err"
        FileManager.default.createFile(atPath: outPath, contents: nil)
        FileManager.default.createFile(atPath: errPath, contents: nil)
        defer {
            try? FileManager.default.removeItem(atPath: outPath)
            try? FileManager.default.removeItem(atPath: errPath)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
        process.standardError = try FileHandle(forWritingTo: URL(fileURLWithPath: errPath))
        try process.run()
        process.waitUntilExit()
        if let handle = process.standardOutput as? FileHandle { try? handle.close() }
        if let handle = process.standardError as? FileHandle { try? handle.close() }

        return Result(
            status: process.terminationStatus,
            standardOutput: (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "",
            standardError: (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
        )
    }
}

// MARK: - Surface log

/// One fixture surface: a real herdr client running on a pty, read through
/// the typescript `script(1)` writes for it.
///
/// This stands in for `TerminalScreenAXReader` and nothing else. Reads are
/// always SINCE A MARK, because a typescript is append-only: a token stamped
/// three assertions ago stays in the file forever, and searching the whole
/// file would let a stale frame answer a question about the current one.
final class HerdrSurfaceLog: @unchecked Sendable {
    let path: String
    private let mark = Mutex<UInt64>(0)

    init(path: String) {
        self.path = path
    }

    var byteCount: UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Everything painted from here on is what the next read may see.
    func markCurrentEnd() {
        let end = byteCount
        mark.withLock { $0 = end }
    }

    /// Rendered text painted since the mark, with escape sequences removed.
    func textSinceMark() -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: mark.withLock { $0 })
        } catch {
            return nil
        }
        let data = handle.readDataToEndOfFile()
        // isoLatin1 never fails: a typescript is raw bytes, and a UTF-8
        // sequence split across a flush boundary must not blank a whole read.
        let raw = String(data: data, encoding: .isoLatin1) ?? ""
        return Self.visibleText(raw)
    }

    /// Strip CSI/OSC escapes and control bytes so a rendered cell run reads as
    /// the string herdr painted.
    static func visibleText(_ raw: String) -> String {
        var output = String.UnicodeScalarView()
        let scalars = Array(raw.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\u{1B}" else {
                if scalar.value >= 32 || scalar == "\n" {
                    output.append(scalar)
                }
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { break }
            switch scalars[index] {
            case "[":
                index += 1
                // A CSI sequence ends at its first final byte (0x40..0x7E).
                while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) {
                    index += 1
                }
                index += 1
            case "]":
                // OSC runs to BEL or ST.
                while index < scalars.count,
                      scalars[index] != "\u{07}",
                      scalars[index] != "\u{1B}" {
                    index += 1
                }
                index += 1
            default:
                index += 1
            }
        }
        return String(output)
    }
}

// MARK: - Fixture

enum HerdrSurfaceMode: String {
    /// A whole-view herdr client: the App-mode client that renders the
    /// agents sidebar.
    case app
    /// `herdr terminal attach <pane>`: the raw pane stream, no sidebar. The
    /// discriminator the panel-binding trust argument rests on.
    case attach
}

/// A live herdr server, a real pane, a real loopback sshd, and one or more
/// real herdr clients on ptys — brought up by
/// `scripts/herdr-integration-fixture.sh` and torn down deterministically.
@MainActor
final class HerdrLiveFixture {
    struct Info: Decodable {
        let agentSessionID: String
        let alias: String
        /// Same `(hostname, port)` as `alias`, a different `User`.
        let altUserAlias: String
        /// Same hostname as `alias`, a different port.
        let otherPortAlias: String
        let herdrBinary: String
        let socketPath: String
        let paneID: String
        let primarySurfaceLog: String
        let provisionedSSH: Bool
        let workdir: String
    }

    let info: Info
    let primarySurface: HerdrSurfaceLog
    private let scriptURL: URL
    private let repoRoot: URL
    private var isTornDown = false

    private init(info: Info, scriptURL: URL, repoRoot: URL) {
        self.info = info
        self.scriptURL = scriptURL
        self.repoRoot = repoRoot
        self.primarySurface = HerdrSurfaceLog(path: info.primarySurfaceLog)
    }

    static func bringUp(
        repoRoot: URL,
        destination: String?,
        label: String
    ) throws -> HerdrLiveFixture {
        let scriptURL = repoRoot.appendingPathComponent("scripts/herdr-integration-fixture.sh")
        let workdir = "/tmp/lvx-herdr-fixture-\(label)-\(ProcessInfo.processInfo.processIdentifier)"

        // A previous run that died before its teardown would otherwise make
        // every later run fail on "workdir already exists".
        _ = try? HerdrLaneProcess.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL.path, "down", workdir],
            currentDirectory: repoRoot
        )

        var arguments = [scriptURL.path, "up", workdir]
        if let destination { arguments.append(destination) }
        let result = try HerdrLaneProcess.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: arguments,
            currentDirectory: repoRoot
        )
        guard result.succeeded else {
            throw HerdrLaneError.fixtureFailed(
                "`up` exited \(result.status)\n\(result.standardError)\(result.standardOutput)"
            )
        }
        guard let line = result.standardOutput
            .split(separator: "\n")
            .last(where: { $0.hasPrefix("{") }),
            let info = try? JSONDecoder().decode(Info.self, from: Data(line.utf8))
        else {
            throw HerdrLaneError.fixtureFailed(
                "`up` printed no fixture description\n\(result.standardOutput)\(result.standardError)"
            )
        }
        return HerdrLiveFixture(info: info, scriptURL: scriptURL, repoRoot: repoRoot)
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        _ = try? HerdrLaneProcess.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL.path, "down", info.workdir],
            currentDirectory: repoRoot
        )
    }

    /// Start an additional real herdr client on its own pty.
    @discardableResult
    func startSurface(
        name: String,
        mode: HerdrSurfaceMode,
        paneID: String? = nil
    ) throws -> HerdrSurfaceLog {
        var arguments = [scriptURL.path, "surface", info.workdir, name, mode.rawValue]
        if let paneID { arguments.append(paneID) }
        let result = try HerdrLaneProcess.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: arguments,
            currentDirectory: repoRoot
        )
        guard result.succeeded else {
            throw HerdrLaneError.fixtureFailed(
                "`surface \(name)` exited \(result.status)\n\(result.standardError)"
            )
        }
        return HerdrSurfaceLog(path: "\(info.workdir)/surface-\(name).log")
    }

    /// herdr's own CLI against the fixture's socket. Used only to READ herdr's
    /// state (what it stored, what it thinks a pane is) and to set fixture
    /// preconditions — never as a stand-in for the app's client.
    @discardableResult
    func herdrCLI(_ arguments: [String]) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["HERDR_SOCKET_PATH"] = info.socketPath
        let result = try HerdrLaneProcess.run(
            executable: URL(fileURLWithPath: info.herdrBinary),
            arguments: arguments,
            currentDirectory: repoRoot,
            environment: environment
        )
        return result.standardOutput + result.standardError
    }

    /// The custom metadata tokens herdr currently holds for the fixture pane.
    /// An absent `tokens` key is an empty map — that is how herdr represents
    /// "cleared", and the distinction matters to the clear-semantics test.
    func paneTokens() throws -> [String: String] {
        let output = try herdrCLI(["pane", "get", info.paneID])
        guard let data = output.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let pane = result["pane"] as? [String: Any]
        else {
            throw HerdrLaneError.fixtureFailed("could not read pane state: \(output)")
        }
        return (pane["tokens"] as? [String: String]) ?? [:]
    }

    var herdrConfigPath: String {
        NSHomeDirectory() + "/.config/herdr/config.toml"
    }

    /// Ask the live server to re-read the config file. Used to put the fixture
    /// back the way it was after a test rewrote the account's config.
    func reloadConfig() throws {
        _ = try HerdrLaneProcess.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL.path, "reload", info.workdir],
            currentDirectory: repoRoot
        )
    }
}

// MARK: - Live readiness

enum HerdrLaneWait {
    /// Wait for a condition about a LIVE external process.
    ///
    /// The assertion is always the condition; the deadline is only a bound on
    /// how long a dead fixture is allowed to look alive. `Task.sleep` (not a
    /// blocking sleep) so the main actor stays free for the app code under
    /// test — the forward service and the mic indicator both hop back onto it.
    @MainActor
    static func until(
        _ what: String,
        timeout: TimeInterval = 20,
        poll: TimeInterval = 0.1,
        _ condition: () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if try condition() { return }
            guard Date() < deadline else { throw HerdrLaneError.timedOut(what) }
            try? await Task.sleep(for: .milliseconds(Int(poll * 1000)))
        }
    }
}

#endif
