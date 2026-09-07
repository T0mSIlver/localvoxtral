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
