# Vendored: mlx-audio-swift VoxtralRealtime

`Sources/SpeechEngine/` is vendored from
[`Blaizzy/mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift), MIT-licensed
(see `LICENSE.mlx-audio-swift`).

- Upstream commit: `d302a5c6080d2bb97bae38c7418f82abb76013b6` (tag `v0.1.3`, `main` at
  vendoring time — the `Models/VoxtralRealtime/` tree is identical between the two).
- Files taken verbatim then modified: `Models/VoxtralRealtime/*.swift`, plus
  `Generation.swift` and `Models/GLMASR/STTOutput.swift` (the `STT*` protocol types the
  engine references).

## Why vendor instead of depend

The engine needed correctness/performance fixes that we want landing on our schedule, and
we hold it to our own regression tests (notably the append-only delta contract, which our
no-backspace insertion path depends on). We are proposing the performance fix upstream; if
it lands we can revisit depending on a release.

## Local modifications (all marked `LOCAL FIX` in the source)

1. **float32 leak fix (performance, ~3x).** The decoder ran in float32 because the
   time-conditioning scale (`AdaptiveNorm`) and the manual RoPE built their factors in
   float32 and promoted the fp16 hidden state. That forced the tied fp16 embedding
   (131072x3072) to be upcast on every token and pushed quantized matmuls off their fast
   path. Fixes: cast the adaScale to the activation dtype; make the manual RoPE
   dtype-preserving; cast the float32 mel to the conv weight dtype at the conv-stem seam.
   Measured downstream (see PR #141 / the `spike/voxtral-swift` branch): RTF 1.84 -> 0.62
   at identical word accuracy, reaching parity with the Python voxmlx backend.
2. **append-only delta contract.** Delta computation is routed through
   `SpeechEngineText.StreamingDelta`, which holds back a trailing U+FFFD from a split
   multi-byte character instead of re-emitting the whole transcript. Guards duplication on
   the no-backspace insertion path (regression tests in `SpeechEngineTextTests`).

## Updating

Re-copy the files from a newer upstream commit, then re-apply the `LOCAL FIX` blocks
(diff against this note). Record the new commit hash above.
