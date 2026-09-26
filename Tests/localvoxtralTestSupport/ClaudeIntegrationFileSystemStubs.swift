import Foundation
import localvoxtralCore

/// Fixture-driven test double for the opencode file system.
package final class StubOpencodeFileSystem: OpencodePluginFileSystem, @unchecked Sendable {
    package var state: OpencodePluginState
    package var writtenPlugin: (data: Data, permissions: UInt16)?
    package var writtenTUI: (data: Data, permissions: UInt16)?
    package var createdPluginsDir = false
    package var createdConfigDir = false
    package var deletedPlugin = false
    package var deletedTUI = false

    package init(state: OpencodePluginState) { self.state = state }

    package func readState() throws -> OpencodePluginState { state }
    package func createPluginsDirectory(permissions: UInt16) throws { createdPluginsDir = true }
    package func createConfigDirectory(permissions: UInt16) throws { createdConfigDir = true }
    package func atomicWritePlugin(_ data: Data, permissions: UInt16) throws {
        writtenPlugin = (data, permissions)
    }
    package func atomicWriteTUI(_ data: Data, permissions: UInt16) throws {
        writtenTUI = (data, permissions)
    }
    package func deletePlugin() throws { deletedPlugin = true }
    package func deleteTUI() throws { deletedTUI = true }
}

/// Fixture-driven test double for the statusline file system.
package final class StubStatuslineFileSystem: ClaudeStatuslineFileSystem, @unchecked Sendable {
    package var state: ClaudeStatuslineState
    package var written: (data: Data, permissions: UInt16)?
    package var createdDirectory = false
    package var deleted = false

    package init(state: ClaudeStatuslineState) { self.state = state }

    package func readState() throws -> ClaudeStatuslineState { state }
    package func createDirectory(permissions: UInt16) throws { createdDirectory = true }
    package func atomicWrite(_ data: Data, permissions: UInt16) throws {
        written = (data, permissions)
    }
    package func deleteFile() throws { deleted = true }
}
