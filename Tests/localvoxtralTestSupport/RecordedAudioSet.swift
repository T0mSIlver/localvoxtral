import Foundation
import localvoxtralCore

/// A recorded audio set: WAVs in one directory with a `manifest.json` that
/// binds each file to a case id, its language, the words spoken and a
/// SHA-256. The agent-dictation eval and the term-recall eval read the same
/// format; the owner's sets live outside any checkout. A set is the owner's
/// voice unless its manifest names the engine that spoke it in `source`.
package enum RecordedAudioSet {
    package enum Language: String, Codable, Sendable {
        case en
        case fr
    }

    package static let manifestFileName = "manifest.json"
    package static let schemaVersion = 1
    package static let dataFormat = "pcm_s16le@16000Hz-mono"

    package struct Manifest: Codable, Equatable {
        package let schemaVersion: Int
        package let dataFormat: String
        package let recordings: [Recording]
        /// The TTS engine that spoke the set, e.g. `say`; absent for human
        /// recordings.
        package let source: String?

        package init(
            schemaVersion: Int, dataFormat: String, recordings: [Recording], source: String? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.dataFormat = dataFormat
            self.recordings = recordings
            self.source = source
        }

        /// How a run names its audio: `<source>/<set>`, `human/<set>` when
        /// the manifest names no source.
        package func audioLabel(setName: String) -> String {
            "\(source ?? "human")/\(setName)"
        }
    }

    package struct Recording: Codable, Equatable {
        package let id: String
        package let lang: Language
        package let spokenForm: String
        package let file: String
        package let sha256: String

        package init(id: String, lang: Language, spokenForm: String, file: String, sha256: String) {
            self.id = id
            self.lang = lang
            self.spokenForm = spokenForm
            self.file = file
            self.sha256 = sha256
        }
    }

    package struct Expectation: Equatable {
        package let id: String
        package let lang: Language
        package let spokenForm: String

        package init(id: String, lang: Language, spokenForm: String) {
            self.id = id
            self.lang = lang
            self.spokenForm = spokenForm
        }
    }

    package struct SetError: Error, LocalizedError, Equatable {
        package let message: String
        package var errorDescription: String? { message }

        package init(message: String) {
            self.message = message
        }
    }

    package static func parseManifest(_ data: Data) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Validates the manifest against the exact speech-running corpus before
    /// model load. Recorded mode is deliberately all-or-nothing by default:
    /// partial sets, corpus drift, duplicate IDs, unsafe filenames, and stale
    /// extras fail loudly rather than producing a TTS/human hybrid baseline.
    /// `allowSubset` is an explicit exploratory mode that validates and runs
    /// only known recorded IDs; it never fills missing cases with TTS.
    package static func validateManifest(
        _ manifest: Manifest,
        expected: [Expectation],
        allowSubset: Bool = false
    ) throws -> [String: Recording] {
        guard manifest.schemaVersion == Self.schemaVersion else {
            throw SetError(message: "recording manifest schemaVersion must be \(schemaVersion)")
        }
        guard manifest.dataFormat == Self.dataFormat else {
            throw SetError(message: "recording manifest dataFormat must be \(dataFormat)")
        }

        var byID: [String: Recording] = [:]
        for recording in manifest.recordings {
            guard byID[recording.id] == nil else {
                throw SetError(message: "duplicate recording id: \(recording.id)")
            }
            guard recording.file == "\(recording.id).wav",
                  !recording.file.contains("/"), !recording.file.contains("..")
            else {
                throw SetError(message: "unsafe recording filename for \(recording.id)")
            }
            guard recording.sha256.count == 64,
                  recording.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else {
                throw SetError(message: "invalid SHA-256 for recording \(recording.id)")
            }
            byID[recording.id] = recording
        }

        let actualIDs = Set(byID.keys)
        let expectedForRun: [Expectation]
        if allowSubset {
            guard !actualIDs.isEmpty else {
                throw SetError(message: "recording subset is empty")
            }
            expectedForRun = expected.filter { actualIDs.contains($0.id) }
        } else {
            expectedForRun = expected
        }
        let expectedIDs = Set(expectedForRun.map(\.id))
        let missing = expectedIDs.subtracting(actualIDs).sorted()
        let extra = actualIDs.subtracting(expectedIDs).sorted()
        guard missing.isEmpty else {
            throw SetError(message: "recording set is incomplete; missing: \(missing.joined(separator: ", "))")
        }
        guard extra.isEmpty else {
            throw SetError(message: "recording set has stale/unknown cases: \(extra.joined(separator: ", "))")
        }
        for item in expectedForRun {
            guard let recording = byID[item.id] else { continue }
            guard recording.lang == item.lang, recording.spokenForm == item.spokenForm else {
                throw SetError(
                    message: "recording \(item.id) is stale; language or spokenForm changed"
                )
            }
        }
        return byID
    }

    /// Validates the exact format the websocket client expects and returns the
    /// data chunk. The recorder command writes this format directly, avoiding
    /// an implicit resample during eval.
    package static func pcm16(fromWAVData wav: Data) throws -> Data {
        guard wav.count >= 44,
              String(data: wav[0..<4], encoding: .ascii) == "RIFF",
              String(data: wav[8..<12], encoding: .ascii) == "WAVE"
        else { throw SetError(message: "recording is not a RIFF/WAVE file") }

        var format: (code: UInt16, channels: UInt16, rate: UInt32, bits: UInt16)?
        var pcm: Data?
        var index = 12
        while index + 8 <= wav.count {
            let chunkID = String(data: wav[index..<(index + 4)], encoding: .ascii) ?? ""
            let size = Int(readLEUInt32(wav, at: index + 4))
            let start = index + 8
            let end = start + size
            guard end <= wav.count else {
                throw SetError(message: "recording has a truncated WAV chunk")
            }
            if chunkID == "fmt ", size >= 16 {
                format = (
                    readLEUInt16(wav, at: start),
                    readLEUInt16(wav, at: start + 2),
                    readLEUInt32(wav, at: start + 4),
                    readLEUInt16(wav, at: start + 14)
                )
            } else if chunkID == "data" {
                pcm = wav.subdata(in: start..<end)
            }
            index = end + (size % 2)
        }
        guard let format else {
            throw SetError(message: "recording has no WAV fmt chunk")
        }
        guard format.code == 1, format.channels == 1,
              format.rate == 16_000, format.bits == 16
        else {
            throw SetError(
                message: "recording must be mono 16-bit PCM at 16000 Hz"
            )
        }
        guard let pcm, pcm.count >= 8_000, pcm.count.isMultiple(of: 2) else {
            throw SetError(message: "recording is missing or shorter than 0.25 seconds")
        }
        var containsSignal = false
        var sampleOffset = 0
        while sampleOffset < pcm.count {
            if readLEUInt16(pcm, at: sampleOffset) != 0 {
                containsSignal = true
                break
            }
            sampleOffset += 2
        }
        guard containsSignal else {
            throw SetError(message: "recording is digitally silent")
        }
        return pcm
    }

    private static func readLEUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readLEUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
