import CryptoKit
import Foundation

/// Which polishing prompt profile to load. `standard` is the general STT
/// cleanup prompt used everywhere; `agent` is the terminal/coding-agent
/// dictation profile that additionally normalizes spoken symbols, backticks
/// paths/flags, etc. — while never answering or expanding the dictated prompt.
enum PolishPromptProfile: String, Sendable {
    case standard
    case agent
}

protocol AppConfigServing {
    func configDirectoryURL() -> URL
    func loadReplacementDictionary() -> ReplacementDictionary
    func loadLLMPromptTemplates() -> LLMPromptTemplates
    func loadLLMPromptTemplates(profile: PolishPromptProfile) -> LLMPromptTemplates
    func loadTerminalAppBundleIDs() -> [String]
}

extension AppConfigServing {
    /// Default conformance so existing callers/mocks that only implement the
    /// zero-arg loader keep the standard behavior for every profile. The real
    /// `AppConfigStore` overrides this to load the agent files for `.agent`.
    func loadLLMPromptTemplates(profile: PolishPromptProfile) -> LLMPromptTemplates {
        loadLLMPromptTemplates()
    }
}

struct ReplacementEntry: Equatable, Sendable {
    let replaceWith: String
    let matches: [String]
}

struct ReplacementDictionary: Equatable, Sendable {
    let entries: [ReplacementEntry]

    func liveReplacementRules() -> [LiveReplacementRule] {
        var rules: [LiveReplacementRule] = []
        rules.reserveCapacity(entries.reduce(0) { $0 + $1.matches.count })

        var originalOrder = 0
        for entry in entries {
            for match in entry.matches {
                let normalized = match.collapsingInternalWhitespace.trimmed
                defer { originalOrder += 1 }
                guard !normalized.isEmpty else { continue }
                guard let regex = Self.makeRegex(for: normalized) else { continue }
                rules.append(
                    LiveReplacementRule(
                        regex: regex,
                        replaceWith: entry.replaceWith,
                        matchLength: normalized.count,
                        foldedKeyWords: normalized
                            .split(whereSeparator: \.isWhitespace)
                            .map { String($0).caseFoldedForMatching },
                        originalOrder: originalOrder
                    )
                )
            }
        }

        rules.sort()
        return rules
    }

    func apply(to text: String) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }

        let rules = prioritizedRules()
        guard !rules.isEmpty else { return text }

        var candidates: [ReplacementMatchCandidate] = []
        candidates.reserveCapacity(rules.count)

        let fullRange = NSRange(text.startIndex..., in: text)
        for rule in rules {
            let regex = rule.regex
            regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let match,
                      let range = Range(match.range, in: text)
                else {
                    return
                }

                candidates.append(
                    ReplacementMatchCandidate(
                        range: range,
                        replacement: rule.replaceWith,
                        priority: rule.priority
                    )
                )
            }
        }

        guard !candidates.isEmpty else { return text }

        // Sort by: earliest position, then longest match, then widest span,
        // then lexicographic replacement as a stable tiebreaker. The greedy
        // left-to-right scan below skips any candidate that overlaps an
        // already-applied replacement.
        candidates.sort { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            if lhs.range.upperBound != rhs.range.upperBound {
                return lhs.range.upperBound > rhs.range.upperBound
            }
            return lhs.replacement < rhs.replacement
        }

        var output = ""
        var cursor = text.startIndex
        output.reserveCapacity(text.count)

        for candidate in candidates {
            guard candidate.range.lowerBound >= cursor else { continue }
            output.append(contentsOf: text[cursor ..< candidate.range.lowerBound])
            output.append(candidate.replacement)
            cursor = candidate.range.upperBound
        }

        output.append(contentsOf: text[cursor...])
        return output
    }

    func renderedPromptSection() -> String {
        guard !entries.isEmpty else { return "" }

        let rules = entries.map { entry in
            let aliases = entry.matches.joined(separator: ", ")
            return "- \(entry.replaceWith): \(aliases)"
        }.joined(separator: "\n")

        return "Replacement dictionary:\n\(rules)"
    }

    private func prioritizedRules() -> [ReplacementRule] {
        var rules: [ReplacementRule] = []
        rules.reserveCapacity(entries.reduce(0) { $0 + $1.matches.count })

        var nextPriority = 0
        for entry in entries {
            for match in entry.matches {
                let normalized = match.collapsingInternalWhitespace.trimmed
                guard !normalized.isEmpty else { continue }
                guard let regex = Self.makeRegex(for: normalized) else { continue }
                rules.append(
                    ReplacementRule(
                        regex: regex,
                        replaceWith: entry.replaceWith,
                        priority: ReplacementPriority(
                            matchLength: normalized.count,
                            originalOrder: nextPriority
                        )
                    )
                )
                nextPriority += 1
            }
        }

        return rules
    }

    private static func makeRegex(for normalizedMatch: String) -> NSRegularExpression? {
        let parts = normalizedMatch
            .split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }

        let pattern = "(?<![\\p{L}\\p{N}])" + parts.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

struct LiveReplacementRule: Comparable {
    let regex: NSRegularExpression
    let replaceWith: String
    let matchLength: Int
    /// The match key's whitespace-separated words, each fully case-folded.
    ///
    /// `makeRegex` escapes every key with `escapedPattern` and joins the words
    /// with `\s+`, so a rule is a literal word list — no metacharacter ever
    /// survives. `LiveHoldBackReplacementStream` prefix-matches these words to
    /// decide how little text it can hold back. They are stored pre-folded
    /// because the regex matches case-insensitively with FULL case folding,
    /// which can change length (`ß` matches `ss`); comparing raw characters
    /// would miss live prefixes and release text a correction still rewrites.
    let foldedKeyWords: [String]
    let originalOrder: Int

    var wordCount: Int {
        foldedKeyWords.count
    }

    static func == (lhs: LiveReplacementRule, rhs: LiveReplacementRule) -> Bool {
        lhs.matchLength == rhs.matchLength
            && lhs.foldedKeyWords == rhs.foldedKeyWords
            && lhs.originalOrder == rhs.originalOrder
            && lhs.replaceWith == rhs.replaceWith
            && lhs.regex.pattern == rhs.regex.pattern
    }

    static func < (lhs: LiveReplacementRule, rhs: LiveReplacementRule) -> Bool {
        if lhs.matchLength != rhs.matchLength {
            return lhs.matchLength > rhs.matchLength
        }
        return lhs.originalOrder < rhs.originalOrder
    }
}

struct LLMPromptTemplates: Equatable, Sendable {
    let systemContent: String
    let userContent: String

    private static let requiredUserPlaceholders = ["{{input_text}}"]
    private static let optionalUserPlaceholders = ["{{replacement_dictionary}}"]
    private static let userPromptPlaceholderPattern = #"\{\{[a-zA-Z0-9_]+\}\}"#
    private static let splitPlaceholders = ["{{replacement_dictionary}}", "{{input_text}}"]

    /// True when the user template carries the OPTIONAL dictionary placeholder.
    /// The placeholder is documented as removable; features that ride in that
    /// slot (repo vocabulary) must check this BEFORE doing any work, because
    /// `renderTemplate` silently drops the section when the slot is absent.
    var supportsReplacementDictionary: Bool {
        userContent.contains("{{replacement_dictionary}}")
    }

    func renderedUserPrompt(
        inputText: String,
        replacementDictionary: String
    ) -> String {
        renderTemplate(
            userContent,
            inputText: inputText,
            replacementDictionary: replacementDictionary
        )
    }

    /// Splits the rendered user prompt into a stable prefix and a dynamic suffix
    /// at the first placeholder boundary. Serving the static prefix as a separate
    /// message enables LLM prompt-cache reuse across requests with different input.
    func renderedUserPrompts(
        inputText: String,
        replacementDictionary: String
    ) -> [String] {
        guard let splitIndex = splitBoundaryIndex() else {
            return [renderedUserPrompt(
                inputText: inputText,
                replacementDictionary: replacementDictionary
            )]
        }

        let prefix = String(userContent[..<splitIndex])
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [renderedUserPrompt(
                inputText: inputText,
                replacementDictionary: replacementDictionary
            )]
        }

        let suffix = String(userContent[splitIndex...])
        return [
            prefix,
            renderTemplate(
                suffix,
                inputText: inputText,
                replacementDictionary: replacementDictionary
            ),
        ]
    }

    private func renderTemplate(
        _ template: String,
        inputText: String,
        replacementDictionary: String
    ) -> String {
        var rendered = template
        if replacementDictionary.isEmpty {
            // An empty dictionary must not leave its template line behind as
            // a hole of blank lines between the context blocks and `Working
            // text:` (field report 2026-07-21). Drop the placeholder together
            // with one following blank line when present, else with its own
            // line; only a mid-line placeholder falls through to the bare
            // replacement below.
            rendered = rendered
                .replacingOccurrences(of: "{{replacement_dictionary}}\n\n", with: "")
                .replacingOccurrences(of: "{{replacement_dictionary}}\n", with: "")
        }
        // Dictionary before transcript: `inputText` is DICTATED CONTENT and may
        // legitimately contain a placeholder literal (the user talking about
        // this app). Substituting it last means nothing ever re-scans inserted
        // transcript text; the dictionary is app-generated and placeholder-free.
        return rendered
            .replacingOccurrences(of: "{{replacement_dictionary}}", with: replacementDictionary)
            .replacingOccurrences(of: "{{input_text}}", with: inputText)
    }

    /// Index of the first placeholder in `userContent`. Content before this
    /// point is static and sent as a separate message for cache reuse.
    private func splitBoundaryIndex() -> String.Index? {
        Self.splitPlaceholders
            .compactMap { placeholder in
                userContent.range(of: placeholder).map { $0.lowerBound }
            }
            .min()
    }

    func validateUserTemplate(fileName: String) throws {
        let missingRequiredPlaceholders = Self.requiredUserPlaceholders.filter {
            !userContent.contains($0)
        }
        guard missingRequiredPlaceholders.isEmpty else {
            throw AppConfigError.invalidFile(
                fileName: fileName,
                reason:
                    "Missing required prompt variable(s): \(missingRequiredPlaceholders.joined(separator: ", ")). `{{replacement_dictionary}}` is optional."
            )
        }

        let allowedPlaceholders = Set(Self.requiredUserPlaceholders + Self.optionalUserPlaceholders)
        let placeholderRegex = try NSRegularExpression(pattern: Self.userPromptPlaceholderPattern)
        let matches = placeholderRegex.matches(
            in: userContent,
            range: NSRange(userContent.startIndex..., in: userContent)
        )
        let foundPlaceholders = Set(matches.compactMap { match in
            Range(match.range, in: userContent).map { String(userContent[$0]) }
        })
        let unsupportedPlaceholders = foundPlaceholders.subtracting(allowedPlaceholders).sorted()
        guard unsupportedPlaceholders.isEmpty else {
            throw AppConfigError.invalidFile(
                fileName: fileName,
                reason:
                    "Unsupported prompt variable(s): \(unsupportedPlaceholders.joined(separator: ", ")). Supported variables are `{{input_text}}` and optional `{{replacement_dictionary}}`."
            )
        }
    }
}

private struct ReplacementPriority: Comparable {
    /// Character length of the match pattern (longer = higher priority).
    let matchLength: Int
    /// File-order tiebreaker (earlier entries = higher priority).
    let originalOrder: Int

    static func < (lhs: ReplacementPriority, rhs: ReplacementPriority) -> Bool {
        if lhs.matchLength != rhs.matchLength {
            return lhs.matchLength > rhs.matchLength  // Longer matches first
        }
        return lhs.originalOrder < rhs.originalOrder
    }
}

private struct ReplacementRule {
    let regex: NSRegularExpression
    let replaceWith: String
    let priority: ReplacementPriority
}

private struct ReplacementMatchCandidate {
    let range: Range<String.Index>
    let replacement: String
    let priority: ReplacementPriority
}

enum AppConfigError: Error, LocalizedError {
    case missingBundledResource(String)
    case invalidFile(fileName: String, reason: String)
    case unableToResolveConfigDirectory

    var errorDescription: String? {
        switch self {
        case .missingBundledResource(let fileName):
            return "Missing bundled config resource: \(fileName)"
        case .invalidFile(let fileName, let reason):
            return "Invalid config file \(fileName): \(reason)"
        case .unableToResolveConfigDirectory:
            return "Unable to resolve the localvoxtral config directory."
        }
    }
}

struct AppConfigStore: AppConfigServing {
    private enum ConfigFile: CaseIterable {
        case replacementDictionary
        case llmSystemPrompt
        case llmUserPrompt
        case llmSystemPromptAgent
        case llmUserPromptAgent
        case terminalApps

        var fileName: String {
            switch self {
            case .replacementDictionary:
                return "replacement_dictionary.toml"
            case .llmSystemPrompt:
                return "llm_system_prompt.toml"
            case .llmUserPrompt:
                return "llm_user_prompt.toml"
            case .llmSystemPromptAgent:
                return "llm_system_prompt_agent.toml"
            case .llmUserPromptAgent:
                return "llm_user_prompt_agent.toml"
            case .terminalApps:
                return "terminal_apps.toml"
            }
        }

        var resourceName: String {
            fileName.replacingOccurrences(of: ".toml", with: "")
        }
    }

    private let fileManager: FileManager
    private let bundle: Bundle
    private let configDirectoryOverride: URL?
    /// Seams for `reconcileBundledDefaults()`: tests inject a fixed clock for
    /// deterministic backup names and a custom hash table to simulate old
    /// shipped defaults without carrying their full content.
    private let knownDefaultHashes: [String: Set<String>]
    private let now: @Sendable () -> Date

    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .localvoxtralResources,
        configDirectoryOverride: URL? = nil,
        knownDefaultHashes: [String: Set<String>] = BundledConfigDefaultHistory.knownDefaultHashes,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.configDirectoryOverride = configDirectoryOverride
        self.knownDefaultHashes = knownDefaultHashes
        self.now = now
    }

    func configDirectoryURL() -> URL {
        let url = resolvedConfigDirectoryURL()
        ensureConfigFilesExist(at: url)
        return url
    }

    func loadReplacementDictionary() -> ReplacementDictionary {
        let defaultDictionary = loadBundledReplacementDictionary()
        let file = ConfigFile.replacementDictionary
        let url = userConfigURL(for: file)

        do {
            ensureConfigFilesExist(at: resolvedConfigDirectoryURL())
            let data = try Data(contentsOf: url)
            return try Self.parseReplacementDictionary(data: data, fileName: file.fileName)
        } catch {
            Log.config.error(
                "Replacement dictionary fallback to bundled default: \(error.localizedDescription, privacy: .public)"
            )
            return defaultDictionary
        }
    }

    func loadLLMPromptTemplates() -> LLMPromptTemplates {
        let defaultTemplates = loadBundledPromptTemplates()
        let systemPrompt = loadPromptContent(
            file: .llmSystemPrompt,
            fallback: defaultTemplates.systemContent
        )
        let candidateUserPrompt = loadPromptContent(
            file: .llmUserPrompt,
            fallback: defaultTemplates.userContent
        )
        let userPrompt: String
        do {
            let candidateTemplates = LLMPromptTemplates(
                systemContent: systemPrompt,
                userContent: candidateUserPrompt
            )
            try candidateTemplates.validateUserTemplate(fileName: ConfigFile.llmUserPrompt.fileName)
            userPrompt = candidateUserPrompt
        } catch {
            Log.config.error(
                "Prompt config fallback to bundled default for \(ConfigFile.llmUserPrompt.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            userPrompt = defaultTemplates.userContent
        }
        return LLMPromptTemplates(systemContent: systemPrompt, userContent: userPrompt)
    }

    /// Profile-aware prompt loader. `.standard` is byte-for-byte the existing
    /// loader; `.agent` reads the agent files through the same load/validate
    /// chain and falls back to the STANDARD templates on ANY failure, so a
    /// corrupt, missing, or placeholder-invalid agent file never leaves polish
    /// promptless.
    func loadLLMPromptTemplates(profile: PolishPromptProfile) -> LLMPromptTemplates {
        switch profile {
        case .standard:
            return loadLLMPromptTemplates()
        case .agent:
            return loadAgentPromptTemplates()
        }
    }

    private func loadAgentPromptTemplates() -> LLMPromptTemplates {
        let standardTemplates = loadLLMPromptTemplates()
        do {
            let systemPrompt = try loadAgentPromptContentStrict(file: .llmSystemPromptAgent)
            let userPrompt = try loadAgentPromptContentStrict(file: .llmUserPromptAgent)
            let candidate = LLMPromptTemplates(
                systemContent: systemPrompt,
                userContent: userPrompt
            )
            try candidate.validateUserTemplate(fileName: ConfigFile.llmUserPromptAgent.fileName)
            return candidate
        } catch {
            Log.config.error(
                "Agent prompt config fallback to standard templates: \(error.localizedDescription, privacy: .public)"
            )
            return standardTemplates
        }
    }

    /// Reads an agent prompt file strictly: seeds the config dir from the
    /// bundle if absent, then reads/parses the user file, throwing on any
    /// failure (no silent bundled fallback) so `loadAgentPromptTemplates` can
    /// fall back to the standard templates as the design requires.
    private func loadAgentPromptContentStrict(file: ConfigFile) throws -> String {
        ensureConfigFilesExist(at: resolvedConfigDirectoryURL())
        let data = try Data(contentsOf: userConfigURL(for: file))
        return try Self.parsePromptTemplate(data: data, fileName: file.fileName)
    }

    /// User-listed bundle IDs to treat as terminals, on top of
    /// `TerminalTargetDetector`'s built-in allowlist. Any read/parse failure
    /// falls back to an empty list (the built-in detection still applies).
    func loadTerminalAppBundleIDs() -> [String] {
        let file = ConfigFile.terminalApps
        let url = userConfigURL(for: file)

        do {
            ensureConfigFilesExist(at: resolvedConfigDirectoryURL())
            let data = try Data(contentsOf: url)
            return try Self.parseTerminalApps(data: data, fileName: file.fileName)
        } catch {
            Log.config.error(
                "Terminal apps config fallback to empty list: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private func loadPromptContent(file: ConfigFile, fallback: String) -> String {
        let url = userConfigURL(for: file)
        do {
            ensureConfigFilesExist(at: resolvedConfigDirectoryURL())
            let data = try Data(contentsOf: url)
            return try Self.parsePromptTemplate(data: data, fileName: file.fileName)
        } catch {
            Log.config.error(
                "Prompt config fallback to bundled default for \(file.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return fallback
        }
    }

    private func loadBundledReplacementDictionary() -> ReplacementDictionary {
        let file = ConfigFile.replacementDictionary
        guard let url = bundledResourceURL(for: file),
              let data = try? Data(contentsOf: url),
              let dictionary = try? Self.parseReplacementDictionary(data: data, fileName: file.fileName)
        else {
            Log.config.fault("Missing or invalid bundled replacement dictionary resource")
            return ReplacementDictionary(entries: [])
        }

        return dictionary
    }

    private func loadBundledPromptTemplates() -> LLMPromptTemplates {
        let systemContent = bundledPromptContent(for: .llmSystemPrompt)
            ?? "Clean up grammar, punctuation, and capitalization. Preserve intent. Return only the final corrected text."
        let candidateUserContent = bundledPromptContent(for: .llmUserPrompt)
            ?? "{{input_text}}"
        let userContent: String
        do {
            let templates = LLMPromptTemplates(
                systemContent: systemContent,
                userContent: candidateUserContent
            )
            try templates.validateUserTemplate(fileName: ConfigFile.llmUserPrompt.fileName)
            userContent = candidateUserContent
        } catch {
            Log.config.fault(
                "Invalid bundled user prompt template \(ConfigFile.llmUserPrompt.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            userContent = "{{input_text}}"
        }
        return LLMPromptTemplates(systemContent: systemContent, userContent: userContent)
    }

    private func bundledPromptContent(for file: ConfigFile) -> String? {
        guard let url = bundledResourceURL(for: file),
              let data = try? Data(contentsOf: url),
              let content = try? Self.parsePromptTemplate(data: data, fileName: file.fileName)
        else {
            Log.config.fault("Missing or invalid bundled prompt resource \(file.fileName, privacy: .public)")
            return nil
        }
        return content
    }

    private func bundledResourceURL(for file: ConfigFile) -> URL? {
        bundle.url(forResource: file.resourceName, withExtension: "toml")
    }

    private func resolvedConfigDirectoryURL() -> URL {
        if let configDirectoryOverride {
            return configDirectoryOverride
        }

        do {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return appSupport
                .appendingPathComponent("localvoxtral", isDirectory: true)
                .appendingPathComponent("config", isDirectory: true)
        } catch {
            Log.config.fault("Unable to resolve config directory: \(error.localizedDescription, privacy: .public)")
            let fallback = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("localvoxtral", isDirectory: true)
                .appendingPathComponent("config", isDirectory: true)
            return fallback
        }
    }

    private func userConfigURL(for file: ConfigFile) -> URL {
        resolvedConfigDirectoryURL().appendingPathComponent(file.fileName, isDirectory: false)
    }

    private func ensureConfigFilesExist(at directoryURL: URL) {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            Log.config.error(
                "Failed to create config directory \(directoryURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        for file in ConfigFile.allCases {
            let destinationURL = directoryURL.appendingPathComponent(file.fileName, isDirectory: false)
            guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
            guard let sourceURL = bundledResourceURL(for: file) else {
                Log.config.error("Missing bundled config template \(file.fileName, privacy: .public)")
                continue
            }

            do {
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: destinationURL, options: .atomic)
            } catch {
                Log.config.error(
                    "Failed to bootstrap \(file.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func parseReplacementDictionary(
        data: Data,
        fileName: String
    ) throws -> ReplacementDictionary {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppConfigError.invalidFile(fileName: fileName, reason: "File is not valid UTF-8.")
        }

        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalizedText.components(separatedBy: "\n")

        var entries: [ReplacementEntry] = []
        var currentReplaceWith: String?
        var currentMatches: [String]?
        var lineIndex = 0

        func finalizeCurrentEntry() throws {
            guard currentReplaceWith != nil || currentMatches != nil else { return }
            guard let replaceWith = currentReplaceWith?.trimmed, !replaceWith.isEmpty else {
                throw AppConfigError.invalidFile(
                    fileName: fileName,
                    reason: "Each [[replacement]] block requires a non-empty replace_with."
                )
            }
            guard let matches = currentMatches?.map({ $0.trimmed }).filter({ !$0.isEmpty }),
                  !matches.isEmpty
            else {
                throw AppConfigError.invalidFile(
                    fileName: fileName,
                    reason: "Each [[replacement]] block requires a non-empty matches array."
                )
            }

            entries.append(
                ReplacementEntry(
                    replaceWith: replaceWith,
                    matches: matches
                )
            )
            currentReplaceWith = nil
            currentMatches = nil
        }

        while lineIndex < rawLines.count {
            let rawLine = rawLines[lineIndex]
            let line = uncommented(rawLine).trimmed
            lineIndex += 1

            guard !line.isEmpty else { continue }

            if line == "[[replacement]]" {
                try finalizeCurrentEntry()
                continue
            }

            let components = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else {
                throw AppConfigError.invalidFile(
                    fileName: fileName,
                    reason: "Expected key/value assignment near `\(line)`."
                )
            }

            let key = String(components[0]).trimmed
            var value = String(components[1]).trimmed

            switch key {
            case "replace_with":
                currentReplaceWith = try parseBasicString(
                    value,
                    fileName: fileName,
                    fieldName: key
                )
            case "matches":
                while !hasBalancedSquareBrackets(in: value) {
                    guard lineIndex < rawLines.count else {
                        throw AppConfigError.invalidFile(
                            fileName: fileName,
                            reason: "Unterminated matches array."
                        )
                    }
                    let nextLine = uncommented(rawLines[lineIndex]).trimmed
                    value += "\n" + nextLine
                    lineIndex += 1
                }
                currentMatches = try parseStringArray(
                    value,
                    fileName: fileName,
                    fieldName: key
                )
            default:
                throw AppConfigError.invalidFile(
                    fileName: fileName,
                    reason: "Unsupported key `\(key)`."
                )
            }
        }

        try finalizeCurrentEntry()
        return ReplacementDictionary(entries: entries)
    }

    private static func parseTerminalApps(
        data: Data,
        fileName: String
    ) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppConfigError.invalidFile(fileName: fileName, reason: "File is not valid UTF-8.")
        }

        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalizedText.components(separatedBy: "\n")

        var bundleIDs: [String]?
        var lineIndex = 0

        while lineIndex < rawLines.count {
            let line = uncommented(rawLines[lineIndex]).trimmed
            lineIndex += 1

            guard !line.isEmpty else { continue }
            guard bundleIDs == nil else {
                throw AppConfigError.invalidFile(
                    fileName: fileName,
                    reason: "Only a single bundle_ids assignment is supported."
                )
            }

            let components = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2, String(components[0]).trimmed == "bundle_ids" else {
                throw AppConfigError.invalidFile(
                    fileName: fileName,
                    reason: "Expected `bundle_ids = [...]` near `\(line)`."
                )
            }

            var value = String(components[1]).trimmed
            while !hasBalancedSquareBrackets(in: value) {
                guard lineIndex < rawLines.count else {
                    throw AppConfigError.invalidFile(
                        fileName: fileName,
                        reason: "Unterminated bundle_ids array."
                    )
                }
                value += "\n" + uncommented(rawLines[lineIndex]).trimmed
                lineIndex += 1
            }

            bundleIDs = try parseStringArray(
                value,
                fileName: fileName,
                fieldName: "bundle_ids"
            ).map { $0.trimmed }.filter { !$0.isEmpty }
        }

        return bundleIDs ?? []
    }

    private static func parsePromptTemplate(
        data: Data,
        fileName: String
    ) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppConfigError.invalidFile(fileName: fileName, reason: "File is not valid UTF-8.")
        }

        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalizedText.components(separatedBy: "\n")

        var lineIndex = 0
        var content: String?

        while lineIndex < rawLines.count {
            let rawLine = rawLines[lineIndex]
            let trimmedLine = uncommented(rawLine).trimmed
            lineIndex += 1

            guard !trimmedLine.isEmpty else { continue }
            guard content == nil else {
                throw AppConfigError.invalidFile(
                    fileName: fileName,
                    reason: "Prompt files only support a single content assignment."
                )
            }

            let components = trimmedLine.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else {
                throw AppConfigError.invalidFile(
                    fileName: fileName,
                    reason: "Expected `content = ...`."
                )
            }

            let key = String(components[0]).trimmed
            guard key == "content" else {
                throw AppConfigError.invalidFile(
                    fileName: fileName,
                    reason: "Unsupported key `\(key)`."
                )
            }

            let value = String(components[1]).trimmed
            if value.hasPrefix("\"\"\"") {
                let buffer = String(value.dropFirst(3))
                if let range = buffer.range(of: "\"\"\"") {
                    content = String(buffer[..<range.lowerBound])
                    continue
                }

                var collectedLines: [String] = []
                if !buffer.isEmpty {
                    collectedLines.append(buffer)
                }

                while lineIndex < rawLines.count {
                    let nextLine = rawLines[lineIndex]
                    lineIndex += 1
                    if let range = nextLine.range(of: "\"\"\"") {
                        collectedLines.append(String(nextLine[..<range.lowerBound]))
                        content = collectedLines.joined(separator: "\n")
                        break
                    }
                    collectedLines.append(nextLine)
                }

                guard content != nil else {
                    throw AppConfigError.invalidFile(
                        fileName: fileName,
                        reason: "Unterminated multiline content string."
                    )
                }
            } else {
                content = try parseBasicString(
                    value,
                    fileName: fileName,
                    fieldName: "content"
                )
            }
        }

        guard let content else {
            throw AppConfigError.invalidFile(
                fileName: fileName,
                reason: "Missing content field."
            )
        }

        return content
    }
}

// MARK: - Bundled defaults reconciliation

/// `ensureConfigFilesExist` seeds bundled config files only when absent, so an
/// existing install never picks up improved bundled defaults on its own. This
/// extension closes that gap at launch: a user file whose content matches ANY
/// default ever shipped (`BundledConfigDefaultHistory`) is an unedited stale
/// seed and is refreshed in place; anything else is a customization and is
/// only ever replaced through `adoptBundledDefaults` after the user agrees.
/// A hidden sidecar in the config directory remembers which bundled version a
/// "keep mine" decision applied to, so the user is asked once per default
/// change, not once per launch.
extension AppConfigStore {
    private static let defaultsStateFileName = ".bundled-defaults-state.json"

    private struct BundledDefaultsState: Codable {
        /// fileName → bundled-default hash that has already been handled for
        /// that file (seen in sync, silently refreshed to, adopted, or
        /// declined). A file is reconsidered only when the current bundled
        /// hash differs from this entry — which is also what lets a user
        /// deliberately restore an OLD shipped default: the restore happens
        /// after the current default was recorded as handled, so it sticks
        /// instead of being silently re-refreshed on every launch.
        var resolvedBundledHashes: [String: String] = [:]
    }

    func reconcileBundledDefaults() -> BundledDefaultsReconciliation {
        let directory = resolvedConfigDirectoryURL()
        ensureConfigFilesExist(at: directory)

        var result = BundledDefaultsReconciliation()
        var state = readBundledDefaultsState(in: directory)
        var stateChanged = false

        func markResolved(_ file: ConfigFile, hash: String) {
            if state.resolvedBundledHashes[file.fileName] != hash {
                state.resolvedBundledHashes[file.fileName] = hash
                stateChanged = true
            }
        }

        for file in ConfigFile.allCases {
            // The replacement dictionary is the user's own rule set, not a
            // tunable default — its format has never changed since shipping,
            // and "updating" it would only swap the user's rules for the
            // bundled samples. Never refresh it, never prompt for it.
            if file == .replacementDictionary { continue }
            guard let bundled = bundledConfigData(for: file) else { continue }
            if state.resolvedBundledHashes[file.fileName] == bundled.hash { continue }
            let userURL = directory.appendingPathComponent(file.fileName, isDirectory: false)
            guard let userData = try? Data(contentsOf: userURL) else { continue }

            let userHash = Self.sha256Hex(userData)
            if userHash == bundled.hash {
                markResolved(file, hash: bundled.hash)
                continue
            }

            if knownDefaultHashes[file.fileName, default: []].contains(userHash) {
                do {
                    try bundled.data.write(to: userURL, options: .atomic)
                    result.refreshedFileNames.append(file.fileName)
                    markResolved(file, hash: bundled.hash)
                    Log.config.notice(
                        "Refreshed unedited default \(file.fileName, privacy: .public) to the current bundled version"
                    )
                } catch {
                    Log.config.error(
                        "Failed to refresh stale default \(file.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
                continue
            }

            result.customizedOutdatedFileNames.append(file.fileName)
        }

        if stateChanged {
            writeBundledDefaultsState(state, in: directory)
        }
        return result
    }

    /// Replaces the named user config files with the current bundled defaults,
    /// saving each existing file alongside as `<name>.backup-<timestamp>`.
    /// Returns the backup file names that were created.
    func adoptBundledDefaults(fileNames: [String]) -> [String] {
        let directory = resolvedConfigDirectoryURL()
        var state = readBundledDefaultsState(in: directory)
        var stateChanged = false
        var backupNames: [String] = []
        let suffix = backupSuffix()

        for file in ConfigFile.allCases where fileNames.contains(file.fileName) {
            guard let bundled = bundledConfigData(for: file) else { continue }
            let userURL = directory.appendingPathComponent(file.fileName, isDirectory: false)

            do {
                var backupName: String?
                if fileManager.fileExists(atPath: userURL.path) {
                    let name = availableBackupName(for: file.fileName, suffix: suffix, in: directory)
                    try fileManager.copyItem(
                        at: userURL,
                        to: directory.appendingPathComponent(name, isDirectory: false)
                    )
                    backupName = name
                }
                try bundled.data.write(to: userURL, options: .atomic)
                if let backupName {
                    backupNames.append(backupName)
                }
                if state.resolvedBundledHashes[file.fileName] != bundled.hash {
                    state.resolvedBundledHashes[file.fileName] = bundled.hash
                    stateChanged = true
                }
                Log.config.notice(
                    "Adopted new bundled default for \(file.fileName, privacy: .public)"
                )
            } catch {
                Log.config.error(
                    "Failed to adopt bundled default for \(file.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if stateChanged {
            writeBundledDefaultsState(state, in: directory)
        }
        return backupNames
    }

    /// Records that the user chose to keep their customized versions of the
    /// named files for the CURRENTLY bundled defaults — no further prompt
    /// until the bundled defaults change again.
    func recordKeptCustomizedDefaults(fileNames: [String]) {
        let directory = resolvedConfigDirectoryURL()
        var state = readBundledDefaultsState(in: directory)
        var stateChanged = false

        for file in ConfigFile.allCases where fileNames.contains(file.fileName) {
            guard let bundled = bundledConfigData(for: file) else { continue }
            if state.resolvedBundledHashes[file.fileName] != bundled.hash {
                state.resolvedBundledHashes[file.fileName] = bundled.hash
                stateChanged = true
            }
        }

        if stateChanged {
            writeBundledDefaultsState(state, in: directory)
        }
    }

    /// First `<fileName>.backup-<suffix>` name (with a `.2`, `.3`, … tiebreak)
    /// that doesn't already exist, so repeated adoptions never destroy an
    /// earlier backup.
    private func availableBackupName(
        for fileName: String,
        suffix: String,
        in directory: URL
    ) -> String {
        let base = "\(fileName).backup-\(suffix)"
        var candidate = base
        var counter = 2
        while fileManager.fileExists(
            atPath: directory.appendingPathComponent(candidate, isDirectory: false).path
        ) {
            candidate = "\(base).\(counter)"
            counter += 1
        }
        return candidate
    }

    private func bundledConfigData(for file: ConfigFile) -> (data: Data, hash: String)? {
        guard let url = bundledResourceURL(for: file),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return (data, Self.sha256Hex(data))
    }

    private func readBundledDefaultsState(in directory: URL) -> BundledDefaultsState {
        let url = directory.appendingPathComponent(Self.defaultsStateFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(BundledDefaultsState.self, from: data)
        else {
            return BundledDefaultsState()
        }
        return state
    }

    private func writeBundledDefaultsState(_ state: BundledDefaultsState, in directory: URL) {
        let url = directory.appendingPathComponent(Self.defaultsStateFileName, isDirectory: false)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            Log.config.error(
                "Failed to persist bundled-defaults state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func backupSuffix() -> String {
        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone.current, from: now())
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
    /// Test seam: the canonical config file list, so the
    /// `BundledConfigDefaultHistory` guard-rail test can't drift from the
    /// private `ConfigFile` enum when a new config file is added.
    static var debugAllConfigFileNames: [String] {
        ConfigFile.allCases.map(\.fileName)
    }
    #endif
}

private func uncommented(_ line: String) -> String {
    var result = ""
    var isInsideString = false
    var isEscaping = false

    for character in line {
        if isInsideString {
            result.append(character)
            if isEscaping {
                isEscaping = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                continue
            }
            if character == "\"" {
                isInsideString = false
            }
            continue
        }

        if character == "#" {
            break
        }
        if character == "\"" {
            isInsideString = true
        }
        result.append(character)
    }

    return result
}

private func hasBalancedSquareBrackets(in value: String) -> Bool {
    var depth = 0
    var isInsideString = false
    var isEscaping = false

    for character in value {
        if isInsideString {
            if isEscaping {
                isEscaping = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                continue
            }
            if character == "\"" {
                isInsideString = false
            }
            continue
        }

        if character == "\"" {
            isInsideString = true
            continue
        }
        if character == "[" {
            depth += 1
        } else if character == "]" {
            depth -= 1
        }
    }

    return depth == 0
}

private func parseStringArray(
    _ value: String,
    fileName: String,
    fieldName: String
) throws -> [String] {
    let trimmed = value.trimmed
    guard trimmed.hasPrefix("["),
          trimmed.hasSuffix("]")
    else {
        throw AppConfigError.invalidFile(
            fileName: fileName,
            reason: "\(fieldName) must be an array of strings."
        )
    }

    var items: [String] = []
    var index = trimmed.index(after: trimmed.startIndex)
    let endIndex = trimmed.index(before: trimmed.endIndex)

    while index < endIndex {
        while index < endIndex, trimmed[index].isWhitespace {
            index = trimmed.index(after: index)
        }
        if index >= endIndex { break }
        if trimmed[index] == "," {
            index = trimmed.index(after: index)
            continue
        }
        guard trimmed[index] == "\"" else {
            throw AppConfigError.invalidFile(
                fileName: fileName,
                reason: "\(fieldName) only supports quoted string entries."
            )
        }

        let (item, nextIndex) = try parseBasicString(
            in: trimmed,
            from: index,
            fileName: fileName,
            fieldName: fieldName
        )
        items.append(item)
        index = nextIndex

        while index < endIndex, trimmed[index].isWhitespace {
            index = trimmed.index(after: index)
        }
        if index < endIndex, trimmed[index] == "," {
            index = trimmed.index(after: index)
        }
    }

    return items
}

private func parseBasicString(
    _ value: String,
    fileName: String,
    fieldName: String
) throws -> String {
    let trimmed = value.trimmed
    let (parsed, nextIndex) = try parseBasicString(
        in: trimmed,
        from: trimmed.startIndex,
        fileName: fileName,
        fieldName: fieldName
    )

    let trailing = String(trimmed[nextIndex ..< trimmed.endIndex]).trimmed
    guard trailing.isEmpty else {
        throw AppConfigError.invalidFile(
            fileName: fileName,
            reason: "Unexpected trailing content after \(fieldName)."
        )
    }

    return parsed
}

private func parseBasicString(
    in text: String,
    from startIndex: String.Index,
    fileName: String,
    fieldName: String
) throws -> (String, String.Index) {
    guard startIndex < text.endIndex,
          text[startIndex] == "\""
    else {
        throw AppConfigError.invalidFile(
            fileName: fileName,
            reason: "\(fieldName) must be a quoted string."
        )
    }

    var index = text.index(after: startIndex)
    var output = ""

    while index < text.endIndex {
        let character = text[index]
        if character == "\"" {
            return (output, text.index(after: index))
        }

        if character == "\\" {
            index = text.index(after: index)
            guard index < text.endIndex else {
                throw AppConfigError.invalidFile(
                    fileName: fileName,
                    reason: "Invalid escape sequence in \(fieldName)."
                )
            }

            switch text[index] {
            case "\"":
                output.append("\"")
            case "\\":
                output.append("\\")
            case "n":
                output.append("\n")
            case "r":
                output.append("\r")
            case "t":
                output.append("\t")
            default:
                throw AppConfigError.invalidFile(
                    fileName: fileName,
                    reason: "Unsupported escape sequence in \(fieldName)."
                )
            }
        } else {
            output.append(character)
        }

        index = text.index(after: index)
    }

    throw AppConfigError.invalidFile(
        fileName: fileName,
        reason: "Unterminated quoted string in \(fieldName)."
    )
}
