import Foundation
import XCTest
@testable import localvoxtral

enum IntegrationTestSupport {
    private static let tokenRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")

    static func extractPCMDataFromWAV(at url: URL) throws -> Data {
        let wavData = try Data(contentsOf: url)
        guard wavData.count >= 44 else {
            throw XCTSkip("Generated WAV audio is unexpectedly short.")
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

        throw XCTSkip("WAV audio does not contain a valid data chunk.")
    }

    static func splitPCM16IntoChunks(_ pcm: Data, chunkSizeBytes: Int) -> [Data] {
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

    static func wordAccuracy(expected: String, actual: String) -> Double {
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
