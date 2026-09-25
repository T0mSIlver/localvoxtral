# Dependency: mlx-audio-swift streaming ASR

`SpeechEngine` drives [`Blaizzy/mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift)'s
VoxtralRealtime and NemotronASR engines as an **upstream SwiftPM dependency** (product
`MLXAudioSTT`, MIT-licensed). VoxtralRealtime used to be vendored into `Sources/SpeechEngine/`
with local patches; those patches were upstreamed (see below), so we depend instead of vendor.

Which engine a launch drives is decided by `SpeechModelLoader` from the repo id (or a
`--model-dir` checkpoint's `model_type`), and both are adapted to one local contract,
`SpeechASREngine` / `SpeechASRStreamingSession` — see "What stays local" below.

The app now consumes this package as its production managed ASR backend:
`BackendCatalog.speechd` launches the bundled `localvoxtral-speechd`, and the
app pre-downloads the catalog-pinned HF snapshot that the helper loads exactly.

Attribution: the dependency ships its own `LICENSE` (MIT, © 2025 Prince Canuma) in its SwiftPM
checkout — we no longer keep a copy here.

## The pin

```
.package(
    url: "https://github.com/T0mSIlver/mlx-audio-swift.git",
    revision: "06ac8aedfec6b5d072f65323faf2654d9b9d59c8"
)
```

Pinned to a full-SHA **revision**, not a tag, so the exact reviewed tree is reproducible and
can't move under us.

**Temporary fork pin (#521).** `06ac8ae` is upstream `01dec7c` (below) plus the commits on the
fork's `feat/nemotron-term-boost` branch: term boosting in Nemotron's greedy streaming decoder
(`NemotronASRStreamSession.setBoostTerms`). The helper hands it the `vocabulary` list from
`session.update`. Once the change merges upstream, switch the URL back to Blaizzy at the merge
commit and re-run the upgrade procedure below.

`01dec7c` is upstream main at the merge of
[Blaizzy/mlx-audio-swift#265](https://github.com/Blaizzy/mlx-audio-swift/pull/265), the last of
three PRs that bound streaming memory over long sessions: #263 drops conv and adapter rows once
consumed, #264 appends decoder KV rows in place instead of rebuilding the window, #265 decodes
the transcript one token at a time instead of re-detokenizing it every step. `session.text` is
still the full transcript, so the append-only delta routing below is unchanged.

The same tree already carries NVIDIA Nemotron 3.5 ASR streaming — #195/#196 port the model,
#208 adds the incremental `NemotronASRStreamSession`, #236 widens the checkpoint loader — so
adding the second catalog entry (#463) needed no pin change. Two Nemotron facts the adapter
in `SpeechASREngines.swift` depends on:

- It is an **RNN-T**: it only ever appends text, and it never emits end-of-stream on its own,
  so the append-only delta contract carries it unchanged and there is no `maxTokens` to cap.
  `UtteranceLimit` is therefore enforced by our adapter, on the audio the session accepts.
- Its session decodes in fixed chunks of 80 ms encoder frames; the model card publishes WER
  for 80/160/320/560/1120 ms, and `NemotronChunkLadder` maps `--transcription-delay-ms` onto
  those rungs. Its decoder strips the model's `<xx-XX>` language tag itself.

Its `advance()` recomputes the whole mel from the raw buffer on every `step`, which is
O(utterance) per step — upstream calls it negligible at utterance scale and a future
optimization. `speechd-bench` at the production cadence is how to check that claim before
raising the limit on this engine.

The pin before that, `8ed8188`, was the merge of
[Blaizzy/mlx-audio-swift#232](https://github.com/Blaizzy/mlx-audio-swift/pull/232): the
quantized-tied-embedding loader fix, required to load the catalog-pinned `-qhead` checkpoint
(4-bit/g64-quantized tied embedding/LM head — see `SpeechModelCatalog.swift`); without it the
loader rejects the checkpoint's `tok_embeddings.scales`/`.biases` under `verify: .all`. Its
merge ended the temporary `T0mSIlver/mlx-audio-swift` fork pin that had staged the fix — every
optimization the fork ever carried is upstream now (#229: Metal-pool clear cadence, #230:
incremental mel/conv front end, #231: hoisted attention invariants, #232 above). Note the
merged #232 is a review-evolved variant of the fork commit (module-routed
`embedToken`/`logits` instead of raw-weight access, plus upstream regression tests), so the
switchback re-ran the live speechd integration lane rather than assuming equivalence.

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
- **The engine seam** — `SpeechEngineText/SpeechASREngineContract.swift` (pure, tested in the
  tier-0 lane) plus the MLX-bound adapters in `SpeechEngine/SpeechASREngines.swift`. Upstream
  has no common protocol across its models, so the server talks to one of ours: feed audio,
  read the growing transcript, flush the tail, and say why the session stopped decoding.
- **Our loopback server** — `RealtimeSpeechServer.swift`: the OpenAI-Realtime websocket subset
  consumed by the app's production realtime client. Original code, never
  upstream.
- **Watchdog / CLI** — `SpeechEngineText/ParentProcessWatchdog.swift`,
  `Sources/localvoxtral-speechd/SpeechdMain.swift`.

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
2. Re-run the equivalence checklist: diff the new `Models/VoxtralRealtime/` and
   `Models/NemotronASR/` trees (plus `Generation.swift` / `GLMASR/STTOutput.swift`) against the
   previous SHA and confirm nothing we depend on regressed, and that the delta-routing
   assumption still holds (upstream's `session.text` is the full transcript; its raw `Delta`
   is not append-only).
3. Run the lanes: `./scripts/remote-build.sh test --package-path SpeechHelper` (Metal-free unit
   tier) and `./scripts/remote-build.sh package` followed by
   `./scripts/remote-build.sh integration-speechd` (the packaged real-model Metal gate for the
   upstream engine, append-only wire contract, and parent tether) — once per catalog entry,
   passing the repo id as the lane's argument.
