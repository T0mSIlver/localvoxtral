import Foundation
import XCTest
import localvoxtralCore

/// Spoken test audio could not be made. A thrown error, not an `XCTSkip`:
/// callers reach it only once their lane is enabled, and a lane whose tests
/// all skip exits 0 with nothing measured (#1196).
package struct SpokenAudioFailure: Error, CustomStringConvertible {
    package let description: String

    package init(description: String) {
        self.description = description
    }
}

package enum IntegrationTestSupport {
    private static let tokenRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")

    package static func extractPCMDataFromWAV(at url: URL) throws -> Data {
        let wavData = try Data(contentsOf: url)
        guard wavData.count >= 44 else {
            throw SpokenAudioFailure(description: "Generated WAV audio is unexpectedly short.")
        }

        var index = 12
        while index + 8 <= wavData.count {
            let chunkIDData = wavData[index ..< index + 4]
            let chunkID = String(data: chunkIDData, encoding: .ascii) ?? ""
            let chunkSize = Int(readLEUInt32(in: wavData, at: index + 4))
            let chunkStart = index + 8
            let chunkEnd = chunkStart + chunkSize

            guard chunkEnd <= wavData.count else { break }

            if chunkID == "data" {
                return wavData.subdata(in: chunkStart ..< chunkEnd)
            }

            index = chunkEnd
            if index % 2 == 1 {
                index += 1
            }
        }

        throw SpokenAudioFailure(description: "WAV audio does not contain a valid data chunk.")
    }

    /// Synthesizes a spoken phrase with the system TTS and returns its raw
    /// 16 kHz mono PCM16 samples — the same synthetic-speech source every live
    /// realtime lane uses, so accuracy bars stay comparable across providers.
    /// Throws `SpokenAudioFailure` when `say` is missing or errors.
    package static func makeSpokenPCM16Data(
        phrase: String,
        say: URL = URL(fileURLWithPath: "/usr/bin/say")
    ) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("svxt-tts-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let process = Process()
        process.executableURL = say
        process.arguments = [
            "-o", tempURL.path,
            "--file-format=WAVE",
            "--data-format=LEI16@16000",
            phrase,
        ]

        do {
            try process.run()
        } catch {
            throw SpokenAudioFailure(description: "Failed to execute \(say.path): \(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SpokenAudioFailure(description: "System TTS (say) failed with status \(process.terminationStatus).")
        }

        return try extractPCMDataFromWAV(at: tempURL)
    }

    package static func splitPCM16IntoChunks(_ pcm: Data, chunkSizeBytes: Int) -> [Data] {
        guard chunkSizeBytes > 0, !pcm.isEmpty else { return pcm.isEmpty ? [] : [pcm] }

        var chunks: [Data] = []
        chunks.reserveCapacity(max(1, pcm.count / chunkSizeBytes))

        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunkSizeBytes, pcm.count)
            chunks.append(pcm.subdata(in: offset ..< end))
            offset = end
        }

        return chunks
    }

    package static func wordAccuracy(expected: String, actual: String) -> Double {
        let expectedTokens = tokenizedWords(from: expected)
        let actualTokens = tokenizedWords(from: actual)

        if expectedTokens.isEmpty {
            return actualTokens.isEmpty ? 1.0 : 0.0
        }

        let distance = levenshteinDistance(lhs: expectedTokens, rhs: actualTokens)
        let denominator = max(expectedTokens.count, actualTokens.count)
        guard denominator > 0 else { return 1.0 }

        return max(0.0, 1.0 - (Double(distance) / Double(denominator)))
    }

    private static func tokenizedWords(from text: String) -> [String] {
        let normalized = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !normalized.isEmpty else { return [] }

        let range = NSRange(normalized.startIndex..., in: normalized)
        let matches = tokenRegex.matches(in: normalized, options: [], range: range)
        var tokens: [String] = []
        tokens.reserveCapacity(matches.count)

        for match in matches {
            guard let tokenRange = Range(match.range, in: normalized) else { continue }
            tokens.append(String(normalized[tokenRange]))
        }

        return tokens
    }

    private static func levenshteinDistance(lhs: [String], rhs: [String]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0 ... rhs.count)

        for (leftIndex, leftToken) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = leftIndex + 1

            for (rightIndex, rightToken) in rhs.enumerated() {
                let substitutionCost = leftToken == rightToken ? 0 : 1
                let deletion = previous[rightIndex + 1] + 1
                let insertion = current[rightIndex] + 1
                let substitution = previous[rightIndex] + substitutionCost
                current[rightIndex + 1] = min(min(deletion, insertion), substitution)
            }

            previous = current
        }

        return previous[rhs.count]
    }

    private static func readLEUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
