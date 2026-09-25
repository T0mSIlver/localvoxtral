import Foundation
import XCTest

@testable import SpeechEngineText

final class SpeechdLaunchOptionsTests: XCTestCase {
    func testParsesPinnedModelRevisionAndSupervisorArguments() throws {
        let options = try SpeechdOptionParser.parse([
            "--model", "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead",
            "--model-revision", "0123456789abcdef0123456789abcdef01234567",
            "--port", "8471",
            "--parent-pid", "4321",
            "--step-ms", "240",
        ])

        XCTAssertEqual(options.modelID, "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead")
        XCTAssertEqual(options.modelRevision, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(options.port, 8471)
        XCTAssertEqual(options.parentPID, 4321)
        XCTAssertEqual(options.stepMilliseconds, 240)
    }

    func testTermBoostIsOffByDefaultAndParsesThreeBonuses() throws {
        XCTAssertNil(try SpeechdOptionParser.parse(["--model", "example/model"]).termBoost)
        XCTAssertEqual(
            try SpeechdOptionParser.parse(["--model", "example/model", "--term-boost", "1.5,3,4"]).termBoost,
            TermBoostSettings(firstTokenBoost: 1.5, continuationBoost: 3, margin: 4)
        )
        for value in ["1,2", "1,2,3,4", "1,-2,3", "a,b,c", "1,,3", "inf,1,1"] {
            XCTAssertThrowsError(
                try SpeechdOptionParser.parse(["--model", "example/model", "--term-boost", value]), value
            )
        }
    }

    func testBenchVocabularyFileIsABenchmarkOnlyFlag() throws {
        let options = try SpeechdOptionParser.parse([
            "--model", "example/model", "--bench", "--seconds", "10", "--vocabulary-file", "/tmp/terms.txt",
        ])
        XCTAssertEqual(options.benchmark?.vocabularyPath, "/tmp/terms.txt")
        XCTAssertThrowsError(
            try SpeechdOptionParser.parse(["--model", "example/model", "--vocabulary-file", "/tmp/terms.txt"])
        )
    }

    func testStepCadenceDefaultsToModelNativeCadence() throws {
        let options = try SpeechdOptionParser.parse(["--model", "example/model"])

        XCTAssertEqual(options.stepMilliseconds, 100)
    }

    func testStepCadenceAllowsSmallPositiveValues() throws {
        let options = try SpeechdOptionParser.parse([
            "--model", "example/model", "--step-ms", "1",
        ])

        XCTAssertEqual(options.stepMilliseconds, 1)
    }

    func testStepCadenceRejectsNonPositiveAndNonNumericValues() {
        for value in ["0", "-1", "nope"] {
            XCTAssertThrowsError(
                try SpeechdOptionParser.parse([
                    "--model", "example/model", "--step-ms", value,
                ])
            ) { error in
                XCTAssertEqual(error as? SpeechdOptionError, .invalidValue("--step-ms"))
            }
        }
    }

    func testUtteranceLimitDefaultsAndParses() throws {
        XCTAssertEqual(
            try SpeechdOptionParser.parse(["--model", "example/model"]).utteranceLimit,
            UtteranceLimit(seconds: UtteranceLimit.defaultSeconds)
        )
        XCTAssertEqual(
            try SpeechdOptionParser.parse([
                "--model", "example/model", "--max-utterance-seconds", "900",
            ]).utteranceLimit,
            UtteranceLimit(seconds: 900)
        )
    }

    func testUtteranceLimitRejectsNonPositiveAndNonNumericValues() {
        for value in ["0", "-5", "ten"] {
            XCTAssertThrowsError(
                try SpeechdOptionParser.parse([
                    "--model", "example/model", "--max-utterance-seconds", value,
                ])
            ) { error in
                XCTAssertEqual(error as? SpeechdOptionError, .invalidValue("--max-utterance-seconds"))
            }
        }
    }

    func testParsesBenchmarkOptions() throws {
        let options = try SpeechdOptionParser.parse([
            "--model", "example/model",
            "--bench", "--seconds", "60", "--cadence-ms", "100",
            "--wav", "/tmp/example.wav",
        ])

        XCTAssertEqual(
            options.benchmark,
            SpeechdBenchmarkOptions(
                seconds: 60,
                cadenceMilliseconds: 100,
                wavPath: "/tmp/example.wav"
            )
        )
    }

    func testBenchmarkCadenceDefaultsToNativeCadence() throws {
        let options = try SpeechdOptionParser.parse([
            "--model", "example/model", "--bench", "--seconds", "5",
        ])

        XCTAssertEqual(options.benchmark?.cadenceMilliseconds, 100)
    }

    func testBenchmarkRequiresPositiveSeconds() {
        XCTAssertThrowsError(
            try SpeechdOptionParser.parse(["--model", "example/model", "--bench"])
        ) { error in
            XCTAssertEqual(error as? SpeechdOptionError, .missingValue("--seconds"))
        }
        XCTAssertThrowsError(
            try SpeechdOptionParser.parse([
                "--model", "example/model", "--bench", "--seconds", "0",
            ])
        ) { error in
            XCTAssertEqual(error as? SpeechdOptionError, .invalidValue("--seconds"))
        }
    }

    func testBenchmarkOnlyFlagsRequireBenchMode() {
        XCTAssertThrowsError(
            try SpeechdOptionParser.parse([
                "--model", "example/model", "--seconds", "60",
            ])
        ) { error in
            XCTAssertEqual(error as? SpeechdOptionError, .invalidValue("--seconds"))
        }
    }

    func testPinnedRevisionLocatorNeverFallsBackToMain() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: "speechd-hf-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let repoID = "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead"
        let snapshots = cacheRoot
            .appending(path: "models--T0mSIlver--Voxtral-Mini-4B-Realtime-2602-4bit-qhead")
            .appending(path: "snapshots")
        let pinned = snapshots.appending(path: "pinned")
        let main = snapshots.appending(path: "moved-main")
        try FileManager.default.createDirectory(at: pinned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: pinned.appending(path: "config.json"))
        try Data("{}".utf8).write(to: main.appending(path: "config.json"))

        XCTAssertEqual(
            try SpeechHFCacheModelLocator.locate(
                repoID: repoID,
                revision: "pinned",
                cacheRoot: cacheRoot
            ).standardizedFileURL,
            pinned.standardizedFileURL
        )
        XCTAssertThrowsError(
            try SpeechHFCacheModelLocator.locate(
                repoID: repoID,
                revision: "absent-pin",
                cacheRoot: cacheRoot
            )
        )
    }

    func testModelAndModelDirectoryAreMutuallyExclusive() throws {
        XCTAssertThrowsError(
            try SpeechdOptionParser.parse([
                "--model", "mlx-community/model",
                "--model-dir", "/tmp/model",
            ])
        ) { error in
            XCTAssertEqual(
                error as? SpeechdOptionError,
                .mutuallyExclusive("--model", "--model-dir")
            )
            XCTAssertEqual(
                String(describing: error),
                "--model and --model-dir are mutually exclusive"
            )
        }
    }
}
