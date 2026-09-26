import Foundation
import Synchronization
import localvoxtralCore

/// Instructions files in memory, keyed by path relative to home, recording
/// every write and delete the dictation-note service makes.
package final class MemoryDictationNoteFileSystem: DictationNoteFileSystem {
    package struct Storage: Sendable {
        package var files: [String: DictationNoteFile]
        package var createdDirectories: [String] = []
        package var writes: [(path: String, permissions: UInt16)] = []
        package var deletes: [String] = []
        /// Replaces a file's contents after the service's first read of it,
        /// the way an editor saving mid-edit would.
        package var editBetweenReads: (path: String, text: String)?
        var reads = 0
    }

    private let storage: Mutex<Storage>

    package init(files: [String: String] = [:]) {
        storage = Mutex(Storage(files: files.mapValues {
            DictationNoteFile(exists: true, data: Data($0.utf8), permissions: 0o644)
        }))
    }

    package var snapshot: Storage { storage.withLock { $0 } }

    package func text(_ path: String) -> String? {
        storage.withLock { $0.files[path]?.data.flatMap { String(data: $0, encoding: .utf8) } }
    }

    package func set(_ path: String, _ file: DictationNoteFile) {
        storage.withLock { $0.files[path] = file }
    }

    package func editBetweenReads(_ path: String, _ text: String) {
        storage.withLock { $0.editBetweenReads = (path, text) }
    }

    package func readFile(relativePath: String) -> DictationNoteFile {
        storage.withLock { storage in
            let file = storage.files[relativePath] ?? DictationNoteFile()
            if let edit = storage.editBetweenReads, edit.path == relativePath {
                storage.reads += 1
                // The first reads pick the target and compute the edit; the
                // edit lands before the last look.
                if storage.reads == 2 {
                    storage.files[relativePath] = DictationNoteFile(
                        exists: true, data: Data(edit.text.utf8), permissions: 0o644
                    )
                }
            }
            return file
        }
    }

    package func createParentDirectory(of relativePath: String, permissions: UInt16) throws {
        storage.withLock { $0.createdDirectories.append(relativePath) }
    }

    package func atomicWrite(_ data: Data, relativePath: String, permissions: UInt16) throws {
        storage.withLock {
            $0.writes.append((relativePath, permissions))
            $0.files[relativePath] = DictationNoteFile(exists: true, data: data, permissions: permissions)
        }
    }

    package func delete(relativePath: String) throws {
        storage.withLock {
            $0.deletes.append(relativePath)
            $0.files[relativePath] = nil
        }
    }
}
