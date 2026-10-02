import Foundation

public struct ClaudeRemoteSSHConfigState: Sendable, Equatable {
    public var directoryExists: Bool
    public var configData: Data?
    public var configPermissions: UInt16?
    /// lstat-derived trust facts. The live filesystem fills them so the pure
    /// service can refuse to write through a path another principal controls;
    /// the defaults describe the trustworthy case so existing fakes stay valid.
    public var directoryIsSymlink: Bool
    public var directoryOwnedByCurrentUser: Bool
    public var directoryPermissions: UInt16?
    public var configIsSymlink: Bool

    public init(
        directoryExists: Bool,
        configData: Data?,
        configPermissions: UInt16?,
        directoryIsSymlink: Bool = false,
        directoryOwnedByCurrentUser: Bool = true,
        directoryPermissions: UInt16? = nil,
        configIsSymlink: Bool = false
    ) {
        self.directoryExists = directoryExists
        self.configData = configData
        self.configPermissions = configPermissions
        self.directoryIsSymlink = directoryIsSymlink
        self.directoryOwnedByCurrentUser = directoryOwnedByCurrentUser
        self.directoryPermissions = directoryPermissions
        self.configIsSymlink = configIsSymlink
    }
}

/// Filesystem seam for the one local file the enrollment flow may edit.
public protocol ClaudeRemoteSSHConfigFileSystem: Sendable {
    func readState() throws -> ClaudeRemoteSSHConfigState
    func createSSHDirectory(permissions: UInt16) throws
    /// Replaces the config with `data` only while it still holds `expected`
    /// (nil: no file), the bytes the caller read. Otherwise it throws
    /// `ClaudeRemoteSSHConfigChangedOnDisk` and writes nothing (#1345).
    func atomicWriteConfig(_ data: Data, permissions: UInt16, replacing expected: Data?) throws
    /// Runs `body` excluding the other running copies' read-change-write
    /// sections on the same config.
    func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T
}

extension ClaudeRemoteSSHConfigFileSystem {
    public func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T { try body() }
}

/// The config is no longer the one the caller read: another program saved
/// it in between.
public struct ClaudeRemoteSSHConfigChangedOnDisk: Error, Equatable {
    public init() {}
}
