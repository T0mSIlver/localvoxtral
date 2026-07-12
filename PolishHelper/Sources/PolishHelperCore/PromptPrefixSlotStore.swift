import Foundation

/// Fixed-capacity LRU store for prompt-prefix checkpoints, keyed EXACTLY the
/// way the single-slot cache was: the templated prefix tokens plus the
/// chat-template kwargs (a kwargs change re-templates the prefix, so it must
/// never reuse another variant's KV state). Generic over the stored state so
/// it is pure Swift — unit-testable without Metal; `MLXPolishModel` stores
/// `[KVCache]` in it and touches it only inside `container.perform`, which
/// serializes all access.
///
/// Why LRU with a small capacity: the app is growing a second prompt profile
/// (standard vs agent). With one slot, every profile alternation threw away
/// the checkpoint and re-prefilled the full prefix; with one slot per
/// profile both stay warm. Capacity stays small because each slot holds real
/// KV memory (the 4B: ~48 MiB of constant linear-attention state plus
/// ~32 KiB per prefix token of full-attention KV).
public struct PromptPrefixSlotStore<State> {
    public struct Key: Equatable {
        public let prefixTokens: [Int]
        public let chatTemplateArguments: [String: ChatTemplateArgumentValue]?

        public init(
            prefixTokens: [Int],
            chatTemplateArguments: [String: ChatTemplateArgumentValue]?
        ) {
            self.prefixTokens = prefixTokens
            self.chatTemplateArguments = chatTemplateArguments
        }
    }

    public struct Counters: Equatable, Sendable {
        public var hits = 0
        public var misses = 0
        public var evictions = 0

        public init() {}
    }

    private struct Slot {
        let key: Key
        let state: State
        var lastUse: UInt64
    }

    public let capacity: Int
    public private(set) var counters = Counters()
    private var slots: [Slot] = []
    /// Monotonic use clock for LRU ordering (no wall-clock involved).
    private var useClock: UInt64 = 0

    public init(capacity: Int) {
        precondition(capacity >= 1, "prompt cache needs at least one slot")
        self.capacity = capacity
    }

    public var count: Int { slots.count }

    /// The stored state for the exact key, marking the slot most recently
    /// used and counting a hit; nil counts a miss.
    public mutating func lookup(_ key: Key) -> State? {
        useClock += 1
        guard let index = slots.firstIndex(where: { $0.key == key }) else {
            counters.misses += 1
            return nil
        }
        slots[index].lastUse = useClock
        counters.hits += 1
        return slots[index].state
    }

    /// Inserts the state for the key (replacing in place when the key is
    /// already present), evicting the least recently used slot when at
    /// capacity. Returns whether an eviction happened.
    @discardableResult
    public mutating func store(_ key: Key, state: State) -> Bool {
        useClock += 1
        if let index = slots.firstIndex(where: { $0.key == key }) {
            slots[index] = Slot(key: key, state: state, lastUse: useClock)
            return false
        }
        var evicted = false
        if slots.count >= capacity,
            let lruIndex = slots.indices.min(by: { slots[$0].lastUse < slots[$1].lastUse })
        {
            slots.remove(at: lruIndex)
            counters.evictions += 1
            evicted = true
        }
        slots.append(Slot(key: key, state: state, lastUse: useClock))
        return evicted
    }
}
