import XCTest
@testable import localvoxtralCore

/// The code shapes an agent's proposed terms are dropped for (#914), and the
/// names that look like code but are said aloud.
final class SpokenTermShapeTests: XCTestCase {
    func testCodeShapesAreIdentifiers() {
        let cases: [(String, SpokenTermShape.Identifier)] = [
            ("LV_BUILD_DIR", .underscore),
            ("load_tokenizer", .underscore),
            ("HF_TOKEN", .underscore),
            ("__init__", .underscore),
            ("nextChunk", .camelCase),
            ("localvoxtralTestSupport", .camelCase),
            ("frontierTable", .camelCase),
            ("ManualSessionClock", .typeName),
            ("POSIXPipeRead", .typeName),
            ("PolishHelper", .typeName),
            ("RunConfig", .typeName),
            ("ToklenError", .typeName),
            ("DictationPipelineTests", .typeName),
            ("remote-build.sh", .fileName),
            ("pyproject.toml", .fileName),
            ("README.md", .fileName),
            ("node.js", .fileName),
            (".env", .fileName),
            ("Log.backends", .memberPath),
            ("os.path", .memberPath),
            ("src/app", .path),
            ("@huggingface/tokenizers", .codeSyntax),
            ("Qwen/Qwen3.8-27B", .path),
            ("--max-turns", .flag),
            ("-p", .flag),
            ("nextChunk(fromDescriptor:)", .codeSyntax),
            ("$HOME", .codeSyntax),
            ("@MainActor", .codeSyntax),
            ("std::vector", .codeSyntax),
            ("Array<T>", .codeSyntax),
            ("the nextChunk call", .camelCase),
        ]
        for (term, shape) in cases {
            XCTAssertEqual(SpokenTermShape.identifier(in: term), shape, term)
        }
    }

    func testNamesThatLookLikeCodeAreNames() {
        let names = [
            // Named in #914.
            "GitHub", "gpt-6", "mlx-audio-swift",
            // Capitals inside a word.
            "macOS", "iOS", "iPadOS", "iPhone", "iTerm2", "eBay", "vLLM", "xAI", "gRPC", "cuDNN", "nanoGPT",
            "ChatGPT", "OpenAI", "DeepSeek", "PyTorch", "HuggingFace", "WebSocket", "SwiftPM", "SwiftUI",
            "PostgreSQL", "LangChain", "OpenRouter", "WhisperKit", "ScreenCaptureKit", "XCTest",
            // Stylized model and method names.
            "LLaMA", "QLoRA", "RoBERTa", "LaTeX", "MoE", "YaRN", "NVFP4", "DeepSeekMoE", "SmolVLM",
            // Versions and dots.
            "GLM-5.3", "Qwen3.6-35B-A3B", "DeepSeek-V4.1-Flash", "Node.js", "Next.js", "llama.cpp",
            "claude.ai", "Socket.IO", "ASP.NET", ".NET", "v0.dev",
            // Punctuation names keep.
            "C++", "C#", "Objective-C", "CI/CD", "I/O", "AT&T",
            // Several words, and plain ones.
            "Claude Code", "LM Studio", "Simon Willison", "Glyph Atlas", "herdr", "localvoxtral-speechd",
            "sentence-transformers", "Qwen3:8b",
            // From the corpus: names an earlier filter dropped.
            "FastContext", "DeepFilterNet", "arXiv", "docs.mistral.ai", "Q4_K_M", "IQ4_XS",
        ]
        for name in names {
            XCTAssertNil(SpokenTermShape.identifier(in: name), name)
        }
    }

    func testCapitalizedWordsIgnoreStylizedHumps() {
        XCTAssertEqual(SpokenTermShape.capitalizedWords(in: "POSIXPipeRead"), ["POSIX", "Pipe", "Read"])
        XCTAssertEqual(SpokenTermShape.capitalizedWords(in: "LLaMA"), ["MA"])
        XCTAssertEqual(SpokenTermShape.capitalizedWords(in: "OpenAI"), ["Open", "AI"])
        XCTAssertEqual(SpokenTermShape.capitalizedWords(in: "Qwen3Coder"), ["Qwen", "Coder"])
    }
}
