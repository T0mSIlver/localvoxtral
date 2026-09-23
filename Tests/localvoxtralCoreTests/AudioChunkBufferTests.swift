import Foundation
import XCTest
@testable import localvoxtral

final class AudioChunkBufferTests: XCTestCase {

    // MARK: - Functional

    func testAppendAndTakeAll_singleChunk() {
        let buffer = AudioChunkBuffer()
        let data = Data([0x01, 0x02, 0x03])
        buffer.append(data)
        let result = buffer.takeAll()
        XCTAssertEqual(result, data)
    }

    func testTakeAll_empty() {
        let buffer = AudioChunkBuffer()
        let result = buffer.takeAll()
        XCTAssertTrue(result.isEmpty)
    }

    func testTakeAll_drains() {
        let buffer = AudioChunkBuffer()
        buffer.append(Data([0x01]))
        _ = buffer.takeAll()
        let second = buffer.takeAll()
        XCTAssertTrue(second.isEmpty)
    }

    func testMultipleAppends_concatenateInOrder() {
        let buffer = AudioChunkBuffer()
        buffer.append(Data([0x01, 0x02]))
        buffer.append(Data([0x03, 0x04]))
        buffer.append(Data([0x05]))
        let result = buffer.takeAll()
        XCTAssertEqual(result, Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    func testAppendEmptyData_isNoOp() {
        let buffer = AudioChunkBuffer()
        buffer.append(Data([0x01]))
        buffer.append(Data())
        let result = buffer.takeAll()
        XCTAssertEqual(result, Data([0x01]))
    }

    func testClear_discards() {
        let buffer = AudioChunkBuffer()
        buffer.append(Data([0x01, 0x02, 0x03]))
        buffer.clear()
        let result = buffer.takeAll()
        XCTAssertTrue(result.isEmpty)
    }

    func testClear_onEmpty_isNoOp() {
        let buffer = AudioChunkBuffer()
        buffer.clear()
        let result = buffer.takeAll()
        XCTAssertTrue(result.isEmpty)
    }

    func testAppendAfterClear_works() {
        let buffer = AudioChunkBuffer()
        buffer.append(Data([0x01]))
        buffer.clear()
        buffer.append(Data([0x02]))
        let result = buffer.takeAll()
        XCTAssertEqual(result, Data([0x02]))
    }

    // MARK: - Concurrency

    func testConcurrentAppends_totalBytesCorrect() async {
        let buffer = AudioChunkBuffer()
        let chunkSize = 10
        let taskCount = 100

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    let byte = UInt8(i % 256)
                    buffer.append(Data(repeating: byte, count: chunkSize))
                }
            }
        }

        let result = buffer.takeAll()
        XCTAssertEqual(result.count, chunkSize * taskCount)
    }
}
