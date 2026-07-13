# Agent-dictation eval corpus

Ground truth for the wide end-to-end dictation eval. Phase 1 (this
directory) is data + structural validation; Phase 2 is the harness that
drives it through the production pipeline:

```
human WAV or TTS(spokenForm) → websocket ASR (Voxtral realtime)
                            → LLM polish (bundled polishd, agent profile)
                            → scoring against this corpus
```

The Swift loader is `Tests/localvoxtralTests/AgentDictationEvalCorpus.swift`;
`AgentDictationEvalCorpusTests` validates every rule below in the plain unit
tier (no env gate, no network). The corpus is test-only data read from the
source tree via `#filePath` — it is never a packaged app resource.

## Layout

```
strata/*.json                one file per stratum (schema below)
fixtures/repo-<name>.json    repo specs the harness git-inits for
                             repo-vocabulary cases
```

## Record a human baseline

The interactive recorder presents the 146 speech-running phrases, records
mono 16-bit/16 kHz WAVs, plays each take back, and saves progress after every
accept. The 17 `polish-only` cases are text inputs and do not need recordings.

```bash
brew install ffmpeg                         # one-time, if needed
./scripts/record-agent-eval.sh --list-devices
./scripts/record-agent-eval.sh --set owner              # system default microphone
```

The default input is recommended. If needed, choose an AVFoundation audio
index shown by `--list-devices` and pass `--device <index>`.
Run the recorder from a local GUI terminal (not SSH); on the first take,
macOS may prompt for Microphone access for Terminal/iTerm. Grant it in System
Settings → Privacy & Security → Microphone if needed. Digitally silent takes
are rejected, and unusually quiet takes produce a warning.
Press Return to record and Return again to stop. Playback is not automatic:
at review, Return accepts immediately; `p`, `r`, `s`, and `q` play the
native-rate take, re-record, skip, or quit. The default microphone records
through macOS's native audio recorder, then converts offline to the eval's
16 kHz mono format; explicit numeric device indexes retain the ffmpeg capture
fallback. Running the same command again resumes the set; `--lang en`,
`--case <id>`, `--redo`, and `--list` are available for focused passes.

Accepted takes and `manifest.json` live under the gitignored, voice-private
`EvalRecordings/agent-dictation/owner/`. The manifest binds each take to the
exact case ID, language, spoken phrase, file name, and SHA-256. Recorded mode
is deliberately strict: the eval rejects an incomplete, stale, modified, or
wrong-format set before loading either model and never fills gaps with TTS.

After the recorder reports 146/146:

```bash
./scripts/package_app.sh release
./scripts/run-agent-eval-local.sh EvalRecordings/agent-dictation/owner
```

This same-Mac path keeps the voice files in the checkout where they were
captured. If the recording set instead lives in the source checkout that drives
the SSH build loop, the equivalent commands are `remote-build.sh package` and
`remote-build.sh eval-e2e EvalRecordings/agent-dictation/owner`; rsync copies
the set into the private Mac's per-worktree build directory and keeps it there
for fast reruns. The files are never committed. Delete a local set when it is
no longer needed. Running either eval launcher without a recording argument
retains the repeatable `say`-based nightly baseline.

## Stratum file schema (schemaVersion 1)

```jsonc
{
  "schemaVersion": 1,
  "stratum": "symbol-forms",          // must stay in AgentDictationEvalCorpus.expectedStrata
  "description": "…",
  "pipeline": "full",                 // "full" (default) | "asr-only" | "polish-only"
  "cases": [ … ]
}
```

Pipelines:

- `full` — recorded speech or TTS → ASR → polish. The normal lane.
- `asr-only` — recorded speech or TTS → ASR, no polish. Used by `plain-asr-baseline`: tokens
  assert raw recognition only.
- `polish-only` — `spokenForm` is fed directly to the polish path as input
  text. Used by `punctuation-spacing-migration`, whose inputs carry
  ASR-artifact spacing ("tomorrow ?") that TTS cannot speak.

## Case schema

| Field | Meaning |
|---|---|
| `id` | Stable slug `<stratum-letter>-<lang>-<slug>`, unique corpus-wide. |
| `lang` | `"en"` or `"fr"` (validated by a function-word heuristic). |
| `spokenForm` | Exactly what the human recorder or TTS speaks. Symbols written phonetically, the way a human dictates: "dash dash force", "dot env", "tiret tiret", "colle le presse-papier". Include the fillers/self-corrections when the stratum calls for them. |
| `intendedText` | Ground-truth final output. |
| `requiredTokens` | Substrings that MUST appear in the final text — the primary metric. Matched after spacing normalization (U+202F/U+00A0 → space, runs collapsed), byte-exact and case-SENSITIVE unless `caseInsensitive` is set. |
| `forbiddenSubstrings` | Substrings that must NOT appear (fillers, macro marker phrases, leaked payloads, the `$LV_CLIPBOARD_PAYLOAD` placeholder). Always matched case-insensitively. Pick collision-free needles — validation rejects any that appear in `intendedText` or overlap a required token. |
| `caseInsensitive` | Optional, default false. Set on ASR-baseline cases (ASR casing wobbles) and migrated punctuation cases (the old scorer lowercased). |
| `features` | Fixtures the harness must arrange: `clipboard` (payload string to put on the pasteboard), `repo` (`{fixture, files}` — fixture name + the specific files the case relies on), `macro` (true = spoken paste macro MUST fire, false = explicit negative that must NOT fire, absent = no macro semantics). |
| `status` | Per-metric status map, `"required"` \| `"known-hard"`. Metrics: `tokens` (requiredTokens present ∧ forbiddenSubstrings absent — every case carries it) and `exactText` (normalized whole-output equality with `intendedText`). |
| `notes` | One line: why this case exists. |
| `source` | Optional provenance: `migratedFrom`/`originalId` for direct migrations, `seed` for phrasing seeds. |

## Eval policy (owner-established, non-negotiable)

- **No probabilistic pass bars.** No "90% of cases must pass".
- **`required` cases assert individually.** One failure = red suite.
- **`known-hard` cases are XFAIL-tracked**: printed, counted, never asserted.
- **Promotion** `known-hard` → `required` needs stability across server
  states (restarts / prompt-cache configurations — see
  `LLMPolishEvalSupport.requiredCases` doc for the observed flip mechanism).
  Every NEW case therefore starts `known-hard`.
  `testRequiredStatusAppearsOnlyOnMigratedRequiredCases` ratchets this: the
  PR that promotes a case must carry the cross-server-state evidence and
  adjust that assertion deliberately.

## Strata

| File | Stratum | What it exercises |
|---|---|---|
| `a-plain-asr.json` | `plain-asr-baseline` | Recognition floor: plain technical sentences, tokens on ASR-stable words, no polish. |
| `b-symbol-forms.json` | `symbol-forms` | Spoken symbols → written: flags, paths, versions, ports, globs, assignments. |
| `c-filenames.json` | `filenames-backticks` | Filenames from natural words, dotted files, backticked inline code, identifier casing. |
| `d-fillers-corrections.json` | `fillers-self-corrections` | um/uh/like/euh removal, "three retries no wait five" → five, retractions, stutters. |
| `e-punctuation-spacing.json` | `punctuation-spacing-migration` | Direct migration of `LLMPolishEvalSupport` required + known-hard cases (byte-matched by test). |
| `f-enumerations.json` | `enumerations` | Spoken enumerations → numbered/bulleted Markdown lists. |
| `g-clipboard-context.json` | `clipboard-context` | Clipboard payload grounds exact spellings (identifiers, branches, hashes). |
| `h-paste-macro.json` | `paste-clipboard-macro` | "paste clipboard"/"colle le presse-papier" embedding + negatives that must not fire. |
| `i-repo-vocabulary.json` | `repo-vocabulary` | git ls-files vocabulary resolves loose speech to exact repo paths (fixture-backed). |
| `j-guard-stress.json` | `guard-stress` | Token-guard stress: flag/URL/hash/env-var-dense prompts. |

## Authoring rules

- **spokenForm conventions** — EN: "dash dash" (`--`), "dash v" (`-v`),
  "dot" (`.`), "slash" (`/`), "tilde" (`~`), "star" (`*`), "caret" (`^`),
  "underscore" (`_`), "equals" (`=`), "colon" (`:`), "quote" (`"`), spelled
  letters for opaque segments ("u s r", "y m l"). FR: "tiret tiret",
  "point", "étoile", "deux points"; keep "slash"/"underscore" as commonly
  code-switched. Numbers as the speaker would say them ("eight thousand
  eighty", "huit mille quatre-vingts").
- Write `intendedText` as the text you would actually want committed into a
  terminal agent prompt — punctuation, casing, backticks and all.
- Every case needs at least one `requiredTokens` entry and a `tokens`
  status. Use `exactText` additionally where whole-output equality is a
  meaningful (eventual) goal.
- Forbidden needles: prefer multi-character, low-collision strings. The
  validation suite rejects a needle that occurs in `intendedText` (e.g.
  forbidding `um` while `intendedText` contains "number") or that overlaps
  a required token.
- Macro cases must forbid `$LV_CLIPBOARD_PAYLOAD`; positive macro cases
  embed the payload in `intendedText`, negatives forbid the payload.
- Repo-vocabulary cases list the exact fixture files they rely on; the
  files must exist in the fixture spec.
- New strata: update `AgentDictationEvalCorpus.expectedStrata`, this README,
  and the stats table in the introducing PR together.

## Phase 2 consumption contract

- Load via `AgentDictationEvalCorpus.loadStrata()` /
  `loadRepoFixtures()`; drive the pipeline named by
  `stratum.resolvedPipeline`.
- Feed either a manifest-bound human WAV set or speak `spokenForm` with
  `/usr/bin/say` at LEI16@16000 (see
  `RealtimeAPIVLLMIntegrationTests.makeSpokenPCM16Data`), FR cases with a
  French voice. Never mix sources within one scoreboard.
- Arrange `features` BEFORE the run: pasteboard payload, git-inited fixture
  repo (files from the spec, checked out on the spec's `branch`) fronted as
  the active terminal repo.
- Score on `LLMPolishEvalSupport.normalizedSpacing`-normalized output:
  `tokens` = all requiredTokens present (case per `caseInsensitive`) and no
  forbiddenSubstrings (case-insensitive); `exactText` = normalized equality
  with `intendedText`.
- Enforce the eval policy above: assert `required` individually, print
  `known-hard` as XFAIL with pass counts per stratum/lang.
- Keep an anti-rewrite guard in the harness (word-accuracy floor between
  input and output, as `LLMPolishEvalSupport.runCase` does) — it is scorer
  behavior, deliberately not corpus data.
