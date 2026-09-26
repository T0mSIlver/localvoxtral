import Foundation
import XCTest
import localvoxtralTestSupport

/// A run names a recorded set by who spoke it, so a TTS set never scores as
/// the owner's voice (#685).
final class RecordedAudioSetTests: XCTestCase {
    private func manifest(_ sourceField: String) throws -> RecordedAudioSet.Manifest {
        try RecordedAudioSet.parseManifest(Data("""
            {"schemaVersion":1,"dataFormat":"pcm_s16le@16000Hz-mono",\(sourceField)"recordings":[]}
            """.utf8))
    }

    func testManifestWithoutSourceIsHuman() throws {
        XCTAssertEqual(try manifest("").audioLabel(setName: "owner"), "human/owner")
    }

    func testManifestSourceNamesTheEngine() throws {
        XCTAssertEqual(
            try manifest(#""source":"say","#).audioLabel(setName: "say-samantha-thomas"),
            "say/say-samantha-thomas"
        )
    }

    func testAgentDictationKeepsItsHumanLabel() throws {
        XCTAssertEqual(
            try manifest("").audioLabel(setName: "owner", human: "human-recorded"), "human-recorded/owner"
        )
        XCTAssertEqual(
            try manifest(#""source":"say","#).audioLabel(setName: "tts", human: "human-recorded"), "say/tts"
        )
    }
}
