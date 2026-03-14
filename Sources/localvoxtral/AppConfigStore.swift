import Foundation

protocol AppConfigServing {
    func configDirectoryURL() -> URL
    func loadReplacementDictionary() -> ReplacementDictionary
    func loadLLMPromptTemplates() -> LLMPromptTemplates
}

struct ReplacementEntry: Equatable, Sendable {
    let replaceWith: String
    let matches: [String]
}

struct ReplacementDictionary: Equatable, Sendable {
    let entries: [ReplacementEntry]

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
                            sortLength: -normalized.count,
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

struct LLMPromptTemplates: Equatable, Sendable {
    let systemContent: String
    let userContent: String

    private static let requiredUserPlaceholders = ["{{input_text}}"]
    private static let optionalUserPlaceholders = ["{{replacement_dictionary}}"]
    private static let userPromptPlaceholderPattern = #"\{\{[a-zA-Z0-9_]+\}\}"#
    private static let splitPlaceholders = ["{{replacement_dictionary}}", "{{input_text}}"]

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
        template
            .replacingOccurrences(of: "{{input_text}}", with: inputText)
            .replacingOccurrences(of: "{{replacement_dictionary}}", with: replacementDictionary)
    }

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
    let sortLength: Int
    let originalOrder: Int

    static func < (lhs: ReplacementPriority, rhs: ReplacementPriority) -> Bool {
        if lhs.sortLength != rhs.sortLength {
            return lhs.sortLength < rhs.sortLength
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

        var fileName: String {
            switch self {
            case .replacementDictionary:
                return "replacement_dictionary.toml"
            case .llmSystemPrompt:
                return "llm_system_prompt.toml"
            case .llmUserPrompt:
                return "llm_user_prompt.toml"
            }
        }

        var resourceName: String {
            fileName.replacingOccurrences(of: ".toml", with: "")
        }
    }

    private let fileManager: FileManager
    private let bundle: Bundle
    private let configDirectoryOverride: URL?

    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .module,
        configDirectoryOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.configDirectoryOverride = configDirectoryOverride
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
