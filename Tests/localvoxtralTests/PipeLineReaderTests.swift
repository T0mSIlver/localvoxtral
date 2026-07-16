import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

// Retained crash coverage for the shared child-process reader after retirement
// of the installer that originally housed it.
final class PipeLineReaderTests: XCTestCase {
    func testReaderFinishesCleanlyWhenDescriptorIsNotReadable() {
        let writeOnly = FileHandle(forWritingAtPath: "/dev/null")!
        defer { try? writeOnly.close() }

        let reader = PipeLineReader(fileHandle: writeOnly) { _ in }
        reader.start()
        reader.waitUntilFinished()
    }

    func testReaderDeliversLinesThenFinishesOnEOF() {
        let pipe = Pipe()
        let lines = Mutex<[String]>([])
        let reader = PipeLineReader(fileHandle: pipe.fileHandleForReading) { line in
            lines.withLock { $0.append(line) }
        }
        reader.start()
        pipe.fileHandleForWriting.write(Data("one\ntwo\ntrailing".utf8))
        pipe.fileHandleForWriting.closeFile()
        reader.waitUntilFinished()

        XCTAssertEqual(lines.withLock { $0 }, ["one", "two", "trailing"])
    }
}
