import Hub
import Tokenizers
import XCTest

@testable import PolishHelperCore

final class ChatTemplateKwargsTokenizerTests: XCTestCase {
    private let messages: [[String: any Sendable]] = [
        ["role": "system", "content": "instructions"],
        ["role": "user", "content": "raw"],
    ]

    func testInlineTemplateBranchesOnEnableThinkingKwarg() throws {
        let tokenizer = try makeTokenizer()

        let thinkingTokens = try tokenizer.applyChatTemplate(
            messages: [messages[1]],
            tools: nil,
            additionalContext: ["enable_thinking": true]
        )
        let directTokens = try tokenizer.applyChatTemplate(
            messages: [messages[1]],
            tools: nil,
            additionalContext: ["enable_thinking": false]
        )

        XCTAssertEqual(tokenizer.decode(tokenIds: thinkingTokens, skipSpecialTokens: false), "userrawthinkassistant")
        XCTAssertEqual(tokenizer.decode(tokenIds: directTokens, skipSpecialTokens: false), "userrawdirectassistant")
    }

    func testPrefixAndFullPromptUseMatchingKwargsForStrictTokenPrefix() throws {
        let tokenizer = try makeTokenizer()
        let kwargs: [String: any Sendable] = ["enable_thinking": false]

        let fullTokens = try tokenizer.applyChatTemplate(
            messages: messages,
            tools: nil,
            additionalContext: kwargs
        )
        let prefixTokens = try tokenizer.encodeChatPrefix(
            messages: [messages[0]],
            additionalContext: kwargs
        )

        XCTAssertTrue(fullTokens.starts(with: prefixTokens))
        XCTAssertEqual(
            PromptPrefixPlan.plan(fullTokens: fullTokens, cachedPrefixTokens: prefixTokens),
            .reusePrefix(suffixTokens: Array(fullTokens.dropFirst(prefixTokens.count)))
        )
        XCTAssertEqual(
            tokenizer.decode(tokenIds: prefixTokens, skipSpecialTokens: false),
            "systeminstructions"
        )
        XCTAssertEqual(
            tokenizer.decode(tokenIds: fullTokens, skipSpecialTokens: false),
            "systeminstructionsuserrawdirectassistant"
        )
    }

    private func makeTokenizer() throws -> TokenizerBridge {
        let template =
            """
            {% for message in messages %}{{ message['role'] }} {{ message['content'] }} {% endfor %}{% if add_generation_prompt %}{% if enable_thinking %}think {% else %}direct {% endif %}assistant{% endif %}
            """
        let vocabulary = [
            "[UNK]": 0,
            "system": 1,
            "user": 2,
            "assistant": 3,
            "instructions": 4,
            "raw": 5,
            "think": 6,
            "direct": 7,
        ]
        let tokenizerConfig = Config([
            "tokenizer_class": Config("BertTokenizer"),
            "chat_template": Config(template),
            "do_lower_case": Config(false),
        ])
        let vocabConfig = vocabulary.reduce(into: [String: Config]()) { partialResult, entry in
            partialResult[entry.key] = Config(entry.value)
        }
        let tokenizerData = Config([
            "model": Config([
                "vocab": Config(vocabConfig),
            ]),
            "added_tokens": Config([Config]()),
        ])

        let upstream = try PreTrainedTokenizer(
            tokenizerConfig: tokenizerConfig,
            tokenizerData: tokenizerData
        )
        return TokenizerBridge(upstream)
    }
}
