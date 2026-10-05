import Foundation
import Synchronization
import localvoxtralCore

/// In-memory disk for the record store, mirroring `MemoryStoreIO` in the
/// registry tests: the retention rules and the naming contract are the parts
/// worth asserting, and neither needs a real directory. The hardened write path
/// itself is `ClaudeRemoteHostFileStoreIO`'s, already covered by its own tests.
package final class MemoryCaptureIO: ClaudeRemoteHostStoreIO, DiagnosticRecordDirectoryIO {
    package init() {}

    private let files = Mutex<[String: Data]>([:])

    // ClaudeRemoteHostStoreIO
    package func read(from url: URL) throws -> Data? {
        files.withLock { $0[url.path] }
    }

    package func write(_ data: Data, to url: URL) throws {
        files.withLock { $0[url.path] = data }
    }

    // DiagnosticRecordDirectoryIO
    package func contents(of url: URL) throws -> [String]? {
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return files.withLock { store in
            store.keys
                .filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }
        }
    }

    package func remove(at url: URL) throws {
        files.withLock { $0[url.path] = nil }
    }

    package func size(of url: URL) -> Int? {
        files.withLock { $0[url.path]?.count }
    }

    package func seed(_ data: Data, at url: URL) {
        files.withLock { $0[url.path] = data }
    }

    package var fileNames: [String] {
        files.withLock { Array($0.keys.map { URL(fileURLWithPath: $0).lastPathComponent }) }
    }
}

package final class CaptureTestClock: Sendable {
    package init() {}

    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    package func now() -> Date { value.withLock { $0 } }
    package func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    package func set(_ date: Date) { value.withLock { $0 = date } }
}

extension DiagnosticRecord {
    /// A terminal dictation's record with no join and no sources: the record
    /// the store suites write.
    package static func storeFixture(
        id: String = UUID().uuidString,
        capturedAt: Date,
        rawTranscript: String = "run the tests",
        screenText: String? = nil
    ) -> DiagnosticRecord {
        DiagnosticRecord(
            id: id,
            capturedAt: capturedAt,
            session: .init(
                targetBundleID: "com.mitchellh.ghostty",
                targetKind: "terminal",
                outputMode: "overlayBuffer",
                promptProfile: "agent",
                endpointClass: "loopback",
                polishModel: "qwen35-4b"
            ),
            join: nil,
            screen: screenText.map {
                DiagnosticRecord.Screen(
                    route: "herdrPaneRead",
                    decision: "render",
                    cause: nil,
                    sanitizedCharacterCount: $0.count,
                    sanitizedText: $0
                )
            },
            allocation: [],
            sources: [],
            text: .init(
                rawTranscript: rawTranscript,
                workingText: rawTranscript,
                groundedText: rawTranscript,
                systemPrompt: nil,
                userPrompts: [],
                polishedOutput: nil,
                committedText: nil
            ),
            timings: .init()
        )
    }
}
