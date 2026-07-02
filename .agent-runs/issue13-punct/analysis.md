# Issue #13 — punctuation inserted mid-word / wrong position

**Status:** NOT reproduced as a code defect in the merge / delta-boundary logic.
**Outcome:** Added 23 characterization tests (11 pure-merge + 12 view-model
event-path). No source change — the merge logic is provably not on the
reporter's code path, and the live path is append-only. Hypotheses and the
instrumentation needed to catch the real emission are below.

## The report

In **Live Auto-Paste** + **voxmlx** (Voxtral Mini 4B Realtime, 4-bit, Italian),
streaming punctuation intermittently lands at the insertion cursor instead of
the correct boundary (~1 in 10 runs):

- `sparisce.` → `sparis.ce`
- `al fondo,` → `al, fondo`

The maintainer suspected the delta-merge boundary logic.

## TL;DR of the trace

For the reporter's exact configuration, the partial-transcript path through
`DictationViewModel+RealtimeEvents.handlePartialTranscriptEvent` is
**append-only**:

```swift
pendingSegmentText.append(processedDelta)        // raw append
livePartialText   = pendingSegmentText
if isLiveAutoPasteModeEnabled {
    textInsertion.enqueueRealtimeInsertion(processedDelta)   // typed verbatim
}
```

There is **no** `TextMergingAlgorithms` overlap/boundary merge on this path.
`processedDelta` is only passed through `FirstChunkPreprocessor`, which trims
leading whitespace from the *first* chunk of the session and is a no-op for
every subsequent chunk. So whatever characters the delta stream delivers, in
the order it delivers them, is exactly what is typed.

The prime suspects named in the issue brief — `appendWithTailOverlap`,
`appendWithoutOverlap`, `shouldAvoidLeadingSpace`,
`stableWordBoundaryLength`, `normalizeTranscriptionFormatting` — are
collectively reachable only from:

- `MlxHypothesisStabilizer` (the **mlx-audio** path — out of scope, being
  removed by another agent), and
- `OverlayBufferStateMachine.mergedText` (the **overlay** display path).

Neither runs for **Live Auto-Paste + RealtimeAPI**. They therefore cannot be
the source of the reported symptom. `normalizedFinalizedSegment` /
`appendToCurrentDictationEvent` (the only boundary logic that *is* on the
RealtimeAPI path) only run on `.finalTranscript`, and a guard suppresses
re-insertion whenever live deltas were already typed — so even they cannot
splice punctuation into the live field (see "Final-transcript path" below).

## What the new tests prove

`Tests/localvoxtralTests/TextMergingAlgorithmsTests.swift` (Italian/punctuation
block) — pure-function characterization. With left-to-right inputs the helpers
produce the *correct* result every time:

| Inputs | Result |
|---|---|
| `appendWithTailOverlap("sparisce", ".")` | `sparisce.` |
| `appendWithTailOverlap("al fondo", ",")` | `al fondo,` |
| `appendWithTailOverlap("al", "fondo,")` | `al fondo,` |
| `appendWithTailOverlap("l", "'acqua")` | `l'acqua` |
| `appendWithTailOverlap("un", "'altra")` | `un'altra` |
| `appendWithTailOverlap("spari", "sparisce.")` | `sparisce.` (overlap) |
| `normalizeTranscriptionFormatting("sparisce .")` | `sparisce.` |
| `normalizeTranscriptionFormatting("al , fondo")` | `al, fondo` |
| `normalizeTranscriptionFormatting("l' acqua")` | `l'acqua` |

None of these relocate punctuation into a word.

`Tests/localvoxtralTests/RealtimeAPILivePastePunctuationTests.swift` — drives
the production `DictationViewModel.handle(event:source:)` for the RealtimeAPI
path in Live Auto-Paste and captures every chunk
`TextInsertionService` would type (via the `#if DEBUG`
`debugConfigureInsertionHooks` seam). Key results:

1. **Append-only is exact.** Deltas `["spar","isce","."]` produce
   `insertedChunks == ["spar","isce","."]` and
   `pendingSegmentText == "sparisce."`. Likewise `["al"," fondo",","]` →
   `"al fondo,"` and elisions `["l","'acqua"]` → `"l'acqua"`.
2. **Mid-word punctuation requires out-of-order delivery.** The *only* way the
   live path yields `"sparis.ce"` is feeding deltas `["sparis",".","ce"]`
   (punctuation before the rest of the word). The app types exactly what it
   receives — it does not synthesize this ordering from a well-formed stream.
   → The malformed output must originate *upstream* of the merge: in the order
   the model/backend emits tokens.
3. **`resolvedFinalizedSegment` never splices mid-word.** With pending
   `"sparisce"` and final `"sparisce."` it returns `"sparisce."`; with
   final `"."` only it returns `"sparisce ."` (space-joined, end of word);
   disjoint words space-join. Punctuation always stays at a boundary.

## Final-transcript path (a related, but different, finding)

`handleFinalTranscriptEvent` computes
`finalizedSegment = resolvedFinalizedSegment(...)` but only inserts it when no
live delta preceded it:

```swift
let hadLiveDelta = !pendingSegmentText.trimmed.isEmpty || !livePartialText.trimmed.isEmpty
...
if !hadLiveDelta, isLiveAutoPasteModeEnabled {
    textInsertion.enqueueRealtimeInsertion(finalizedSegment)
}
```

Consequence: if a trailing period is delivered **only** in the `.finalTranscript`
and never as a partial delta, it is *dropped* from the live field (the test
`testFinalTranscriptDoesNotDoubleInsertWhenLiveDeltasAlreadyInserted` locks
this in). That is a "missing trailing punctuation" behavior, **not** the
reported "mid-word punctuation" symptom, so it is characterized but not
changed here (changing it would risk double-insertion and is out of scope for
this issue).

## Why the symptom is ~1-in-10 and lands "at the insertion point"

The phrase "lands at the insertion point" is the strongest clue: in an
append-only pipeline, "the insertion point" is simply *wherever the cursor is
when the punctuation delta arrives*. The cursor sits at the end of what was
last typed. So the symptom is consistent with the punctuation delta arriving
*before* the remainder of the word has been streamed/typed. Two realistic
mechanisms (both upstream of our merge):

1. **Periodic commits split a word across two generations.** The RealtimeAPI
   client sends `input_audio_buffer.commit` every `commitIntervalSeconds`
   (`DictationViewModel+Session.restartCommitTask`, 0.1–1.0 s). If a word
   straddles a commit boundary, generation N can transcribe the head of the
   word (and the model may emit trailing punctuation to "finish" it), while
   generation N+1 transcribes the tail. The two generations' deltas are each
   internally left-to-right, but *concatenated across the commit* they read as
   `…sparis.` then `ce…`. The append-only path faithfully types that.
   Non-final commits are skipped while a generation is in progress
   (`sendCommit` checks `isGenerationInProgress`), but this does not prevent a
   word from being split at the generation boundary itself.
2. **Backend emission / Voxtral tokenization.** voxmlx/vLLM streaming may emit
   a punctuation token detached from the word in a way that, combined with
   timing of when our client receives frames, appears reordered. This is
   inherently non-deterministic (~1-in-10) and matches the report.

Mechanism (1) is the most likely and is *not* a merge bug — it is a
consequence of periodic-commit segmentation interacting with an append-only
live pipeline. A proper fix belongs at the commit/segmentation layer (e.g.,
not committing mid-word, or reconciling head/tail across generations), not in
`TextMergingAlgorithms`.

## What I did NOT change (and why)

- No edit to `TextMergingAlgorithms` — proven correct for the reported inputs
  and not on the reported path.
- No edit to `FirstChunkPreprocessor` — only touches the first chunk; cannot
  reorder mid-stream.
- No edit to `resolvedFinalizedSegment` — never splices mid-word.
- No mlx-audio files touched (concurrent removal in flight).
- No existing assertion weakened.

## Instrumentation that would catch it live

To confirm the upstream-emission hypothesis, capture (DEBUG-gated, off by
default) the raw delta sequence the RealtimeAPI client emits, in arrival order:

- In `RealtimeAPIWebSocketClient.handle(json:)` at the
  `"transcription.delta"` / `"response.audio_transcript.delta"` branch, log
  each emitted `.partialTranscript(delta)` with a monotonic sequence number
  and the current commit-generation marker (`isGenerationInProgress` toggles).
- Mirror the same log in `DictationViewModel.handlePartialTranscriptEvent`
  right before `enqueueRealtimeInsertion`, including the running
  `pendingSegmentText` length.

With that trace from a reproducing run, the `sparis.ce` case will show either
(a) a delta ordering like `sparis`, `.`, `ce` (emission/commit-split), or
(b) something else that points at the insertion layer. `LOCALVOXTRAL_DEBUG=1`
already gates `debugLog`; the additional structured delta log would slot in
behind the same flag.

## Verification

```
LV_BUILD_DIR=work/localvoxtral-issue13 ./scripts/remote-build.sh test
→ Executed 231 tests, with 0 failures (0 unexpected) in 1.504 seconds
```

Baseline was 208 tests; this branch adds 23 (11 in TextMergingAlgorithmsTests,
12 in the new RealtimeAPILivePastePunctuationTests), all green, no existing
test modified.
