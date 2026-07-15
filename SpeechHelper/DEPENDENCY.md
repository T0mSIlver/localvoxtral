# Dependency: mlx-audio-swift VoxtralRealtime

`SpeechEngine` drives [`Blaizzy/mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift)'s
VoxtralRealtime engine as an **upstream SwiftPM dependency** (product `MLXAudioSTT`, MIT-licensed).
It used to be vendored into `Sources/SpeechEngine/` with local patches; those patches were
upstreamed (see below), so we depend instead of vendor.

Attribution: the dependency ships its own `LICENSE` (MIT, © 2025 Prince Canuma) in its SwiftPM
checkout — we no longer keep a copy here.

## The pin

```
.package(
    url: "https://github.com/Blaizzy/mlx-audio-swift.git",
    revision: "3b0b114fc7d98dd000bb7f631588a172b5c61823"
)
```

Pinned to a full-SHA **revision**, not a tag, so the exact reviewed tree is reproducible and
can't move under us. `3b0b114` is the merge of
[Blaizzy/mlx-audio-swift#226](https://github.com/Blaizzy/mlx-audio-swift/pull/226)
("Fix float32 leak in VoxtralRealtime streaming"), authored by us.

## What #226 upstreamed

All four dtype-cast families that were previously our `LOCAL FIX` sites — the float32 leak
that ran the decoder in float32 and cost ~3x (RTF 1.84 → 0.62 at identical word accuracy):

- **adaScale cast** (`VoxtralRealtimeDecoder.swift`): cast the float32 time-conditioning
  scale down to the activation dtype so it doesn't promote the fp16 hidden state.
- **RoPE cos/sin cast** (`VoxtralRealtimeEncoder.swift`): cast the float32-computed rotation
  factors down before rotating fp16 q/k.
- **conv-stem mel cast** (`VoxtralRealtimeEncoder.swift`): cast the float32 mel to the conv
  weight dtype at the conv-stem seam.
- **SDPA additive-mask cast** (encoder + decoder): build the additive attention mask in the
  activation dtype — required once q/k/v are fp16, or `scaledDotProductAttention` aborts with
  "Mask type must promote to output type float16".

Equivalence was verified at adoption time by diffing every vendored engine file against the
`3b0b114` tree: `VoxtralRealtime.swift`, `VoxtralRealtimeAudio.swift`,
`VoxtralRealtimeConfig.swift`, `VoxtralRealtimeTokenizer.swift`, `Generation.swift`, and
`STTOutput.swift` were byte-identical; `VoxtralRealtimeDecoder.swift` and
`VoxtralRealtimeEncoder.swift` differed only in the comment prose around the (now upstreamed)
casts; `VoxtralRealtimeStreamSession.swift` differed only in the delta routing below.

## What stays local (and why)

- **Append-only delta contract** — `SpeechEngineText.StreamingDelta` +
  `TranscriptDeltaEmitter`. Upstream's `VoxtralRealtimeStreamSession.Delta` re-emits the ENTIRE
  transcript on any non-prefix step (routinely: a multi-byte UTF-8 char split across two
  tokens first decodes to a trailing U+FFFD that the next token replaces). Our insertion path
  has no backspaces (terminals can't support them), so re-emission would duplicate text on
  screen. `RealtimeSpeechServer` therefore ignores the engine's raw `Delta` and instead feeds
  each `session.text` full-transcript snapshot through `TranscriptDeltaEmitter`, emitting only
  its held-back, forward-only delta. This reproduces exactly what the vendored engine did
  internally (old LOCAL FIX #6), but now in a Metal-free, unit-testable layer
  (`SpeechEngineTextTests`). `transcript.done` carries `emitter.emittedText` (== the sum of
  every delta) so the final payload can never contradict the streamed wire output.
- **Our loopback server** — `RealtimeSpeechServer.swift`: the OpenAI-Realtime websocket subset
  that makes the engine a drop-in for the Python `voxmlx` process. Original code, never
  upstream.
- **Watchdog / CLI** — `SpeechEngineText/ParentProcessWatchdog.swift`,
  `Sources/localvoxtral-speechd/main.swift`.

## Version constraints (both risky deps pinned exact)

Upstream's manifest uses `.upToNextMajor` for every dependency, so unconstrained resolution can
drift onto known-bad versions. We pin the two risky ones exactly:

- **mlx-swift `exact: "0.31.3"`** — matches upstream's own `Package.resolved` (what the engine
  and our downstream spike were validated against) and, critically, **avoids 0.31.4 and
  0.31.5**, which carry the `evalLock` deadlock ([mlx-swift#428](https://github.com/ml-explore/mlx-swift/issues/428),
  fixed in 0.31.6).
- **swift-transformers `exact: "1.1.9"`** — must stay **< 1.2**: 1.2+ fails to compile under
  Xcode 26 (the xcodebuild packaging lane that produces the shippable Metal binary). Not
  directly imported here — it's a transitive dep of mlx-audio-swift — so SPM warns it's
  "unused"; that's expected, the pin exists to freeze the whole graph below 1.2.

`mlx-swift-lm` (`exact: "3.31.3"`) and `swift-huggingface` (`exact: "0.8.1"`) also match
upstream's resolved graph. `Package.resolved` is checked in (as in `PolishHelper`) to lock the
full transitive closure.

## Upgrade procedure

1. Bump the `revision:` to the new upstream SHA (and re-pin the four graph deps to whatever the
   new upstream `Package.resolved` uses, keeping the two `exact` constraints above satisfied —
   never let mlx-swift reach 0.31.4/0.31.5 or swift-transformers reach 1.2).
2. Re-run the equivalence checklist: diff the new `Models/VoxtralRealtime/` tree (plus
   `Generation.swift` / `GLMASR/STTOutput.swift`) against the previous SHA and confirm nothing
   we depend on regressed, and that the delta-routing assumption still holds (upstream's
   `session.text` is the full transcript; its raw `Delta` is not append-only).
3. Run the lanes: `./scripts/remote-build.sh test --package-path SpeechHelper` (Metal-free unit
   tier — the verification tier for a manifest/wrapper change) and, for any behavior change, the
   part-2 real-model integration lane (Metal) before wiring anything into the app.
