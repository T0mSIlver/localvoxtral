import XCTest

@testable import PolishHelperCore

final class PromptPrefixPlanTests: XCTestCase {

    // MARK: - cacheablePrefix

    func testCacheablePrefixDropsOnlyTheFinalMessage() {
        let messages = [
            ChatCompletionMessage(role: "system", content: "polish transcripts"),
            ChatCompletionMessage(role: "user", content: "instructions"),
            ChatCompletionMessage(role: "user", content: "the transcript"),
        ]
        XCTAssertEqual(
            PromptPrefixPlan.cacheablePrefix(of: messages),
            Array(messages.dropLast())
        )
    }

    func testCacheablePrefixWithSystemPlusSingleUserCachesTheSystemMessage() {
        let messages = [
            ChatCompletionMessage(role: "system", content: "polish transcripts"),
            ChatCompletionMessage(role: "user", content: "the transcript"),
        ]
        XCTAssertEqual(PromptPrefixPlan.cacheablePrefix(of: messages), [messages[0]])
    }

    func testCacheablePrefixIsNilWhenNothingStableExists() {
        XCTAssertNil(PromptPrefixPlan.cacheablePrefix(of: []))
        XCTAssertNil(
            PromptPrefixPlan.cacheablePrefix(of: [
                ChatCompletionMessage(role: "user", content: "the transcript")
            ])
        )
    }

    // MARK: - plan

    func testPlanReusesStrictPrefixAndReturnsTheSuffix() {
        XCTAssertEqual(
            PromptPrefixPlan.plan(fullTokens: [1, 2, 3, 4, 5], cachedPrefixTokens: [1, 2, 3]),
            .reusePrefix(suffixTokens: [4, 5])
        )
    }

    func testPlanRejectsNonPrefixTokens() {
        XCTAssertEqual(
            PromptPrefixPlan.plan(fullTokens: [1, 2, 3, 4, 5], cachedPrefixTokens: [1, 9, 3]),
            .fullPrefill
        )
    }

    func testPlanRejectsPrefixEqualToFullPrompt() {
        // Generation needs at least one fresh token to prefill, so an exact
        // match cannot be served from the checkpoint.
        XCTAssertEqual(
            PromptPrefixPlan.plan(fullTokens: [1, 2, 3], cachedPrefixTokens: [1, 2, 3]),
            .fullPrefill
        )
    }

    func testPlanRejectsPrefixLongerThanPrompt() {
        XCTAssertEqual(
            PromptPrefixPlan.plan(fullTokens: [1, 2], cachedPrefixTokens: [1, 2, 3]),
            .fullPrefill
        )
    }

    func testPlanRejectsEmptyPrefix() {
        XCTAssertEqual(
            PromptPrefixPlan.plan(fullTokens: [1, 2, 3], cachedPrefixTokens: []),
            .fullPrefill
        )
    }
}
