import Foundation

/// Why a store did not load its file (#989). The file keeps its bytes, the
/// store refuses to write over it, and the UI says so until the user moves
/// it aside (`StoredFile.moveAside`) or a newer build reads it again.
package enum StoredFileProblem: Equatable, Sendable {
    /// There, but it could not be read or decoded.
    case unreadable
    /// Written by a later build, in this format version.
    case newerVersion(Int)
}

/// What loading a store's file found. Only `.absent` lets the store create
/// the file; an empty store is never a stand-in for one it could not read.
package enum StoredFileLoad<Value> {
    case absent
    case loaded(Value)
    case refused(StoredFileProblem)

    package var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    package var problem: StoredFileProblem? {
        if case .refused(let problem) = self { return problem }
        return nil
    }
}

package enum StoredFile {
    private struct VersionProbe: Decodable { var version: Int? }

    /// Reads and decodes a JSON file that carries a top-level `version`,
    /// refusing one newer than `currentVersion` before decoding the rest.
    package static func load<Value: Decodable>(
        _ type: Value.Type,
        from url: URL,
        currentVersion: Int,
        decoder: JSONDecoder = JSONDecoder()
    ) -> StoredFileLoad<Value> {
        let data: Data
        switch read(url) {
        case .absent: return .absent
        case .unreadable: return .refused(.unreadable)
        case .bytes(let bytes): data = bytes
        }
        return decode(type, from: data, name: url.lastPathComponent, currentVersion: currentVersion, decoder: decoder)
    }

    /// `load`'s decoding half, for a caller that already holds the bytes.
    package static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        name: String,
        currentVersion: Int,
        decoder: JSONDecoder = JSONDecoder()
    ) -> StoredFileLoad<Value> {
        if let version = (try? decoder.decode(VersionProbe.self, from: data))?.version, version > currentVersion {
            Log.persistence.error(
                "\(name, privacy: .public): format \(version, privacy: .public) is newer than this build's \(currentVersion, privacy: .public), kept and not written"
            )
            return .refused(.newerVersion(version))
        }
        do {
            return .loaded(try decoder.decode(type, from: data))
        } catch {
            Log.persistence.error(
                "\(name, privacy: .public): could not be decoded, kept and not written: \(String(describing: error), privacy: .public)"
            )
            return .refused(.unreadable)
        }
    }

    package struct MoveAsideFailed: Error, Equatable {
        package init() {}
    }

    /// The user's way out of a refused file: renames it beside itself under a
    /// name no file has (`<name>.unreadable-<id>`), and returns that name
    /// only once the moved file has the same size and the original is gone.
    /// A rename that would replace a file fails instead.
    package static func moveAside(_ url: URL, id: String = UUID().uuidString) throws -> URL {
        let fileManager = FileManager.default
        let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? Int
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).unreadable-\(id)")
        guard !fileManager.fileExists(atPath: destination.path) else { throw MoveAsideFailed() }
        // link(2) refuses an existing name, so nothing is ever replaced; then
        // the original goes.
        guard link(url.path, destination.path) == 0 else { throw MoveAsideFailed() }
        let movedSize = try fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int
        guard movedSize == size else { throw MoveAsideFailed() }
        try fileManager.removeItem(at: url)
        guard !fileManager.fileExists(atPath: url.path) else { throw MoveAsideFailed() }
        Log.persistence.notice(
            "\(url.lastPathComponent, privacy: .public): moved aside as \(destination.lastPathComponent, privacy: .public)"
        )
        return destination
    }
}
