import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Live file systems for the Integrations pane's two installers, with the
/// same discipline as the ssh-config and shell-rc writers
/// (`ClaudeRemoteEnrollmentLiveIO.swift`): `lstat` so a symlink is seen as
/// one, `O_NOFOLLOW` on the temp file, an atomic rename, symlink refusal on
/// every path component from home, and "unreadable" reported distinctly from
/// "absent" so a confirmed install can never blank a file it could not read.
///
/// The two structs stay separate despite their shape: `~/.claude` and
/// `~/.config/opencode` have different owners of trust (Claude Code's own
/// settings vs a third harness's config), and merging them would let one
/// path's rules apply where they do not belong — the same reason the
/// ssh-config and rc writers were never merged.
enum ClaudeIntegrationLiveIO {
    /// Temp-write + rename into the destination directory, so the rename is
    /// same-filesystem and atomic. Mirrors the two existing writers syscall
    /// for syscall (`O_EXCL | O_NOFOLLOW`, `fchmod`, full write with EINTR
    /// retry, `fsync`, `rename`, unlink-on-failure).
    static func atomicWrite(_ data: Data, to destinationURL: URL, permissions: UInt16) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".localvoxtral-install.\(UUID().uuidString)", isDirectory: false
        )
        struct POSIXFailure: Error, CustomStringConvertible {
            var operation: String
            var code: Int32
            var description: String { "\(operation) failed with errno \(code)" }
        }
        #if canImport(Darwin)
        let descriptor = temporaryURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw POSIXFailure(operation: "open", code: errno) }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed { _ = temporaryURL.path.withCString { unlink($0) } }
        }
        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw POSIXFailure(operation: "fchmod", code: errno)
        }
        try data.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    descriptor, baseAddress.advanced(by: offset), raw.count - offset
                )
                if written == -1, errno == EINTR { continue }
                guard written > 0 else {
                    throw POSIXFailure(operation: "write", code: errno)
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXFailure(operation: "fsync", code: errno) }
        let moved = temporaryURL.path.withCString { source in
            destinationURL.path.withCString { destination in rename(source, destination) }
        }
        guard moved == 0 else { throw POSIXFailure(operation: "rename", code: errno) }
        renamed = true
        #else
        try data.write(to: temporaryURL, options: .atomic)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        #endif
    }

    /// Read-or-absent for a leaf file: nil data with `exists == true` means
    /// "exists but could not be read" — the services turn that into a
    /// refusal, never into an empty file.
    static func readLeaf(at url: URL) -> (exists: Bool, isSymlink: Bool, data: Data?, permissions: UInt16?) {
        let metadata = ClaudeSocketGuard.metadata(ofPath: url.path)
        guard let metadata else { return (false, false, nil, nil) }
        guard !metadata.isSymlink else { return (true, true, nil, nil) }
        // NOT `try!` and not defaulted: an unreadable file must reach the
        // writer as "unreadable", never as empty (rc writer finding M2).
        let data = try? Data(contentsOf: url)
        var permissions: UInt16?
        if data != nil,
           let number = try? FileManager.default
               .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber {
            permissions = number.uint16Value
        }
        return (true, false, data, permissions)
    }
}

/// `~/.claude/settings.json`, live.
struct LiveClaudeStatuslineFileSystem: ClaudeStatuslineFileSystem {
    static let relativePath = ".claude/settings.json"

    private let homeURL: URL
    private let fileURL: URL
    private let directoryURL: URL

    init(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        homeURL = homeDirectoryURL
        fileURL = homeDirectoryURL.appendingPathComponent(Self.relativePath, isDirectory: false)
        directoryURL = fileURL.deletingLastPathComponent()
    }

    func readState() throws -> ClaudeStatuslineState {
        let leaf = ClaudeIntegrationLiveIO.readLeaf(at: fileURL)
        let intermediateIsSymlink = LiveClaudeShellRCFileSystem.anyComponentIsSymlink(
            under: homeURL, relativePath: Self.relativePath
        )
        return ClaudeStatuslineState(
            fileExists: leaf.exists,
            fileIsSymlink: leaf.isSymlink,
            directoryExists: ClaudeSocketGuard.metadata(ofPath: directoryURL.path)?.isDirectory == true,
            directoryIsSymlink: intermediateIsSymlink,
            // A file behind a symlinked component reads as absent-with-data-nil
            // only when nothing exists; when the leaf itself exists but the
            // path is untrusted, report it as existing-but-unreadable so the
            // writer refuses on the symlink gate rather than treating it as
            // a fresh install.
            data: intermediateIsSymlink ? nil : leaf.data,
            permissions: intermediateIsSymlink ? nil : leaf.permissions
        )
    }

    func createDirectory(permissions: UInt16) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: permissions)]
        )
    }

    func atomicWrite(_ data: Data, permissions: UInt16) throws {
        try ClaudeIntegrationLiveIO.atomicWrite(data, to: fileURL, permissions: permissions)
    }

    func deleteFile() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

/// `~/.config/opencode/plugins/localvoxtral.js` + `~/.config/opencode/tui.json`, live.
struct LiveOpencodePluginFileSystem: OpencodePluginFileSystem {
    static let pluginsRelativePath = ".config/opencode/plugins/\(ClaudePluginAssets.opencodePluginFileName)"
    static let tuiRelativePath = ".config/opencode/tui.json"
    static let pluginsDirectoryRelativePath = ".config/opencode/plugins"
    static let configDirectoryRelativePath = ".config/opencode"

    private let homeURL: URL
    private let pluginURL: URL
    private let pluginsDirectoryURL: URL
    private let tuiURL: URL
    private let configDirectoryURL: URL

    init(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        homeURL = homeDirectoryURL
        pluginURL = homeDirectoryURL.appendingPathComponent(Self.pluginsRelativePath, isDirectory: false)
        pluginsDirectoryURL = homeDirectoryURL.appendingPathComponent(
            Self.pluginsDirectoryRelativePath, isDirectory: true
        )
        tuiURL = homeDirectoryURL.appendingPathComponent(Self.tuiRelativePath, isDirectory: false)
        configDirectoryURL = homeDirectoryURL.appendingPathComponent(
            Self.configDirectoryRelativePath, isDirectory: true
        )
    }

    func readState() throws -> OpencodePluginState {
        let pluginIntermediateIsSymlink = LiveClaudeShellRCFileSystem.anyComponentIsSymlink(
            under: homeURL, relativePath: Self.pluginsRelativePath
        )
        let tuiIntermediateIsSymlink = LiveClaudeShellRCFileSystem.anyComponentIsSymlink(
            under: homeURL, relativePath: Self.tuiRelativePath
        )
        let pluginLeaf = ClaudeIntegrationLiveIO.readLeaf(at: pluginURL)
        let tuiLeaf = ClaudeIntegrationLiveIO.readLeaf(at: tuiURL)
        return OpencodePluginState(
            pluginFileExists: pluginLeaf.exists,
            pluginFileIsSymlink: pluginLeaf.isSymlink,
            pluginData: pluginIntermediateIsSymlink ? nil : pluginLeaf.data,
            pluginPermissions: pluginIntermediateIsSymlink ? nil : pluginLeaf.permissions,
            pluginsDirExists: ClaudeSocketGuard.metadata(ofPath: pluginsDirectoryURL.path)?.isDirectory == true,
            pluginsDirIsSymlink: pluginIntermediateIsSymlink,
            tuiFileExists: tuiLeaf.exists,
            tuiFileIsSymlink: tuiLeaf.isSymlink,
            tuiData: tuiIntermediateIsSymlink ? nil : tuiLeaf.data,
            tuiPermissions: tuiIntermediateIsSymlink ? nil : tuiLeaf.permissions,
            configDirExists: ClaudeSocketGuard.metadata(ofPath: configDirectoryURL.path)?.isDirectory == true,
            configDirIsSymlink: tuiIntermediateIsSymlink
        )
    }

    func createPluginsDirectory(permissions: UInt16) throws {
        try FileManager.default.createDirectory(
            at: pluginsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: permissions)]
        )
    }

    func createConfigDirectory(permissions: UInt16) throws {
        try FileManager.default.createDirectory(
            at: configDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: permissions)]
        )
    }

    func atomicWritePlugin(_ data: Data, permissions: UInt16) throws {
        try ClaudeIntegrationLiveIO.atomicWrite(data, to: pluginURL, permissions: permissions)
    }

    func atomicWriteTUI(_ data: Data, permissions: UInt16) throws {
        try ClaudeIntegrationLiveIO.atomicWrite(data, to: tuiURL, permissions: permissions)
    }

    func deletePlugin() throws {
        if FileManager.default.fileExists(atPath: pluginURL.path) {
            try FileManager.default.removeItem(at: pluginURL)
        }
    }

    func deleteTUI() throws {
        if FileManager.default.fileExists(atPath: tuiURL.path) {
            try FileManager.default.removeItem(at: tuiURL)
        }
    }
}

/// Whether a `herdr` binary is reachable on this Mac.
///
/// `~/.local/bin` is probed explicitly alongside PATH: a GUI app's PATH is
/// not the user's shell PATH, and `~/.local/bin` is where the herdr install
/// script puts it without touching a shell rc. Pure over its inputs so the
    /// probe order is testable without depending on the machine's own PATH.
enum ClaudeHerdrAvailability {
    /// - Parameters:
    ///   - environment: process environment (`PATH`, `HOME`).
    ///   - isExecutable: injected so tests pin the ordering without depending
    ///     on whether the build host happens to have herdr installed.
    static func isHerdrBinaryAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Bool {
        for candidate in herdrCandidates(environment: environment) where isExecutable(candidate) {
            return true
        }
        return false
    }

    static func herdrCandidates(environment: [String: String]) -> [String] {
        var candidates: [String] = []
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") where !directory.isEmpty {
                candidates.append("\(directory)/herdr")
            }
        }
        if let home = environment["HOME"], !home.isEmpty {
            candidates.append("\(home)/.local/bin/herdr")
        }
        return candidates
    }
}
