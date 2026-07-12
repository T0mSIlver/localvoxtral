import Foundation

/// Loader + Codable schema for the agent-dictation eval corpus at
/// `EvalCorpus/agent-dictation/` (repo root). Phase 1 ships the corpus and
/// this loader with a validation suite; the Phase 2 harness (TTS →
/// production websocket ASR → production polish → scoring) consumes the
/// same loader. Schema reference and authoring rules live in the corpus
/// directory's README.md.
///
/// Scoring contract carried per case (enforced structurally by
/// `AgentDictationEvalCorpusTests`, enforced behaviorally by Phase 2):
/// - `requiredTokens` must appear in the final output, byte-exact after
///   spacing normalization (`LLMPolishEvalSupport.normalizedSpacing`);
///   case-sensitive unless the case sets `caseInsensitive`.
/// - `forbiddenSubstrings` must NOT appear in the final output, matched
///   case-insensitively (they are contamination detectors: filler words,
///   macro marker phrases, leaked payloads).
/// - `exactText` metric: normalized whole-output equality with
///   `intendedText` (same normalization).
///
/// Eval policy (owner-established, non-negotiable): no probabilistic pass
/// bars. `required` cases assert individually; `known-hard` cases are
/// XFAIL-tracked. Promotion to `required` needs cross-server-state
/// stability, so every NEW case starts `known-hard`; only direct
/// migrations of currently-required `LLMPolishEvalSupport` cases carry
/// `required` from day one.
enum AgentDictationEvalCorpus {
    /// Metric identifiers a case's `status` map may key on.
    static let validMetrics: Set<String> = ["tokens", "exactText"]

    /// The exact stratum names the corpus must contain — a new stratum is a
    /// deliberate act (update this list and the README together).
    static let expectedStrata: Set<String> = [
        "plain-asr-baseline",
        "symbol-forms",
        "filenames-backticks",
        "fillers-self-corrections",
        "punctuation-spacing-migration",
        "enumerations",
        "clipboard-context",
        "paste-clipboard-macro",
        "repo-vocabulary",
        "guard-stress",
    ]

    enum Language: String, Codable {
        case en
        case fr
    }

    enum Status: String, Codable {
        case required
        case knownHard = "known-hard"
    }

    /// Which production pipeline the Phase 2 harness drives for a stratum.
    enum Pipeline: String, Codable {
        /// TTS(spokenForm) → websocket ASR → polish → scoring.
        case full
        /// TTS(spokenForm) → websocket ASR → scoring (no polish; the
        /// baseline stratum asserts only ASR-stable tokens).
        case asrOnly = "asr-only"
        /// spokenForm fed directly to the polish path as input text —
        /// preserves the semantics of the migrated LLMPolishEvalSupport
        /// corpus, whose inputs carry ASR-artifact spacing TTS cannot speak.
        case polishOnly = "polish-only"
    }

    /// CodingKey that accepts any string key — used to enumerate a JSON
    /// object's ACTUAL keys so schema drift is rejected instead of silently
    /// dropped by JSONDecoder. Without this, a typo'd optional field (e.g.
    /// `features.clipboardPayload`) decodes fine, the fixture is lost, and
    /// Phase 2 would run the case without its intended setup.
    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    fileprivate static func rejectUnknownKeys(
        in decoder: Decoder,
        allowed: Set<String>,
        describing objectName: String
    ) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription:
                        "\(objectName) has unknown key(s): \(unknown.sorted().joined(separator: ", ")) "
                        + "— schema drift is rejected; fix the corpus file or extend the schema deliberately"
                )
            )
        }
    }

    struct RepoFeature: Codable, Equatable {
        /// Name of a fixture spec in `fixtures/repo-<fixture>.json`.
        let fixture: String
        /// The fixture files this case depends on (validated ⊆ fixture spec).
        let files: [String]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case fixture, files
        }

        init(from decoder: Decoder) throws {
            try AgentDictationEvalCorpus.rejectUnknownKeys(
                in: decoder,
                allowed: Set(CodingKeys.allCases.map(\.rawValue)),
                describing: "features.repo"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fixture = try container.decode(String.self, forKey: .fixture)
            files = try container.decode([String].self, forKey: .files)
        }
    }

    struct Features: Codable, Equatable {
        /// Clipboard payload the harness must place on the pasteboard
        /// (clipboard-as-context and macro strata).
        let clipboard: String?
        /// Repo-vocabulary fixture the harness must git-init and front.
        let repo: RepoFeature?
        /// true → the spoken macro MUST fire (payload embedded in output);
        /// false → explicit negative, the macro must NOT fire; nil → no
        /// macro semantics.
        let macro: Bool?

        init(clipboard: String? = nil, repo: RepoFeature? = nil, macro: Bool? = nil) {
            self.clipboard = clipboard
            self.repo = repo
            self.macro = macro
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case clipboard, repo, macro
        }

        init(from decoder: Decoder) throws {
            try AgentDictationEvalCorpus.rejectUnknownKeys(
                in: decoder,
                allowed: Set(CodingKeys.allCases.map(\.rawValue)),
                describing: "features"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            clipboard = try container.decodeIfPresent(String.self, forKey: .clipboard)
            repo = try container.decodeIfPresent(RepoFeature.self, forKey: .repo)
            macro = try container.decodeIfPresent(Bool.self, forKey: .macro)
        }
    }

    struct Source: Codable, Equatable {
        /// e.g. "LLMPolishEvalSupport.requiredCases" — set on direct
        /// migrations, which the validation suite byte-matches against the
        /// Swift originals.
        let migratedFrom: String?
        /// The original case id in the migrated-from corpus.
        let originalId: String?
        /// Free-form seed attribution ("idiolect", "field-2026-07", …).
        let seed: String?

        init(migratedFrom: String? = nil, originalId: String? = nil, seed: String? = nil) {
            self.migratedFrom = migratedFrom
            self.originalId = originalId
            self.seed = seed
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case migratedFrom, originalId, seed
        }

        init(from decoder: Decoder) throws {
            try AgentDictationEvalCorpus.rejectUnknownKeys(
                in: decoder,
                allowed: Set(CodingKeys.allCases.map(\.rawValue)),
                describing: "source"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            migratedFrom = try container.decodeIfPresent(String.self, forKey: .migratedFrom)
            originalId = try container.decodeIfPresent(String.self, forKey: .originalId)
            seed = try container.decodeIfPresent(String.self, forKey: .seed)
        }
    }

    struct Case: Codable {
        let id: String
        let lang: Language
        /// Exactly what TTS will speak — symbols written phonetically the
        /// way a human dictates ("dash dash force", "dot env").
        let spokenForm: String
        /// Ground-truth final output.
        let intendedText: String
        /// Byte-exact (after spacing normalization) substrings that MUST
        /// appear in the final text — the primary metric.
        let requiredTokens: [String]
        /// Substrings that must NOT appear (matched case-insensitively).
        let forbiddenSubstrings: [String]?
        /// true → requiredTokens matched case-insensitively (migrated
        /// punctuation cases keep the old scorer's semantics; the ASR
        /// baseline stratum tolerates ASR casing).
        let caseInsensitive: Bool?
        let features: Features?
        /// Per-metric status: "tokens" and/or "exactText" → required |
        /// known-hard. Every case carries at least "tokens".
        let status: [String: Status]
        /// One line: why this case exists.
        let notes: String
        let source: Source?

        var forbidden: [String] { forbiddenSubstrings ?? [] }
        var isCaseInsensitive: Bool { caseInsensitive ?? false }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, lang, spokenForm, intendedText, requiredTokens
            case forbiddenSubstrings, caseInsensitive, features, status, notes, source
        }

        init(from decoder: Decoder) throws {
            try AgentDictationEvalCorpus.rejectUnknownKeys(
                in: decoder,
                allowed: Set(CodingKeys.allCases.map(\.rawValue)),
                describing: "case"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            lang = try container.decode(Language.self, forKey: .lang)
            spokenForm = try container.decode(String.self, forKey: .spokenForm)
            intendedText = try container.decode(String.self, forKey: .intendedText)
            requiredTokens = try container.decode([String].self, forKey: .requiredTokens)
            forbiddenSubstrings = try container.decodeIfPresent([String].self, forKey: .forbiddenSubstrings)
            caseInsensitive = try container.decodeIfPresent(Bool.self, forKey: .caseInsensitive)
            features = try container.decodeIfPresent(Features.self, forKey: .features)
            status = try container.decode([String: Status].self, forKey: .status)
            notes = try container.decode(String.self, forKey: .notes)
            source = try container.decodeIfPresent(Source.self, forKey: .source)
        }
    }

    struct Stratum: Codable {
        let schemaVersion: Int
        let stratum: String
        let description: String
        let pipeline: Pipeline?
        let cases: [Case]

        var resolvedPipeline: Pipeline { pipeline ?? .full }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion, stratum, description, pipeline, cases
        }

        init(from decoder: Decoder) throws {
            try AgentDictationEvalCorpus.rejectUnknownKeys(
                in: decoder,
                allowed: Set(CodingKeys.allCases.map(\.rawValue)),
                describing: "stratum file"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            stratum = try container.decode(String.self, forKey: .stratum)
            description = try container.decode(String.self, forKey: .description)
            pipeline = try container.decodeIfPresent(Pipeline.self, forKey: .pipeline)
            cases = try container.decode([Case].self, forKey: .cases)
        }
    }

    struct RepoFixture: Codable {
        let name: String
        let branch: String
        /// Paths the Phase 2 harness will `git init` + commit (content is
        /// irrelevant to the vocabulary index; paths are the vocabulary).
        let files: [String]

        init(name: String, branch: String, files: [String]) {
            self.name = name
            self.branch = branch
            self.files = files
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case name, branch, files
        }

        init(from decoder: Decoder) throws {
            try AgentDictationEvalCorpus.rejectUnknownKeys(
                in: decoder,
                allowed: Set(CodingKeys.allCases.map(\.rawValue)),
                describing: "repo fixture"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            branch = try container.decode(String.self, forKey: .branch)
            files = try container.decode([String].self, forKey: .files)
        }
    }

    struct LoadedStratum {
        let fileName: String
        let stratum: Stratum
    }

    enum LoadError: Error, CustomStringConvertible {
        case corpusDirectoryMissing(String)
        case decodeFailed(file: String, underlying: Error)
        case duplicateRepoFixtureName(String)

        var description: String {
            switch self {
            case .corpusDirectoryMissing(let path):
                return "corpus directory not found at \(path)"
            case .decodeFailed(let file, let underlying):
                return "failed to decode \(file): \(underlying)"
            case .duplicateRepoFixtureName(let name):
                return "duplicate repo fixture name '\(name)' — fixture names must be unique across fixtures/"
            }
        }
    }

    /// Repo root derived from this file's location
    /// (Tests/localvoxtralTests/AgentDictationEvalCorpus.swift). The corpus
    /// is test-only data consumed from the source tree — it is never a
    /// packaged app resource, so the Bundle.localvoxtralResources rules do
    /// not apply; remote-build.sh rsyncs the whole working tree, so the
    /// path resolves on the build host too.
    static func corpusDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // localvoxtralTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("EvalCorpus", isDirectory: true)
            .appendingPathComponent("agent-dictation", isDirectory: true)
    }

    static func loadStrata() throws -> [LoadedStratum] {
        let strataDirectory = corpusDirectory().appendingPathComponent("strata", isDirectory: true)
        return try decodeJSONFiles(in: strataDirectory) { fileName, data in
            LoadedStratum(
                fileName: fileName,
                stratum: try decode(Stratum.self, from: data, file: fileName)
            )
        }
    }

    /// Fixture specs keyed by their `name` field.
    static func loadRepoFixtures() throws -> [String: RepoFixture] {
        let fixturesDirectory = corpusDirectory().appendingPathComponent("fixtures", isDirectory: true)
        let fixtures = try decodeJSONFiles(in: fixturesDirectory) { fileName, data in
            try decode(RepoFixture.self, from: data, file: fileName)
        }
        return try indexRepoFixtures(fixtures)
    }

    /// Keys fixtures by name, throwing a readable error on duplicates
    /// (Dictionary(uniqueKeysWithValues:) would trap and crash the suite
    /// instead of producing an XCTest failure).
    static func indexRepoFixtures(_ fixtures: [RepoFixture]) throws -> [String: RepoFixture] {
        var indexed: [String: RepoFixture] = [:]
        for fixture in fixtures {
            guard indexed.updateValue(fixture, forKey: fixture.name) == nil else {
                throw LoadError.duplicateRepoFixtureName(fixture.name)
            }
        }
        return indexed
    }

    static func allCases() throws -> [Case] {
        try loadStrata().flatMap(\.stratum.cases)
    }

    private static func decodeJSONFiles<T>(
        in directory: URL,
        transform: (String, Data) throws -> T
    ) throws -> [T] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw LoadError.corpusDirectoryMissing(directory.path)
        }
        let fileURLs = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try fileURLs.map { url in
            let data = try Data(contentsOf: url)
            return try transform(url.lastPathComponent, data)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, file: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LoadError.decodeFailed(file: file, underlying: error)
        }
    }
}
