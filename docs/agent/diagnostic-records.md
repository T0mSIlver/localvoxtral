# Diagnostic records

Every polished Overlay Buffer dictation writes one JSON record of what the
context pipeline saw and decided, next to its History entry. Users see one
switch, History > Storage > "Keep diagnostic records on this Mac" (on by
default); `docs/dictation.md` ("Diagnostic records") is their side. This page
is the format and the rules that keep it safe to ship.

## Why it exists

The app logs context **counts only**. Repository contents, screen text,
clipboard text and rendered prompts never reach the unified log, so nobody can
tell afterwards where a retrieval miss happened. When the polished text gets a
technical term wrong, the record says which of four stages lost it: never
harvested, harvested but not matched, matched but lost a conflict, or matched
but cut by the render budget
([`DiagnosticRecord.swift`](../../Sources/localvoxtralCore/DiagnosticRecords/DiagnosticRecord.swift)).

## Where it lives and when it is written

- `~/Library/Application Support/localvoxtral/diagnostic-records/dictation-<UTC stamp>-<History id>.json`,
  0600 files in a 0700 folder, written through `ClaudeRemoteHostFileStoreIO`
  ([`DiagnosticRecordStore.swift`](../../Sources/localvoxtralCore/DiagnosticRecords/DiagnosticRecordStore.swift)).
- The record's `id` is its `DictationSessionRecord` id, so a record joins its
  History entry and its audio (`dictation-audio/<id>.wav`).
- Written only on the polish commit path, after the text is committed and the
  History entry saved, and only when the switch is on AND History keeps
  dictations. `saveSessionRecord` returns the entry id; nil means no entry, so
  no record. Live Auto-Paste writes none.
- Deleted with its entry: `DictationSessionStore` removes it on Delete, Delete
  All and retention, and sweeps records whose entry is gone at launch and on
  every trim. Turning the switch off deletes every record. The store's own
  limit is 500 records and 14 days.
- A write failure logs to `Log.backends` and costs only the record, never the
  commit.
- Unit tests get no store (`diagnosticRecordStore` is nil without runtime
  services), so a test never writes the user's folder.

## What a record contains

High level; the type is the reference:

- **Session**: target app kind, output mode, prompt profile, endpoint
  *class* only (`loopback`/`lan`/`remote`, never the URL).
- **Join**: which arm resolved the agent session (`tty` / `herdrPane` /
  `remoteHerdrPane` / `remoteSSHConnection` / `remoteLocalTTY` /
  `cmuxSurface` / `browserTab` / `none`) and every abstention reason along
  the way. The same fields, from the same mapper, that `localvoxtral
  --probe-surface` prints, so a probe run and a record compare directly
  (`docs/agent/field-debugging.md`).
- **Screen**: capture route, the render / vocabulary-only / drop decision and
  its cause, and the sanitized screen text (capped, truncation recorded).
- **Budget**: per source, characters demanded vs granted vs rendered.
- **Sources**: per source, the harvested candidate terms, the matched
  `(heard span, exact term)` pairs, and the rendered excerpt.
- **Text**: raw transcript, then working text, then grounded text; the
  rendered system and user prompts, the model reply, and the committed text
  (placeholder-bearing: the clipboard payload never enters).
- **Behavior**: the edit signal (below) and timings, including
  `captureMilliseconds`, what building the record cost.

`schemaVersion` is 2: version 1 was the dogfood build's, with a fresh UUID
for `id` and a `flagged` field.

## What is kept out

[`DiagnosticRecordRedaction`](../../Sources/localvoxtralCore/DiagnosticRecords/DiagnosticRecordRedaction.swift)
runs on every string before the write:

- Secret shapes: PEM private keys (also cut off), JWTs, `Bearer` tokens,
  service-prefixed keys (`sk-`, `ghp_`, `github_pat_`, `xox?-`, `AKIA`,
  `AIza`, `glpat-`, `hf_`, `sk_live_`, `npm_`, `pypi-`), uppercase
  `…KEY/TOKEN/SECRET/PASSWORD…=` shell assignments, runs of 32+ hex digits,
  and the 43-character remote-enrollment token. Each has a test in
  `DiagnosticRecordRedactionTests`. It is a backstop: the guarantee is that
  records never leave the Mac.
- The prompt the user last sent to the joined agent
  (`latestPriorUserPrompt`). The session context carries it into the rendered
  prompts, the agent source's excerpt and often the screen; the builder
  replaces its lines there before the record exists, both as sent and as a
  selected excerpt renders them (tabs as spaces, #1106), and on the screen
  also soft-wrapped across rows with whitespace ignored (#1121), because
  `docs/dictation.md` promises the app never saves that prompt. Earlier
  prompts can still be on the screen text, which the owner accepted in #792.
- The unsent draft the joined session's mod read from its prompt box at
  the stop (`ClaudePromptDraft`, #1406). It reaches the session context
  behind its own labels; the builder takes it out by the same passes as the
  prior prompt, under `<prompt draft withheld>`.
- Never add a field that holds the prompt correction learning compares
  (`CorrectionLearning`), or the clipboard payload.

## The edit signal

A content-free signal of whether the user erased what was inserted
([`EditSignalWatcher.swift`](../../Sources/localvoxtralCore/DiagnosticRecords/EditSignalWatcher.swift)).
A post-commit window (2 s for 1–5 words, up to 15 s for 41+ words) watches
for Backspace/forward delete or ⌘A, and nothing else.

- Recorded: the gesture, a bucketed delay, the word-count bucket, the output
  mode. The `clean` and `superseded` outcomes too: without the negative there
  is no denominator.
- Not recorded: key content, text, or anything about any other key.
- A global `NSEvent` keyDown observer, which needs only the Accessibility
  trust insertion already has, installed only while a window is open. It runs
  only when a record is written, and patches that record in place when the
  window closes; a record deleted meanwhile, by this copy or another one
  sharing the data folder, is not recreated.

## Analyzing records

Plain JSON with sorted keys, so `jq` reads them. `screen.cause`,
`allocation` and `sources[].entries` answer "which stage lost the term".
[`DiagnosticRecordPipeline.swift`](../../Sources/localvoxtral/DiagnosticRecords/DiagnosticRecordPipeline.swift)
assembles them;
[`DictationSessionController+DiagnosticRecord.swift`](../../Sources/localvoxtral/DiagnosticRecords/DictationSessionController+DiagnosticRecord.swift)
is the wiring point.
