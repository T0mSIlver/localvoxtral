# Term-recall eval (private)

Measures whether the speech engine spells the owner's technical terms right,
whether it writes listed terms nobody said, and how it does on the other
words. Polish is not in the loop, so a speech-engine change is measured
alone. It is the gate for term biasing in the engine (#316, #521) and for a
second pass on stop (#524).

This directory holds only this README. The cases come from the owner's own
Claude Code transcripts, so everything the pipeline writes stays under the
gitignored `EvalRecordings/term-recall/` or outside the repo. Never commit
it, and never quote a case, a term or a transcript into a PR, an issue or a
CI log. The scoreboard prints counts only and is the part that goes in a PR.

## Pipeline

On the machine that holds the transcripts (`~/.claude/projects`):

```bash
python3 scripts/harvest-term-recall-cases.py
```

It writes `EvalRecordings/term-recall/cases.json`, the only file that goes to
the Mac. `terms.json` (the ranked inventory) and `session-map.json` (case
session hash to transcript path) go to `~/.local/share/localvoxtral/term-recall/`,
outside the repo, so no sync can carry them off. `remote-build.sh` refuses to
run if either sits in `EvalRecordings/term-recall/`.

From the same machine, against the Mac's speech test services:

```bash
./scripts/remote-build.sh eval-term-recall --asr voxtral
```

```bash
./scripts/remote-build.sh eval-term-recall --asr nemotron
```

```bash
./scripts/remote-build.sh eval-term-recall compare voxtral-none nemotron-none
```

Each run prints a scoreboard and leaves its run file in
`EvalRecordings/term-recall/runs/<label>.jsonl`. `--hypotheses
EvalRecordings/term-recall/<file>.jsonl` scores `{"id", "text"}` rows with no
speech engine, for a second pass or a polished transcript. `--recordings
EvalRecordings/term-recall/<set>` replaces `say` with human WAVs in the
agent-dictation manifest format. The full option list is in the header of
`scripts/remote-build.sh`.

## Cases

`cases.json` (schema 2) holds `noiseTerms` and a list of cases, each with:

- `id`: `tr-en-` or `tr-fr-` plus 10 hex characters of the sentence's
  SHA-256.
- `language`: `en` or `fr`, decided per sentence by function-word counts,
  else by its message.
- `text`: the sentence `say` speaks and the reference it is scored against.
- `terms`: the listed terms the sentence contains (1 to 3).
- `sessionTerms`: at most 100 terms from the sentence's session, topped up from
  its project, its own terms included. This is the list the session arm of
  #316 biases with.
- `sessionHash`: 12 hex characters; the path it stands for stays in
  `session-map.json`.

`noiseTerms` holds up to 100 inventory terms that no case speaks or lists: the
noise-control arm's list.

The harvester keeps every sentence that qualifies, including the ones the
engine already gets right, because a clean case is the only way to see a term
a change breaks. It takes real user messages only, and drops sentences with
secrets, URLs, paths, code, command-line flags, table rows, or runs of
identifiers such as a diff line of CSS class names. The inventory is built from
English sentences, because the "not in the dictionary" test that makes a word
technical is English; French sentences are matched against it.

## Scoring

`TermRecallScorer` in `localvoxtralCore` (tests: `TermRecallScoringTests`,
Linux) does all of it:

- Words are lowercased and split on anything that is not a letter or digit,
  so case and punctuation never decide.
- A listed term is recalled where its words appear in order, or where fewer
  adjacent words glue to it exactly (`mlxlm` for `mlx-lm`). It never matches
  inside a longer word, and a split term (`work tree` for `worktree`) is a
  miss. Where two listed terms overlap, the longer one claims the words.
- Term recall counts occurrences of the session list's terms in the reference.
- A false insertion is a listed term the hypothesis says more often than the
  reference, reported for the session list and the noise list separately.
  Every arm counts against both lists, so arms stay comparable. A listed term
  written over the words of another term the reference says ("Claude Claude"
  for "Claude Code") is that term misheard and counts against recall only.
- The non-term word error rate counts alignment errors on reference words
  outside listed terms. An extra word next to a term is left out, so a
  misheard term ("clothes code") counts against recall once, not twice.
- `compare` pairs two runs per case and counts term occurrences gained and
  lost. A case id comes from its sentence, so it survives a re-harvest; a case
  whose text differs between the two runs is left out and counted apart.

## Known limits

- `say` is cleaner than a human voice. Confirm headline results on human
  recordings.
- The sentences are mostly typed, not dictated, messages.
- Term detection is heuristic; a few common words still rank as terms. The
  paired comparison is what a decision rests on, and it is unaffected.
