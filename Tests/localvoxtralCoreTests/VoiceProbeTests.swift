import Foundation
import XCTest

/// Holds an xctest process of this package alive for eval-e2e's voice probe
/// (#960): `say -v ?` lists only the built-in voices while the eval's xctest
/// runs, whoever spawns `say`. Runs only with LV_VOICE_PROBE_MARKER set.
final class VoiceProbeTests: XCTestCase {
    func testHoldTheProcessWhileTheShellListsVoices() throws {
        guard let marker = ProcessInfo.processInfo.environment["LV_VOICE_PROBE_MARKER"] else {
            throw XCTSkip("eval-e2e's voice probe sets LV_VOICE_PROBE_MARKER")
        }
        FileManager.default.createFile(atPath: marker, contents: nil)
        Thread.sleep(forTimeInterval: 20)
    }
}
