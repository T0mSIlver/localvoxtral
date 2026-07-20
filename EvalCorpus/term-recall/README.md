# Term-recall harvest (private eval raw material)

Raw material for a future term-recall eval: can the polish LLM map botched
ASR of technical terms ("clothes code" -> "Claude Code") back to exact local
spellings using attached context?  This directory holds ONLY documentation
and no data.  Everything the pipeline produces is PRIVATE — derived from the
owner's real Claude Code transcripts — and lives under `EvalRecordings/`,
which is wholesale gitignored (root `.gitignore`, `/EvalRecordings/`) and
receiver-protected by `remote-build.sh`'s rsync filters.  Never commit the
outputs, never upload them, never quote them into public PRs/issues.

## Pipeline

```
Linux dev box (where ~/.claude/projects lives):
  python3 scripts/harvest-term-recall-cases.py
    -> EvalRecordings/term-recall/cases.json       (sentence, target terms, context;
         provenance is a 12-hex session HASH, no transcript paths)
    -> EvalRecordings/term-recall/terms.json       (ranked term inventory)
    -> EvalRecordings/term-recall/session-map.json (hash -> transcript path;
         LOCAL ONLY — never copy off the harvest machine)

Mac build host (live voxmlx; copy ONLY cases.json into
EvalRecordings/term-recall/ there — not session-map.json):
  ./scripts/mine-term-recall-asr.sh
    -> EvalRecordings/term-recall/mined.jsonl          (resumable journal)
    -> EvalRecordings/term-recall/asr-corruptions.json (the mined product:
         {id, spoken_text, asr_text, corrupted_terms:[{intended, heard}]})
```

A relative `--out-dir` is always resolved against `git rev-parse
--show-toplevel` (the script refuses to run if that fails): the privacy
guarantee rests on the ROOT-anchored `/EvalRecordings/` gitignore rule, so a
cwd-relative write from a subdirectory must be impossible.  The top-terms
stdout dump is opt-in (`--print-terms`) so transcript-derived content stays
out of terminal scrollback and logs by default.

The miner keeps only cases where TTS -> live voxmlx ASR genuinely corrupted a
target term; those `(intended, heard)` pairs are the future eval's inputs.

## What the harvest does

- Scans `~/.claude/projects/*/*.jsonl` session transcripts (schema parsed
  defensively; sidechains, `subagents/` files, command wrappers, and
  tool-result echoes are excluded — only real human messages count).
- Builds a technical-term inventory (unigrams + whitespace-adjacent n-grams
  up to 3) ranked by frequency x session spread x multi-word bonus, with
  per-term provenance counts.  Unspeakable tokens (hashes, UUIDs, paths,
  symbol soup) are dropped.
- Selects real user sentences containing 1–3 inventory terms that read like
  dictation, with per-term caps for diversity.  Pasted content (diffs, logs,
  shell prompts, markup, code) is filtered out.
- Redacts by DROPPING: any sentence matching secret/token/key/email/JWT/
  hex-blob patterns, URLs, long paths, or `user@host` strings is discarded
  entirely rather than masked.

## Harness conventions reused (do not fork them)

- TTS: `/usr/bin/say --file-format=WAVE --data-format=LEI16@16000`, cached in
  `~/Library/Caches/localvoxtral-eval/wav/<key>.wav` with the exact
  `AgentDictationE2EEvalSupport.wavCacheKey` derivation (SHA-256 over
  length-prefixed text/voice/data-format), so WAVs are shared with the
  agent-dictation E2E eval and reruns are pure cache hits.  Synthesis is
  temp-name-then-move, same as the harness.
- ASR: the realtime websocket protocol the production client speaks
  (`OpenAI-Beta: realtime=v1` header, `session.update` ->
  `input_audio_buffer.append` -> commit + final commit ->
  `transcription.done`), default endpoint `ws://127.0.0.1:8000/v1/realtime`
  with the repo-wide model pin
  `T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit`; the wrapper warms
  voxmlx via `scripts/mac/lv-test-servers.sh ensure voxmlx` first, like
  `run-agent-eval-local.sh`.  Like the E2E harness, the miner waits a 1 s
  grace after the first non-empty final and joins trailing final segments,
  so multi-segment utterances are not truncated into false corruptions.
- Reporting: `mined.jsonl` appends one record per case immediately
  (resumable; reruns skip cases whose `input_sha` is unchanged) and stdout
  ends with a sentinel-delimited report,
  `=== TERM-RECALL-MINING-REPORT-BEGIN/END ===` — deliberately a DIFFERENT
  sentinel name from the E2E inspection report so `ablate-agent-eval.py`
  can never mistake one for the other.

## Corruption decision and "heard" span extraction

A term counts as PRESERVED when its speech tokens appear contiguously in the
ASR tokens, or when some window of 1..N adjacent ASR tokens (N = term token
count) joins to exactly the glued term — windowed EQUALITY on token
boundaries, never substring containment, so "tty" can never false-preserve
inside an unrelated glued word.  Decision table (validated against a Python
reference, 9/9):

| term | ASR text | decision |
|---|---|---|
| Claude Code | open claude code and fix the bug | preserved |
| tty | that is pretty good | corrupted |
| tty | join the tty now | preserved |
| mlx-lm | package mlxlm into the app | preserved (glued token) |
| mlx-lm | package mlx lm into the app | preserved (contiguous) |
| mlx-lm | package em el ex el em into the app | corrupted |
| SwiftPM | swift pm process trees | corrupted (needs exact-spelling recall) |
| voxmlx | restart vox m l x on the mac | corrupted |
| AGENTS.md | read agents md first | preserved |

For a corrupted term, the miner reports what ASR wrote in its place: the ASR
tokens between the nearest exactly-matched anchor words on either side of
the term (word-level minimum-edit alignment).  Validated against a Python
reference on these cases before the Swift port (8/8):

| term | ASR heard | extracted span |
|---|---|---|
| Claude Code | clothes code | clothes code |
| voxmlx | vox m l x | vox m l x |
| worktree | work tree | work tree |
| mlx-lm | em el ex el em | em el ex el em |
| AGENTS.md | agents dot MD | agents dot md |
| polishd | polished | polished |
| Ghostty | ghosty | ghosty |
| tty | (dropped) | "" |

## Caveats

- `scripts/mine-term-recall-asr.swift` has not been executed yet (the build
  gate offers no standalone-script typecheck verb); first Mac run should
  start with `--limit 3`.
- Term detection is heuristic.  The inventory deliberately over-collects;
  the per-case `target_terms` are what matter, and the mining pass is the
  ground-truth filter.
