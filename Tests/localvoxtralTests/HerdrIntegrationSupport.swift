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
        text(fromOffset: mark.withLock { $0 })
    }

    /// The complete visible paint stream. Diagnostics use this only after
    /// copying the raw typescript, so an ANSI parser can reconstruct the last
    /// frame without losing evidence.
    func fullVisibleText() -> String? {
        text(fromOffset: 0)
    }

    /// Reconstruct the last fixed-size terminal frame from the typescript.
    /// Herdr redraws with absolute CSI cursor positions, so this small parser
    /// needs only the cursor and erase operations emitted by its renderer.
    func lastRenderedFrame(rows: Int = 45, columns: Int = 130) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        return TerminalDiagnosticFrame(raw: raw, rows: rows, columns: columns).text
    }

    func observedSidebarWidth(rows: Int = 45, columns: Int = 130) -> Int? {
        guard let data = FileManager.default.contents(atPath: path),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }
        return TerminalDiagnosticFrame(raw: raw, rows: rows, columns: columns).sidebarWidth
    }

    private func text(fromOffset offset: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
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

private struct TerminalDiagnosticFrame {
    private(set) var cells: [[Character]]
    private var row = 0
    private var column = 0
    private var savedRow = 0
    private var savedColumn = 0
    private let rows: Int
    private let columns: Int

    init(raw: String, rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
        self.cells = Array(
            repeating: Array(repeating: " ", count: columns), count: rows
        )
        consume(Array(raw))
    }

    var text: String {
        cells.map { String($0).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    /// The most common rendered vertical divider column, in terminal cells.
    /// The desktop layout paints `│` at column 26, so its sidebar is 26 cells.
    var sidebarWidth: Int? {
        var counts: [Int: Int] = [:]
        for line in cells {
            for (index, cell) in line.enumerated() where cell == "│" {
                counts[index + 1, default: 0] += 1
            }
        }
        return counts.max { lhs, rhs in lhs.value < rhs.value }?.key
    }

    private mutating func consume(_ characters: [Character]) {
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\u{1B}" {
                index += 1
                guard index < characters.count else { break }
                if characters[index] == "[" {
                    index = consumeCSI(characters, from: index + 1)
                } else if characters[index] == "]" {
                    index = consumeOSC(characters, from: index + 1)
                } else if characters[index] == "7" {
                    savedRow = row
                    savedColumn = column
                    index += 1
                } else if characters[index] == "8" {
                    row = savedRow
                    column = savedColumn
                    index += 1
                } else {
                    index += 1
                }
                continue
            }
            switch character {
            case "\r": column = 0
            case "\n": row = min(row + 1, rows - 1)
            case "\u{08}": column = max(column - 1, 0)
            case "\t": column = min(((column / 8) + 1) * 8, columns - 1)
            default:
                if character.unicodeScalars.allSatisfy({ $0.value >= 32 }) {
                    if row >= 0, row < rows, column >= 0, column < columns {
                        cells[row][column] = character
                    }
                    column = min(column + 1, columns)
                }
            }
            index += 1
        }
    }

    private mutating func consumeCSI(_ characters: [Character], from start: Int) -> Int {
        var index = start
        var body = ""
        while index < characters.count {
            guard let scalar = characters[index].unicodeScalars.first else {
                index += 1
                continue
            }
            if (0x40...0x7E).contains(scalar.value) {
                applyCSI(final: characters[index], body: body)
                return index + 1
            }
            body.append(characters[index])
            index += 1
        }
        return index
    }

    private mutating func consumeOSC(_ characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count {
            if characters[index] == "\u{07}" { return index + 1 }
            if characters[index] == "\u{1B}",
               index + 1 < characters.count,
               characters[index + 1] == "\\"
            {
                return index + 2
            }
            index += 1
        }
        return index
    }

    private mutating func applyCSI(final: Character, body: String) {
        let values = body
            .trimmingCharacters(in: CharacterSet(charactersIn: "?<>"))
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        let first = max(values.first ?? 1, 1)
        switch final {
        case "H", "f":
            row = min(max((values.first ?? 1) - 1, 0), rows - 1)
            column = min(max((values.dropFirst().first ?? 1) - 1, 0), columns - 1)
        case "A": row = max(row - first, 0)
        case "B": row = min(row + first, rows - 1)
        case "C": column = min(column + first, columns - 1)
        case "D": column = max(column - first, 0)
        case "G": column = min(first - 1, columns - 1)
        case "d": row = min(first - 1, rows - 1)
        case "J" where values.first == 2 || values.first == 3:
            cells = Array(repeating: Array(repeating: " ", count: columns), count: rows)
        case "K":
            let mode = values.first ?? 0
            if mode == 0 {
                for cell in column..<columns { cells[row][cell] = " " }
            } else if mode == 1 {
                for cell in 0...min(column, columns - 1) { cells[row][cell] = " " }
            } else if mode == 2 {
                cells[row] = Array(repeating: " ", count: columns)
            }
        case "s":
            savedRow = row
            savedColumn = column
        case "u":
            row = savedRow
            column = savedColumn
        default: break
        }
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
    /// `herdr terminal session observe <pane>`: newline-delimited
    /// `terminal.frame` records of the raw pane stream, likewise no sidebar.
    /// Pinned next to the attach case since herdr 0.9 federates the agents
    /// panel across machines.
    case observe
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
    private let diagnosticsRoot: URL
    private var surfaces: [String: HerdrSurfaceLog]
    private var isTornDown = false

    private init(info: Info, scriptURL: URL, repoRoot: URL, diagnosticsRoot: URL) {
        self.info = info
        self.scriptURL = scriptURL
        self.repoRoot = repoRoot
        self.diagnosticsRoot = diagnosticsRoot
        let primarySurface = HerdrSurfaceLog(path: info.primarySurfaceLog)
        self.primarySurface = primarySurface
        self.surfaces = ["primary": primarySurface]
    }

    static func bringUp(
        repoRoot: URL,
        destination: String?,
        label: String
    ) throws -> HerdrLiveFixture {
        let scriptURL = repoRoot.appendingPathComponent("scripts/herdr-integration-fixture.sh")
        let workdir = "/tmp/lvx-herdr-fixture-\(label)-\(ProcessInfo.processInfo.processIdentifier)"
        let configuredDiagnostics = ProcessInfo.processInfo.environment[
            "HERDR_INTEGRATION_DIAGNOSTICS_DIR"
        ]
        let diagnosticsRoot = configuredDiagnostics.map(URL.init(fileURLWithPath:))
            ?? repoRoot.appendingPathComponent(".build/herdr-lane-diagnostics")

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
        if !result.standardError.isEmpty {
            print(result.standardError, terminator: result.standardError.hasSuffix("\n") ? "" : "\n")
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
        return HerdrLiveFixture(
            info: info,
            scriptURL: scriptURL,
            repoRoot: repoRoot,
            diagnosticsRoot: diagnosticsRoot
        )
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        captureDiagnostics()
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
        if !result.standardError.isEmpty {
            print(result.standardError, terminator: result.standardError.hasSuffix("\n") ? "" : "\n")
        }
        let surface = HerdrSurfaceLog(path: "\(info.workdir)/surface-\(name).log")
        surfaces[name] = surface
        return surface
    }

    /// Preserve the evidence before the fixture removes its temporary tree.
    /// This runs for green tests too, which makes runner and SSH-account runs
    /// directly comparable instead of leaving diagnostics only for failures.
    private func captureDiagnostics() {
        let fileManager = FileManager.default
        let runName = URL(fileURLWithPath: info.workdir).lastPathComponent
        let destination = diagnosticsRoot.appendingPathComponent(runName, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: diagnosticsRoot, withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: info.workdir, isDirectory: true)
            for item in try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                guard try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                else { continue }
                let safeNames: Set<String> = [
                    "environment.txt", "fixture.json", "herdr.bin", "pane-lifecycle.log",
                    "report-agent.err", "report-agent.out", "server.log", "sshd.log",
                    "sshd.out", "sshd.port",
                ]
                let isSurfaceEvidence = item.lastPathComponent.hasPrefix("surface-")
                    && (item.pathExtension == "log" || item.pathExtension == "geometry")
                guard safeNames.contains(item.lastPathComponent) || isSurfaceEvidence else {
                    continue
                }
                try fileManager.copyItem(
                    at: item,
                    to: destination.appendingPathComponent(item.lastPathComponent)
                )
            }
            for (name, surface) in surfaces {
                let visible = surface.fullVisibleText() ?? "<surface log unavailable>"
                try visible.write(
                    to: destination.appendingPathComponent("surface-\(name).visible.txt"),
                    atomically: true,
                    encoding: .utf8
                )
                let frame = surface.lastRenderedFrame() ?? "<frame unavailable>"
                try frame.write(
                    to: destination.appendingPathComponent("surface-\(name).last-frame.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            print("[herdr-fixture] diagnostics: \(destination.path)")
        } catch {
            print("[herdr-fixture] WARNING: could not preserve diagnostics: \(error)")
        }
    }

    func dumpSurfaceFrames(reason: String) {
        print("[herdr-fixture] SURFACE DUMP: \(reason)")
        for name in surfaces.keys.sorted() {
            let surface = surfaces[name]!
            let width = surface.observedSidebarWidth().map(String.init) ?? "not-rendered"
            print("[herdr-fixture] surface=\(name) observed_sidebar_width=\(width)")
            print(surface.lastRenderedFrame() ?? "<frame unavailable>")
        }
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

    // MARK: - Federation (herdr 0.9)

    /// Set up the federated 0.9 client: `herdr machine add` of the fixture's
    /// own loopback target (or the caller's destination), one agent-bearing
    /// pane on the remote server, and the selection left on Local.
    /// On a host whose herdr predates `machine` the fixture verb refuses with
    /// the required version — that loud failure is what the federation tests
    /// assert there, not a skip.
    @discardableResult
    func federate() throws -> HerdrFederationInfo {
        let result = try HerdrLaneProcess.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL.path, "federation", info.workdir],
            currentDirectory: repoRoot
        )
        guard result.succeeded else {
            throw HerdrLaneError.fixtureFailed(
                "`federation` exited \(result.status)\n\(result.standardError)\(result.standardOutput)"
            )
        }
        if !result.standardError.isEmpty {
            print(result.standardError, terminator: result.standardError.hasSuffix("\n") ? "" : "\n")
        }
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: info.workdir).appendingPathComponent("federation.json")
        ),
            let federation = try? JSONDecoder().decode(HerdrFederationInfo.self, from: data)
        else {
            throw HerdrLaneError.fixtureFailed(
                "`federation` printed no federation description\n\(result.standardOutput)\(result.standardError)"
            )
        }
        return federation
    }

    /// Write the scratch client's endpoint selection before a whole-view
    /// surface starts: a running client keeps its own selection while a
    /// starting one honors this file. This is the file write a real sidebar
    /// switch produces, called out as such — the lane does not drive the
    /// switch through the pty.
    func setFederationSelection(profileID: String?) throws {
        let result = try HerdrLaneProcess.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL.path, "federation-select", info.workdir, profileID ?? "local"],
            currentDirectory: repoRoot
        )
        guard result.succeeded else {
            throw HerdrLaneError.fixtureFailed(
                "`federation-select` exited \(result.status)\n\(result.standardError)"
            )
        }
    }

    /// `herdr machine list --json` against the scratch client state, with the
    /// runner's own herdr session variables scrubbed (a runner living inside
    /// a herdr pane would otherwise leak its pane id into the call).
    func federationMachineList(clientStateHome: String) throws -> [HerdrFederationMachineRow] {
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_STATE_HOME"] = clientStateHome
        for key in ["HERDR_ENV", "HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID", "HERDR_SESSION"] {
            environment.removeValue(forKey: key)
        }
        let result = try HerdrLaneProcess.run(
            executable: URL(fileURLWithPath: info.herdrBinary),
            arguments: ["machine", "list", "--json"],
            currentDirectory: repoRoot,
            environment: environment
        )
        guard result.succeeded,
            let data = result.standardOutput.data(using: .utf8),
            let rows = try? JSONDecoder().decode([HerdrFederationMachineRow].self, from: data)
        else {
            throw HerdrLaneError.fixtureFailed(
                "`machine list --json` failed (\(result.status))\n\(result.standardError)\(result.standardOutput)"
            )
        }
        return rows
    }
}

/// One `herdr machine list --json` row: the fields the catalog holds (no
/// credentials, no key material — herdr stores none).
struct HerdrFederationMachineRow: Decodable {
    let id: String
    let label: String
    let target: String
    let session: String
    let enabled: Bool
    let selected: Bool
}

/// The federated half of a fixture run, written by the fixture's
/// `federation` verb. `remoteSocketPath` and `remoteConfigPath` are empty
/// when the lane runs against a real second host, whose files this Mac
/// cannot read directly.
struct HerdrFederationInfo: Decodable {
    let profileID: String
    let label: String
    let target: String
    let session: String
    let remoteAgentSessionID: String
    let clientStateHome: String
    let clientDir: String
    let remoteSocketPath: String
    let remotePaneID: String
    let remoteConfigPath: String
}

// MARK: - Observe-frame decoding

/// One `herdr terminal session observe` surface: newline-delimited
/// `terminal.frame` JSON records whose `bytes` are base64 terminal output.
/// Unlike a whole-view typescript this needs decoding before the lane can
/// read it — and it is the shape that proves an observer renders no panel.
enum HerdrObserveFrame {
    private struct Record: Decodable {
        let type: String
        let bytes: String
    }

    /// The text bytes of every frame record painted since the mark, in
    /// order, with every escape sequence removed and nothing else interpreted.
    ///
    /// The observer is a JSONL stream of DIFF frames, not a screen: a frame
    /// repaints only the cells that changed, positioned by cursor moves, and
    /// the shell echoes typed text in chunks. Reconstructing a screen from
    /// that (`visibleTexts`) is the wrong instrument for "did this text reach
    /// the observer" — measured on the Mac 2026-09-13: the frame carrying the
    /// post-stamp sentinel reconstructed to its last ten characters only. A
    /// sentinel is contiguous ASCII in the byte stream, so stripping the
    /// escapes and concatenating frames is exact, and a token that is absent
    /// from the raw bytes is absent from the observer full stop.
    static func plainTexts(sinceMark surface: HerdrSurfaceLog) -> [String] {
        frameBytes(sinceMark: surface).map { bytes in
            String(decoding: Self.strippingEscapes(bytes), as: UTF8.self)
        }
    }

    /// CSI (`ESC [ … final`), OSC (`ESC ] … BEL` or `ESC ] … ESC \`), and
    /// any other `ESC x` pair are removed; everything else passes through.
    static func strippingEscapes(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x1B else {
                out.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            switch bytes[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) { index += 1 }
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x07 { index += 1; break }
                    if bytes[index] == 0x1B, index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\\") {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        return out
    }

    /// Raw frame bytes since the mark, one entry per `terminal.frame` record.
    static func frameBytes(sinceMark surface: HerdrSurfaceLog) -> [[UInt8]] {
        records(sinceMark: surface).compactMap { record in
            Data(base64Encoded: record.bytes, options: .ignoreUnknownCharacters).map(Array.init)
        }
    }

    /// Visible text of every frame record painted since the mark, in order.
    /// Empty when the observer has not painted yet, which lets the lane wait
    /// for a connected observer instead of asserting about a silent surface.
    ///
    /// Records are recovered by brace matching, not line splitting: the pty
    /// layer may split one JSON record across flushes, and a line-based
    /// decoder would drop both halves. A truncated tail record is skipped
    /// until the rest of it arrives.
    static func visibleTexts(sinceMark surface: HerdrSurfaceLog) -> [String] {
        records(sinceMark: surface).compactMap { record in
            guard let bytes = Data(base64Encoded: record.bytes, options: .ignoreUnknownCharacters),
                  let raw = String(data: bytes, encoding: .utf8)
            else { return nil }
            return HerdrSurfaceLog.visibleText(raw)
        }
    }

    /// Every complete `terminal.frame` record since the mark, brace-matched.
    private static func records(sinceMark surface: HerdrSurfaceLog) -> [Record] {
        guard let text = surface.textSinceMark() else { return [] }
        var frames: [Record] = []
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escaped = false
            var cursor = open
            var end: String.Index?
            while cursor < text.endIndex {
                let ch = text[cursor]
                if inString {
                    if escaped {
                        escaped = false
                    } else if ch == "\\" {
                        escaped = true
                    } else if ch == "\"" {
                        inString = false
                    }
                } else if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        end = text.index(after: cursor)
                        break
                    }
                }
                cursor = text.index(after: cursor)
            }
            guard let end else { break }
            let candidate = String(text[open..<end])
            if let data = candidate.data(using: .utf8),
                let record = try? JSONDecoder().decode(Record.self, from: data),
                record.type == "terminal.frame"
            {
                frames.append(record)
            }
            index = end
        }
        return frames
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
