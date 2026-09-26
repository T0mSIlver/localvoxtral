# Voxtral Realtime on vLLM, on demand

`voxtral-vllm.sh` serves `mistralai/Voxtral-Mini-4B-Realtime-2602` through vLLM
at `ws://127.0.0.1:8000/v1/realtime` on a Linux box with an NVIDIA GPU. ASR
work that needs hours of inference (term-recall runs, long benches, ASR-only
eval runs) goes there instead of the Mac, which is the owner's working machine
and the only CI runner.

It is not the shipped engine. The app runs the 4-bit MLX conversion
(`T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead`) through
`localvoxtral-speechd`; vLLM runs the BF16 weights. See
[How far it is from speechd](#how-far-it-is-from-speechd) before drawing
conclusions from it.

## Use

```bash
scripts/linux/voxtral-vllm.sh install   # once: venv + pinned weights (~20 GB of disk)
scripts/linux/voxtral-vllm.sh up        # blocks until healthy; instant if already up
scripts/linux/voxtral-vllm.sh status
scripts/linux/voxtral-vllm.sh logs -f
scripts/linux/voxtral-vllm.sh down
```

`up` starts an idle reaper with the server. It stops the server after 10
minutes without a decoded token or another `up`, then exits, so nothing runs
when idle. Call `up` before each batch; it also resets the idle clock.

Sessions send `{"type": "session.update", "model":
"mistralai/Voxtral-Mini-4B-Realtime-2602"}`. The server answers to that name
only, so a scoreboard can't mistake it for the 4-bit model.

`vllm_transcribe.py FILE...` transcribes audio files through the server, one
JSON line per file. With `--realtime` it paces the audio at 1x and reports the
time to first text and the stop tail (last audio sent to final transcript). Run both Python helpers with the venv's interpreter
(`~/work/voxtral-vllm/.venv/bin/python`).

Settings, all environment variables:

| Variable | Default | |
|---|---|---|
| `VOXTRAL_VLLM_HOME` | `~/work/voxtral-vllm` | venv, logs and pid files |
| `VOXTRAL_VLLM_PORT` | `8000` | |
| `VOXTRAL_VLLM_IDLE_SECONDS` | `600` | |
| `VOXTRAL_VLLM_MAX_MODEL_LEN` | `2048` | tokens per take, one per 80 ms: 164 s |
| `VOXTRAL_VLLM_KV_CACHE_BYTES` | `2600M` | 4096 tokens needs about 4.6 GB |
| `VOXTRAL_VLLM_NEED_FREE_MIB` | `12500` | `up` refuses below this much free GPU memory |
| `VOXTRAL_VLLM_COMPILE` | `0` | `1`: torch.compile and CUDA graphs |
| `VOXTRAL_VLLM_LOGITS_PROCESSOR` | empty | `module:Class` of a logits processor on `PYTHONPATH` |
| `VOXTRAL_VLLM_DELAY_MS` | unset (480) | transcription delay, a multiple of 80; needs a port other than 8000 |

With `VOXTRAL_VLLM_DELAY_MS`, the server answers to
`mistralai/Voxtral-Mini-4B-Realtime-2602-delay-<ms>ms` and keeps its files in
`run-delay-<ms>/`, so pass the same two variables to `status`, `logs` and
`down`. vLLM reads the delay once per server, from the snapshot's
`tekken.json`, so the script serves a copy with that value patched.

A take longer than the token limit ends its generation there, and the next
one starts mid-word (#516). Raise both the limit and the KV cache for
long-form benches.

## Numbers

Measured on 2026-09-26 on an RTX 3090 (driver 550, CUDA 12.4) with 16 GB of
RAM, vLLM 0.30.0.

| | Eager (default) | Compiled |
|---|---|---|
| `up` to healthy, weights in page cache | 19.8 s (3 runs) | 21.3–22.8 s (3 runs) |
| `up` to healthy, weights from disk (one run each) | 30 s | 25 s |
| 25 s clip, whole file sent at once | 6.8–7.1 s | 6.2–6.8 s |

`down` takes under a second. Both modes give identical text on the test clips.
Eager is the default because eval runs are short; set `VOXTRAL_VLLM_COMPILE=1`
for long benches.

The server holds 11.8 GB of GPU memory (8.4 GB of weights, 2.6 GB of KV cache)
and 3.6 GB of RAM. Other processes on the card use between 7 and 11 GB, and
that moves, so the footprint is fixed and `up` checks for room first.

Across the 146 eval-e2e TTS cases, sent one at a time, decoding takes a third
of the audio's duration.

## Setup notes

- The PyPI `vllm` wheel pulls torch built for CUDA 13, which needs driver
  580 or newer. `install` takes the release's `+cu129` wheel and cu129 torch,
  which run on driver 550 through CUDA minor-version compatibility.
- FlashInfer's sampler compiles itself with `nvcc` on first use. The box has
  no CUDA toolkit, so the script sets `VLLM_USE_FLASHINFER_SAMPLER=0`.
- vLLM checks free memory against `--gpu-memory-utilization` before it reads
  `--kv-cache-memory-bytes`, so the script passes a low share (0.3) with the
  fixed KV size.

## How far it is from speechd

Same audio, both engines: the 146 speech cases of the agent-dictation eval,
spoken by `say` (Samantha, Thomas) and regenerated from the case text on the
Mac. speechd's raw transcripts come from the eval-e2e run of 2026-09-22 on
`d05e76ec14` (qhead revision `247f2ee`); vLLM's from this server. Word accuracy
is the eval's own metric, measured against the text `say` spoke.

| | All (146) | English (97) | French (49) |
|---|---|---|---|
| Same words from both engines | 110 | 79 | 31 |
| Word agreement between engines | 0.957 | 0.968 | 0.936 |
| Word accuracy, speechd | 0.775 | 0.806 | 0.714 |
| Word accuracy, vLLM | 0.773 | 0.797 | 0.727 |
| Cases vLLM does better / worse | 13 / 12 | 3 / 8 | 10 / 4 |

On the 19 ASR-only cases, required tokens pass 17 times on speechd and 18 on
vLLM.

The two engines agree word for word on three cases in four. Neither is
consistently better, and aggregate accuracy differs by about a point. So a
decoding-level finding (a biasing rule's gains and losses, which terms the
model mishears) carries over as a direction, but its size needs a
confirmation run on speechd. Anything about the app's own path does not carry
over: merging, reconnects, latency, MLX performance. The proofs AGENTS.md
requires on the shipped engine (integration-speechd, eval-e2e) still run on
the Mac.

To redo the comparison against a newer run, download its
`eval-e2e-scoreboard` artifact, then:

```bash
~/work/voxtral-vllm/.venv/bin/python scripts/linux/vllm_fidelity.py eval-e2e.log --say-script > gen.sh
# on the Mac: bash gen.sh in an empty directory, then copy the WAVs here
~/work/voxtral-vllm/.venv/bin/python scripts/linux/vllm_fidelity.py eval-e2e.log <wav dir> out.jsonl
```

## Term biasing prototype (#316)

`vllm_term_bias.py` is a vLLM logits processor that applies #316's biasing
rules to this server, so a rule change costs a Linux run, not the Mac. Only
the mlx-audio-swift hook can ship; this one measures direction. Start the
server with it, then run one arm at a time over a term-recall recording set:

```bash
PYTHONPATH=scripts/linux VOXTRAL_VLLM_LOGITS_PROCESSOR=vllm_term_bias:TermBias scripts/linux/voxtral-vllm.sh up
~/work/voxtral-vllm/.venv/bin/python scripts/linux/vllm_term_bias_eval.py --arm session --out EvalRecordings/term-recall/tb-session.jsonl
```

`up` does not restart a server that already runs, so run `down` first when
switching the processor on or off. The realtime endpoint drops every
`session.update` field but the model, so the driver hands the processor each
case's list through a side file; that file applies to every request, so run
one session at a time. Arms are `none`, `session` and `noise`. Score the
output in `TermRecallEvalTests`' hypotheses mode (`EvalCorpus/term-recall/README.md`).

## What can use it today

Python tools, through `vllm_transcribe.py`, and two Swift suites, which run
the production realtime client under `scripts/core-tests-linux.sh` (#637):

```bash
VLLM_REALTIME_TEST_ENABLE=1 scripts/core-tests-linux.sh --filter RealtimeAPIVLLMIntegrationTests
```

`TermRecallEvalTests` runs in audio mode over a recorded set, with the marker
written by hand (there is no `say` here); see `EvalCorpus/term-recall/README.md`.
Its scoreboard names the engine through the marker's `asr` and `asrModel`.

The speech stage of the agent-dictation eval runs here too, over a recording
set (`AgentDictationASREvalTests`; `EvalCorpus/agent-dictation/README.md`,
"ASR-only runs on Linux"). Its polish stage stays on the Mac.
`SpeechdStreamingBenchTests` drives the MLX helper itself and stays there.
