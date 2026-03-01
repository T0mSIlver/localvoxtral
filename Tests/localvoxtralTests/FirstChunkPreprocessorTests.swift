import XCTest
@testable import localvoxtral

final class FirstChunkPreprocessorTests: XCTestCase {
    func testPreprocess_firstNonEmptyChunkTrimsLeadingWhitespaceOnly() {
        var preprocessor = FirstChunkPreprocessor()

        let first = preprocessor.preprocess("   hello  ")
        let second = preprocessor.preprocess(" world")

        XCTAssertEqual(first, "hello  ")
        XCTAssertEqual(second, " world")
        XCTAssertFalse(preprocessor.isFirstChunkPending)
    }

    func testPreprocess_emptyChunkDoesNotConsumeFirstChunk() {
        var preprocessor = FirstChunkPreprocessor()

        let empty = preprocessor.preprocess("")
        let next = preprocessor.preprocess("  hi")

        XCTAssertEqual(empty, "")
        XCTAssertEqual(next, "hi")
        XCTAssertFalse(preprocessor.isFirstChunkPending)
    }

    func testPreprocess_whitespaceOnlyFirstChunkIsConsumed() {
        var preprocessor = FirstChunkPreprocessor()

        let first = preprocessor.preprocess(" \n\t ")
        let second = preprocessor.preprocess(" keep-leading-space")

        XCTAssertEqual(first, "")
        XCTAssertEqual(second, " keep-leading-space")
        XCTAssertFalse(preprocessor.isFirstChunkPending)
    }

    func testPreprocess_resetEnablesFirstChunkTrimmingAgain() {
        var preprocessor = FirstChunkPreprocessor()
        _ = preprocessor.preprocess("  one")
        preprocessor.reset()

        let afterReset = preprocessor.preprocess("  two")

        XCTAssertEqual(afterReset, "two")
    }
}
