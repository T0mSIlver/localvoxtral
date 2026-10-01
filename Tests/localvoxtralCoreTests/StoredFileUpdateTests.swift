import Foundation
import XCTest

@testable import localvoxtralCore

/// `StoredFile.update`, the write every store shares with other running
/// copies of the app (#990).
final class StoredFileUpdateTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stored-file-update-\(UUID().uuidString)")
            .appendingPathComponent("words.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private struct DiskFull: Error {}

    private func update(
        _ memory: inout [String], seen: inout StoredFileSeen, writeFails: Bool = false, adding word: String
    ) {
        let result = StoredFile.update(
            fileURL, memory: memory, seen: &seen,
            decode: { data in (try? JSONDecoder().decode([String].self, from: data)).map { .loaded($0) } ?? .refused(.unreadable) },
            encode: { try JSONEncoder().encode($0) },
            write: { data, url in
                if writeFails { throw DiskFull() }
                try data.write(to: url, options: .atomic)
            },
            change: { $0.append(word) })
        switch result {
        case .written(let value), .failed(let value, _): memory = value
        case .refused(let problem): XCTFail("refused: \(problem)")
        }
    }

    /// Another copy wrote the file, then this copy's write failed (#990
    /// review): the change it applied on top of the other copy's is still
    /// written by the next update.
    func testAChangeWhoseWriteFailedAfterAnotherCopyWroteIsKept() throws {
        var memory: [String] = []
        var seen = StoredFileSeen()
        update(&memory, seen: &seen, adding: "Voxtral")
        try JSONEncoder().encode(["Voxtral", "Mistral"]).write(to: fileURL)

        update(&memory, seen: &seen, writeFails: true, adding: "Tekken")
        XCTAssertEqual(memory, ["Voxtral", "Mistral", "Tekken"])
        update(&memory, seen: &seen, adding: "Ministral")

        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(contentsOf: fileURL)),
            ["Voxtral", "Mistral", "Tekken", "Ministral"])
    }
}
