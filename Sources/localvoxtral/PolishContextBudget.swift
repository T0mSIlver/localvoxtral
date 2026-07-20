import Foundation

/// A kind of dynamic reference context that can be attached to a polish
/// request. Only `.clipboard` is wired today; the other cases exist so the
/// budget, the excerpt selector, and the cross-source grounding merge are
/// written once against a general type rather than being retrofitted when the
/// terminal / Claude / repo sources land.
///
/// Declaration order IS the allocation order: it decides who wins the odd
/// leftover character when a water-fill round cannot be split evenly, and
/// which source keeps a term two sources agree on. Reordering these cases
/// changes rendered output — treat the order as behavior, not cosmetics.
/// Earliest = most trusted for grounding provenance (the repo the speaker is
/// working in beats what happens to be on their clipboard).
enum PolishContextSource: String, CaseIterable, Sendable, Hashable {
    case repository
    case terminal
    case claude
    case clipboard

    /// Position in the fixed allocation order (declaration order).
    var allocationRank: Int {
        PolishContextSource.allCases.firstIndex(of: self) ?? 0
    }
}

/// Deterministic character budget shared by every dynamic polish-context
/// source. Context rides inside the final (uncached) user message, so its size
/// is paid on EVERY polish request in prefill — an unbounded context is a
/// direct latency regression on a local 4B model. This type is the single
/// place that decides how many characters each source may render.
///
/// Pure and synchronous: no I/O, no actor, no clock. The allocation is a
/// function of the demands alone, so a given set of demands always produces
/// the same split.
enum PolishContextBudget {
    /// Total characters ALL context sources may render into one polish
    /// request, combined.
    ///
    /// PROVISIONAL — 6000 characters is roughly 1.5k tokens of context on top
    /// of the cached prompt prefix, chosen conservatively: it comfortably
    /// holds the copied error message / file listing / diff hunk that motivates
    /// the feature, while staying far below the point where prefill on the
    /// bundled 4B model threatens the polish client timeout. It is NOT an
    /// eval-derived number. The agent-dictation E2E eval
    /// (`AgentDictationE2EEvalTests`) is the instrument that should set it:
    /// when a run shows grounding recall still climbing at the cap, or shows
    /// latency headroom, calibrate this constant and paste the paired
    /// scoreboard in the PR. Change it HERE — no source hardcodes its own cap.
    static let totalCharacterBudget = 6000

    /// Characters a populated source is guaranteed before any other source may
    /// take a second helping. Without a floor, one large source (a 90k-char
    /// clipboard) would swallow the whole budget on demand order alone and a
    /// small, highly relevant source (a 300-char terminal tail) would render
    /// nothing. 400 characters is a few lines — enough for a floor to still
    /// carry the entity that made the source worth attaching.
    static let sourceFloorCharacters = 400

    /// The per-source character caps for `demands`, honoring these invariants:
    ///
    /// - **Never over total**: the granted characters sum to at most `total`.
    /// - **Never over demand**: no source is granted more than it asked for, so
    ///   a source that fits is never told to render padding.
    /// - **Unpopulated stays unpopulated**: a source with a demand of zero (or
    ///   absent, or negative) is granted zero and is never given a floor.
    /// - **Everything fits ⇒ everyone wins**: when the demands sum to at most
    ///   `total`, every source is granted its FULL demand (this is the common
    ///   case — a short clipboard is attached verbatim).
    /// - **Deterministic**: same demands in, same allocation out, regardless of
    ///   dictionary iteration order.
    ///
    /// On overflow: every populated source first takes its floor
    /// (`min(demand, sourceFloorCharacters)`) in `allocationRank` order, then
    /// the remainder is water-filled — repeated equal shares among the sources
    /// still short of their demand, so the space a nearly-satisfied source
    /// cannot use flows to the ones that can, instead of being lost. When the
    /// floors alone exceed `total`, earlier ranks take their floor and later
    /// ranks get what is left (possibly nothing): a deliberate, documented
    /// preference for the more trusted source over an even split that would
    /// leave every source below a useful size.
    static func allocate(
        demands: [PolishContextSource: Int],
        total: Int = totalCharacterBudget
    ) -> [PolishContextSource: Int] {
        allocate(
            demands: demands,
            order: PolishContextSource.allCases,
            floor: sourceFloorCharacters,
            total: total
        )
    }

    /// The same allocation, over any ranked key.
    ///
    /// Generic because the repository source has to solve this problem a second
    /// time INSIDE its own grant: active files, diff hunks, status, and tracked
    /// snippets compete for the characters `.repository` won, under exactly the
    /// invariants above (fits ⇒ verbatim; on overflow, floors then water-fill;
    /// deterministic). That is the same function, not a similar one — and a
    /// second copy would be a second place for the odd-leftover-character rule
    /// and the floors-exceed-total case to drift.
    ///
    /// - Parameter order: the allocation order. Position in this array is the
    ///   rank, so it decides who wins the odd leftover character and who keeps
    ///   its floor when the floors alone exceed `total`. A key absent from
    ///   `order` is dropped: an unranked key has no defined place in a
    ///   deterministic split.
    static func allocate<Key: Hashable>(
        demands: [Key: Int],
        order: [Key],
        floor: Int,
        total: Int
    ) -> [Key: Int] {
        // Clamp first: a negative demand is a caller bug, not a credit.
        var demand: [Key: Int] = [:]
        for key in order {
            let value = max(0, demands[key] ?? 0)
            if value > 0 { demand[key] = value }
        }
        guard total > 0, !demand.isEmpty else { return [:] }

        // Fixed order — never dictionary order, which is not deterministic
        // across runs.
        let populated = order.filter { demand[$0] != nil }

        let totalDemand = populated.reduce(0) { $0 + demand[$1]! }
        if totalDemand <= total {
            return demand
        }

        var granted: [Key: Int] = [:]
        var remaining = total
        for source in populated {
            let floorGrant = min(demand[source]!, floor, remaining)
            granted[source] = floorGrant
            remaining -= floorGrant
        }

        while remaining > 0 {
            let hungry = populated.filter { granted[$0]! < demand[$0]! }
            guard !hungry.isEmpty else { break }
            if remaining < hungry.count {
                // Fewer characters than claimants: hand them out one apiece in
                // rank order rather than looping forever on a zero share.
                for source in hungry.prefix(remaining) {
                    granted[source]! += 1
                }
                remaining = 0
                break
            }
            let share = remaining / hungry.count
            for source in hungry {
                let grant = min(share, demand[source]! - granted[source]!)
                granted[source]! += grant
                remaining -= grant
            }
        }

        return granted.filter { $0.value > 0 }
    }
}

/// Assembles the dynamic context block into the polish request's user
/// messages. Extracted as a pure function because its ONE hard requirement is
/// invisible at the call site: it must not disturb the prompt-cache prefix.
enum PolishContextComposer {
    /// Prepends `contextMessage` to the LAST user message, returning the new
    /// messages.
    ///
    /// Two constraints are encoded here, both learned the hard way:
    ///
    /// 1. **Inside the last message, never a new message.** polishd checkpoints
    ///    ALL-BUT-LAST messages as its single-slot prefix cache. A separate
    ///    context message between the cached prefix and the suffix invalidates
    ///    that checkpoint on every request, and the resulting cold 4B re-prefill
    ///    blew the polish client timeout in the field (2026-07-11). Every
    ///    message before the last must come out byte-identical.
    /// 2. **Prepended, never appended.** The transcript must stay LAST in the
    ///    final message — this model family echoes instructions placed after
    ///    the input text back into its output.
    ///
    /// An empty context message, or an empty message list, is a no-op.
    static func prepending(contextMessage: String, to userPrompts: [String]) -> [String] {
        guard !contextMessage.isEmpty, let lastIndex = userPrompts.indices.last else {
            return userPrompts
        }
        var updated = userPrompts
        updated[lastIndex] = contextMessage + "\n\n" + updated[lastIndex]
        return updated
    }
}
