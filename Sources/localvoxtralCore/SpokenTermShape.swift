import Foundation

/// Whether a proposed term is shaped like code rather than like a name
/// someone says aloud. The people who dictate to coding agents say model,
/// product, tool, repository and people names, rarely an identifier, and
/// never an environment variable, a file name or a flag (owner, 2026-09-27).
/// A coding agent asked for a project's terms lists those anyway, so its
/// answer passes through here after the prompt asks it not to.
///
/// Deterministic and conservative: a shape counts only when names are rarely
/// written that way. Product names that look like code (`GitHub`, `macOS`,
/// `vLLM`, `Node.js`, `llama.cpp`, `mlx-audio-swift`) pass.
package enum SpokenTermShape {
    package enum Identifier: String, Sendable, Equatable {
        /// `LV_BUILD_DIR`, `load_tokenizer`, `__init__`.
        case underscore
        /// `nextChunk`, `localvoxtralCore`.
        case camelCase
        /// `ManualSessionClock`, `PolishHelper`: three or more capitalized
        /// words, or two ending in a word types end in.
        case typeName
        /// `remote-build.sh`, `pyproject.toml`.
        case fileName
        /// `Log.backends`, `os.path`.
        case memberPath
        /// `src/app`, `@huggingface/tokenizers`.
        case path
        /// `--max-turns`, `-p`.
        case flag
        /// `nextChunk(fromDescriptor:)`, `$HOME`, `@MainActor`, `<T>`.
        case codeSyntax
    }

    /// The first code shape any word of `term` has, or nil for a name.
    package static func identifier(in term: String) -> Identifier? {
        if allowed.contains(term.lowercased()) { return nil }
        for word in term.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let shape = identifier(inWord: word) { return shape }
        }
        return nil
    }

    private static func identifier(inWord word: String) -> Identifier? {
        if allowed.contains(word.lowercased()) { return nil }
        if word.hasPrefix("-") { return .flag }
        if word.hasPrefix("@") || word.hasPrefix("#") || word.hasPrefix("$") || word.contains("::")
            || word.contains(where: { codeCharacters.contains($0) })
        {
            return .codeSyntax
        }
        if word.contains("/") || word.contains("\\") {
            // CI/CD, I/O, TCP/IP are said aloud.
            let parts = word.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            return parts.allSatisfy({ $0.allSatisfy(\.isUppercase) }) && parts.count > 1 ? nil : .path
        }
        if word.contains("_"), !isQuantizationName(word) { return .underscore }
        if word.contains(".") {
            if let shape = dottedIdentifier(word) { return shape }
        }
        for part in word.split(separator: "-").map(String.init) {
            if let shape = casedIdentifier(part) { return shape }
        }
        return nil
    }

    private static func dottedIdentifier(_ word: String) -> Identifier? {
        let segments = word.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count > 1, let last = segments.last, let first = segments.first, !last.isEmpty
        else { return nil }
        // `.env`, `.gitignore`; `.NET` is a name.
        if first.isEmpty { return segments.count == 2 && last.allSatisfy(\.isLowercase) ? .fileName : nil }
        let lastLower = last.lowercased()
        if fileExtensions.contains(lastLower) {
            // Node.js, Next.js, Three.js: a capitalized name before `.js`.
            if lastLower == "js", segments.count == 2, first.first?.isUppercase == true { return nil }
            return .fileName
        }
        // docs.mistral.ai, fly.io: a site.
        if webSuffixes.contains(last) { return nil }
        let identifierLike = segments.allSatisfy { segment in
            guard let head = segment.first, head.isLetter else { return false }
            return segment.allSatisfy { $0.isLetter || $0.isNumber }
        }
        guard identifierLike else { return nil }
        let member = segments.dropFirst().contains { segment in
            segment.first?.isLowercase == true && !webSuffixes.contains(segment)
        }
        return member ? .memberPath : nil
    }

    private static func casedIdentifier(_ part: String) -> Identifier? {
        let letters = part.filter(\.isLetter)
        guard let head = letters.first, letters.contains(where: \.isUppercase),
              letters.contains(where: \.isLowercase)
        else { return nil }
        if head.isLowercase {
            // iPhone, iTerm2, eBay, vLLM, xAI: one lowercase letter first.
            if let second = part.dropFirst().first, second.isUppercase { return nil }
            // macOS, gRPC, cuDNN, nanoGPT: lowercase, then only capitals.
            let tail = part.drop(while: \.isLowercase)
            if tail.allSatisfy({ $0.isUppercase || $0.isNumber }) { return nil }
            return .camelCase
        }
        let words = capitalizedWords(in: part)
        // ScreenCaptureKit, DeepFilterNet: frameworks and model families are
        // said by name.
        if words.count >= 3, let lastWord = words.last, !namedFamilies.contains(lastWord) { return .typeName }
        if words.count == 2, let lastWord = words.last, typeSuffixes.contains(lastWord) { return .typeName }
        return nil
    }

    /// The words a PascalCase part is made of: capitalized runs of three
    /// letters or more, and acronyms of two capitals or more. Stylized short
    /// humps (the `La` of `LLaMA`, the `Mo` of `MoE`) do not count, so model
    /// names stay one word.
    static func capitalizedWords(in part: String) -> [String] {
        var words: [String] = []
        let characters = Array(part)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character.isUppercase else {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count, characters[end].isUppercase { end += 1 }
            if end - index > 1 {
                // An acronym, minus the capital that starts the next word.
                let acronymEnd = end < characters.count && characters[end].isLowercase ? end - 1 : end
                if acronymEnd - index >= 2 { words.append(String(characters[index..<acronymEnd])) }
                index = acronymEnd
                continue
            }
            while end < characters.count, characters[end].isLowercase { end += 1 }
            if end - index >= 3 { words.append(String(characters[index..<end])) }
            index = end
        }
        return words
    }

    /// `Q4_K_M`, `IQ4_XS`, `Q8_0`: a GGUF quantization, said letter by
    /// letter. Short capital segments with a digit, unlike `LV_BUILD_DIR`.
    private static func isQuantizationName(_ word: String) -> Bool {
        let segments = word.split(separator: "_", omittingEmptySubsequences: false)
        return segments.allSatisfy { !$0.isEmpty && $0.count <= 3 && !$0.contains(where: \.isLowercase) }
            && segments.contains { $0.contains(where: \.isNumber) }
    }

    private static let namedFamilies: Set<String> = ["Kit", "Net"]

    private static let codeCharacters: Set<Character> = ["(", ")", "[", "]", "{", "}", "<", ">", "=", "`", ";", "|", "\"", "*"]

    /// Names that look like code but are said aloud as they are written.
    private static let allowed: Set<String> = [
        "llama.cpp", "whisper.cpp", "stable-diffusion.cpp", "xctest", "googletest", "openstreetmap", "arxiv",
    ]

    /// Two capitalized words ending in one of these name a type, not a
    /// product: `PolishHelper`, `RunConfig`, `ToklenError`.
    private static let typeSuffixes: Set<String> = [
        "Test", "Tests", "Spec", "Specs", "View", "Views", "Controller", "Manager", "Helper", "Helpers",
        "Service", "Services", "Store", "Coordinator", "Handler", "Handlers", "Provider", "Factory",
        "Delegate", "Runner", "Builder", "Parser", "Error", "Errors", "Exception", "Type", "Types", "Impl",
        "Protocol", "Config", "Configuration", "Options", "Settings", "State", "Request", "Response", "Util",
        "Utils", "Kind", "Info", "Wrapper", "Adapter", "Client", "Listener", "Observer",
        "Registry", "Resolver", "Loader", "Reader", "Writer", "Formatter", "Validator", "Scheduler", "Cache",
        "Clock", "Record", "Entry", "Mock", "Stub", "Fake", "Fixture", "Suite", "Support", "Result", "Event",
        "Hook", "Hooks",
    ]

    /// After a dot, these end a product or site name (`claude.ai`,
    /// `fly.io`), not a member.
    private static let webSuffixes: Set<String> = [
        "ai", "io", "dev", "com", "org", "net", "app", "new", "so", "co", "cc", "gg", "fm", "tv", "me", "run",
        "xyz", "cloud",
    ]

    private static let fileExtensions: Set<String> = [
        "sh", "bash", "zsh", "fish", "ps1", "bat", "py", "pyi", "ipynb", "swift", "rs", "go", "js", "mjs",
        "cjs", "jsx", "ts", "tsx", "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "kts", "rb", "php",
        "cs", "lua", "pl", "scala", "dart", "ex", "exs", "erl", "hs", "zig", "nim", "vue", "svelte", "html",
        "htm", "css", "scss", "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "lock",
        "md", "mdx", "rst", "txt", "csv", "tsv", "xml", "plist", "sql", "db", "sqlite", "proto", "gradle",
        "cmake", "mk", "dockerfile", "gitignore", "log", "pem", "wasm", "onnx", "safetensors", "gguf", "bin",
        "pt", "pth", "npz", "npy", "pkl", "wav", "mp3", "png", "jpg", "jpeg", "svg", "pdf", "zip", "tar",
        "gz", "dylib", "so", "entitlements", "xcconfig", "pbxproj", "storyboard", "xib",
    ]
}
