import XCTest

@testable import PolishHelperCore

final class PromptPrefixSlotStoreTests: XCTestCase {
    private typealias Store = PromptPrefixSlotStore<String>
    private typealias Key = Store.Key

    private let keyA = Key(prefixTokens: [1, 2, 3], chatTemplateArguments: nil)
    private let keyB = Key(prefixTokens: [4, 5, 6], chatTemplateArguments: nil)
    private let keyC = Key(prefixTokens: [7, 8, 9], chatTemplateArguments: nil)

    func testCapacityOneReplacesLikeTheOriginalSingleSlot() {
        var store = Store(capacity: 1)

        XCTAssertNil(store.lookup(keyA))
        XCTAssertFalse(store.store(keyA, state: "A"))
        XCTAssertEqual(store.lookup(keyA), "A")

        // Storing a second prefix evicts the first — old behavior exactly.
        XCTAssertTrue(store.store(keyB, state: "B"))
        XCTAssertEqual(store.lookup(keyB), "B")
        XCTAssertNil(store.lookup(keyA))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.counters, {
            var c = Store.Counters()
            c.hits = 2
            c.misses = 2
            c.evictions = 1
            return c
        }())
    }

    func testTwoSlotsKeepBothAlternatingPrefixesWarm() {
        var store = Store(capacity: 2)

        // The motivating sequence: standard, agent, standard, agent, ...
        XCTAssertNil(store.lookup(keyA))
        store.store(keyA, state: "standard")
        XCTAssertNil(store.lookup(keyB))
        store.store(keyB, state: "agent")

        XCTAssertEqual(store.lookup(keyA), "standard")
        XCTAssertEqual(store.lookup(keyB), "agent")
        XCTAssertEqual(store.lookup(keyA), "standard")

        XCTAssertEqual(store.counters.hits, 3)
        XCTAssertEqual(store.counters.misses, 2)
        XCTAssertEqual(store.counters.evictions, 0)
        XCTAssertEqual(store.count, 2)
    }

    func testEvictionRemovesTheLeastRecentlyUsedSlot() {
        var store = Store(capacity: 2)
        store.store(keyA, state: "A")
        store.store(keyB, state: "B")

        // Touch A so B becomes least recently used.
        XCTAssertEqual(store.lookup(keyA), "A")

        XCTAssertTrue(store.store(keyC, state: "C"))
        XCTAssertEqual(store.lookup(keyA), "A", "recently used slot must survive")
        XCTAssertNil(store.lookup(keyB), "least recently used slot must be the one evicted")
        XCTAssertEqual(store.lookup(keyC), "C")
        XCTAssertEqual(store.counters.evictions, 1)
    }

    func testStoreOrderAloneMakesTheOldestSlotLRU() {
        var store = Store(capacity: 2)
        store.store(keyA, state: "A")
        store.store(keyB, state: "B")

        // No lookups: A is the least recently used by store order.
        XCTAssertTrue(store.store(keyC, state: "C"))
        XCTAssertNil(store.lookup(keyA))
        XCTAssertEqual(store.lookup(keyB), "B")
        XCTAssertEqual(store.lookup(keyC), "C")
    }

    func testKeyingIncludesChatTemplateArguments() {
        var store = Store(capacity: 2)
        let thinkingOff = Key(
            prefixTokens: [1, 2, 3],
            chatTemplateArguments: ["enable_thinking": .bool(false)]
        )
        let thinkingOn = Key(
            prefixTokens: [1, 2, 3],
            chatTemplateArguments: ["enable_thinking": .bool(true)]
        )

        store.store(thinkingOff, state: "off")

        // Same tokens, different kwargs: MUST miss — reusing another
        // template variant's KV state would corrupt output.
        XCTAssertNil(store.lookup(thinkingOn))
        XCTAssertNil(store.lookup(keyA), "nil kwargs is its own variant, distinct from any set")
        XCTAssertEqual(store.lookup(thinkingOff), "off")
    }

    func testStoringAnExistingKeyReplacesInPlaceWithoutEviction() {
        var store = Store(capacity: 2)
        store.store(keyA, state: "old")
        store.store(keyB, state: "B")

        XCTAssertFalse(store.store(keyA, state: "new"))
        XCTAssertEqual(store.lookup(keyA), "new")
        XCTAssertEqual(store.lookup(keyB), "B")
        XCTAssertEqual(store.counters.evictions, 0)
        XCTAssertEqual(store.count, 2)
    }
}
