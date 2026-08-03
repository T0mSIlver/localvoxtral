# Dogfood builds

A dogfood build is the instrumented variant of localvoxtral the owner runs
day-to-day to debug the context pipeline against real usage. It is the same
app — same version, same bundle id, same signing identity — plus a capture
layer that records, per dictation, everything the context pipeline saw and
decided. Shipped releases never contain this code.

## Why it exists

The shipped app deliberately logs context **counts only** — repository
contents, screen text, clipboard text, and rendered prompts never reach the
unified log. The cost of that discipline is that a retrieval miss is
unattributable after the fact: when the polished text gets a technical term
wrong, nothing says whether the term was never harvested, harvested but not
matched, matched but lost a conflict, or matched but cut by the rendering
budget. The dogfood capture is the gated exception that records enough to
blame exactly one of those four stages
([`DogfoodCaptureRecord.swift`](../Sources/localvoxtral/Dogfood/DogfoodCaptureRecord.swift)).

## Two gates, both required

1. **Compile flag** — `LOCALVOXTRAL_DOGFOOD`
   ([`Package.swift`](../Package.swift)): the capture code is not compiled
   into ordinary builds. Set via the env var, or via the gitignored
   `.dogfood-capture-enable` marker file (which exists because the Mac build
   gate can't pass env vars; `remote-build.sh` writes and removes it).
2. **Runtime opt-in** — even an instrumented binary records nothing until
   armed:

   ```
   defaults write com.localvoxtral.app debug.dogfood_capture_enabled -bool true
   ```

   (takes effect on relaunch; `try-pr.sh --dogfood` arms it for you).

## Installing one

```bash
./scripts/try-pr.sh main --dogfood        # on the Mac — the whole install
```

This downloads the CI-built `localvoxtral-app-dogfood` artifact, verifies its
stamp, arms the runtime opt-in, and launches. The artifact is **opt-in in
CI**: put the literal marker `[dogfood-package]` in the PR body / head commit
message, or dispatch CI with `dogfood=true` — which is exactly what try-pr
offers to do when the target run doesn't have the artifact.

Local-build equivalent: `./scripts/remote-build.sh dogfood-package`.
The capture unit suite runs via `./scripts/remote-build.sh dogfood`.

## Knowing which binary you're running

Dogfood builds keep the version and bundle id on purpose (the Accessibility
grant is part of what they exercise), so:

- **Settings > About > Build** shows `Standard` or
  `Dogfood — capture armed | disarmed`
  ([`DogfoodBuildStatus.swift`](../Sources/localvoxtral/Dogfood/DogfoodBuildStatus.swift)).
- The bundle carries `LVXDogfoodCapture` in Info.plist, stamped and
  self-verified by [`package_app.sh`](../scripts/package_app.sh); `try-pr.sh`
  prints it before launching.

## What a record contains

One pretty-printed JSON file per polished dictation, under
`~/Library/Application Support/localvoxtral/dogfood`
([`DogfoodCaptureStore.swift`](../Sources/localvoxtral/Dogfood/DogfoodCaptureStore.swift)).
High level ([`DogfoodCaptureRecord.swift`](../Sources/localvoxtral/Dogfood/DogfoodCaptureRecord.swift)):

- **Session**: target app kind, output mode, prompt profile, endpoint
  *class* only (`loopback`/`lan`/`remote` — never the URL).
- **Join**: which arm resolved the Claude Code session (`tty` / `herdrPane` /
  `titleMarker` / `none`) and every abstention reason along the way.
- **Screen**: capture route, the render / vocabulary-only / drop decision and
  its cause, and the sanitized screen text (capped, truncation recorded).
- **Budget**: per source, characters demanded vs granted vs rendered.
- **Sources**: per source, the harvested candidate terms, the matched
  `(heard span, exact term)` pairs, and the rendered excerpt.
- **Text**: raw transcript → working text → grounded text, the fully
  rendered system/user prompts, the model reply, and the committed text.
- **Behavior**: the edit signal (below) and timings.

Records are token-redacted before writing (43-char base64url runs — a
shape-matched backstop, not a guarantee), stored 0600 in a 0700 directory,
and pruned at 500 records / 14 days. Flagged records are exempt from pruning
and survive until deleted by hand.

## The behavioral edit signal

Each record can carry a content-free signal of whether the user immediately
erased what was inserted
([`DogfoodEditSignalWatcher.swift`](../Sources/localvoxtral/Dogfood/DogfoodEditSignalWatcher.swift)):
a bounded post-commit window (2 s for 1–5 words up to 15 s for 41+ words)
watches for exactly two gestures — Backspace/forward-delete or ⌘A. Recorded:
the gesture, a bucketed delay, the word-count bucket, and the output mode.
Not recorded: key content, text, or anything about any other key. The
`clean` and `superseded` outcomes are recorded too — without the negative
there is no denominator. It is a global `NSEvent` keyDown observer (no new
permission beyond the Accessibility trust insertion already requires),
installed only while a window is open and torn down the instant it closes.

## What it deliberately does not do

- **No uploader, ever.** Records are local files; adding an uploader would
  defeat the point of the compile gate.
- **Never breaks a dictation** — capture runs after the text is committed; a
  write failure costs the record, loudly, never the commit.
- **Not a keylogger** — see the two-gesture allowlist above.
- **Nothing sensitive in the unified log** — the capture's own log lines are
  counts, slugs, and filenames.

## Analyzing records

Records are plain JSON, sorted keys — `jq` away. The `Screen.cause`,
`Allocation`, and `Source.entries` fields are the ones that answer "which
stage lost the term". The pipeline that assembles them is
[`DogfoodCapturePipeline.swift`](../Sources/localvoxtral/Dogfood/DogfoodCapturePipeline.swift);
the wiring point is
[`DictationViewModel+DogfoodCapture.swift`](../Sources/localvoxtral/Dogfood/DictationViewModel+DogfoodCapture.swift).
