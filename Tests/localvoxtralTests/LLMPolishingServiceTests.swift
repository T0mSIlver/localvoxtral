import Foundation
import XCTest
@testable import localvoxtral

final class LLMPolishingServiceTests: XCTestCase {
    private let request = LLMPolishingRequest(
        inputText: "hello",
        systemPrompt: "system",
        userPrompts: ["first", "second"]
    )

    func testNilSamplingDefaultsKeepLegacyRequestBytesIdentical() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1/chat")!,
            apiKey: "",
            model: "model",
            samplingDefaults: nil
        )
        let bytes = try LLMPolishingService.requestBody(
            request: request,
            configuration: configuration
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )

        // JSONSerialization does not guarantee dictionary key order, so raw
        // bytes from two independent serialization calls are not comparable.
        // Pin the exact legacy wire object and prove no override key was added.
        XCTAssertEqual(Set(json.keys), ["model", "messages", "temperature"])
        XCTAssertEqual(json["model"] as? String, "model")
        XCTAssertEqual(json["temperature"] as? Double, 0.3)
        XCTAssertEqual(
            json["messages"] as? [[String: String]],
            [
                ["role": "system", "content": "system"],
                ["role": "user", "content": "first"],
                ["role": "user", "content": "second"],
            ]
        )
        XCTAssertNil(json["chat_template_kwargs"])
    }

    func testSamplingDefaultsEmitExactOpenAIFieldNames() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1/chat")!,
            apiKey: "",
            model: "model",
            samplingDefaults: PolishSamplingDefaults(
                temperature: 1.0,
                topP: 0.9,
                topK: 20,
                minP: 0.1,
                presencePenalty: 2.0
            )
        )

        let data = try LLMPolishingService.requestBody(
            request: request,
            configuration: configuration
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["temperature"] as? Double, 1.0)
        XCTAssertEqual(json["top_p"] as? Double, 0.9)
        XCTAssertEqual(json["top_k"] as? Int, 20)
        XCTAssertEqual(json["min_p"] as? Double, 0.1)
        XCTAssertEqual(json["presence_penalty"] as? Double, 2.0)
        XCTAssertNil(json["topP"])
        XCTAssertNil(json["topK"])
        XCTAssertNil(json["minP"])
        XCTAssertNil(json["presencePenalty"])
    }

    func testChatTemplateArgumentsEmitMlxLmFieldName() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1/chat")!,
            apiKey: "",
            model: "model",
            chatTemplateArguments: ["enable_thinking": false]
        )

        let data = try LLMPolishingService.requestBody(
            request: request,
            configuration: configuration
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let kwargs = try XCTUnwrap(json["chat_template_kwargs"] as? [String: Bool])

        XCTAssertEqual(kwargs, ["enable_thinking": false])
        XCTAssertNil(json["chatTemplateArguments"])
    }
}
