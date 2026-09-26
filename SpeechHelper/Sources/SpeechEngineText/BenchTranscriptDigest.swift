import CryptoKit
import Foundation

/// The bench's transcript fingerprint. Two arms that decode the same audio to the
/// same text print the same line, so a speed change can be checked for an output
/// change without logging the words.
public enum BenchTranscriptDigest {
    public static func line(for transcript: String) -> String {
        let digest = SHA256.hash(data: Data(transcript.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "BENCH transcript sha256=\(hex) chars=\(transcript.count)"
    }
}
