import Foundation

/// The local herdr config, as the panel-row writer found it.
public struct ClaudeLocalHerdrConfigState: Sendable, Equatable {
    public var directoryExists: Bool
    public var configData: Data?
    public var configPermissions: UInt16?
    public var configIsSymlink: Bool

    public init(
        directoryExists: Bool,
        configData: Data?,
        configPermissions: UInt16?,
        configIsSymlink: Bool = false
    ) {
        self.directoryExists = directoryExists
        self.configData = configData
        self.configPermissions = configPermissions
        self.configIsSymlink = configIsSymlink
    }
}

/// Filesystem seam for the LOCAL herdr config — the file a federated herdr
/// 0.9 client reads its agents-panel rows from. Injected so tests can never
/// reach the real `~/.config/herdr/config.toml`; nil in the service disables
/// the local panel-row offer entirely.
public protocol ClaudeLocalHerdrConfigFileSystem: Sendable {
    func readState() throws -> ClaudeLocalHerdrConfigState
    func createConfigDirectory(permissions: UInt16) throws
    /// - Parameter expectedConfigPresent: what `readState` saw. The
    ///   implementation re-checks the destination immediately before the final
    ///   rename and refuses when it changed (a planted symlink, a swapped
    ///   file, or a file appearing where none was): the check-then-write gap
    ///   is a local-attacker TOCTOU otherwise.
    func atomicWriteConfig(_ data: Data, permissions: UInt16, expectedConfigPresent: Bool) throws
}
