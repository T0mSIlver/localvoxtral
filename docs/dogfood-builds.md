# Dogfood builds

A dogfood build is the instrumented variant of localvoxtral that the owner
runs day to day to debug the context pipeline against real usage. It is the
same app, with the same version, bundle id and signing identity, plus a
capture layer that records, per dictation, everything the context pipeline
saw and decided. Shipped releases never contain this code.

## Why it exists

The shipped app deliberately logs context **counts only**. Repository
contents, screen text, clipboard text, and rendered prompts never reach the
unified log. The cost is that nobody can tell afterwards where a retrieval
miss happened. When the polished text gets a technical term wrong, nothing
says whether the term was never harvested, harvested but not matched,
matched but lost a conflict, or matched but cut by the rendering budget. The
dogfood capture is the gated exception that records enough to blame exactly
one of those four stages
([`DogfoodCaptureRecord.swift`](../Sources/localvoxtral/Dogfood/DogfoodCaptureRecord.swift)).

## Two gates, both required

1. **Compile flag** `LOCALVOXTRAL_DOGFOOD`
   ([`Package.swift`](../Package.swift)). Ordinary builds don't compile the
   capture code. Set the flag with the env var, or with the gitignored
   `.dogfood-capture-enable` marker file. The marker exists because the Mac
   build gate can't pass env vars; `remote-build.sh` writes and removes it.
2. **Runtime opt-in.** Even an instrumented binary records nothing until
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
CI**. Put the literal marker `[dogfood-package]` in the PR body / head commit
message, or dispatch CI with `dogfood=true -f herdr=false`. try-pr offers to
run that dispatch when the target run doesn't have the artifact.

A dispatch otherwise forces the live herdr lane on, and `herdr=false` keeps
that lane from failing the run: its fixture refuses to start beside a herdr
the account is already running. Packaging and the artifact uploads run
before the live lanes either way, so a red lane no longer costs you the
artifact.

To build locally instead, run `./scripts/remote-build.sh dogfood-package`.
The capture unit suite runs via `./scripts/remote-build.sh dogfood`.

## Knowing which binary you're running

Dogfood builds keep the version and bundle id on purpose, because the
Accessibility grant is part of what they exercise. To tell them apart:

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
  *class* only (`loopback`/`lan`/`remote`, never the URL).
- **Join**: which arm resolved the Claude Code session (`tty` / `herdrPane` /
  `remoteHerdrPane` / `remoteSSHConnection` / `remoteLocalTTY` / `cmuxSurface` / `browserTab` / `none`)
  and every abstention reason along the way. These are the same six fields,
  from the same mapper, that `localvoxtral --probe-surface` prints for the
  frontmost surface, so you can compare a probe run and a record directly
  (`docs/agent/field-debugging.md`).
- **Screen**: capture route, the render / vocabulary-only / drop decision and
  its cause, and the sanitized screen text (capped, truncation recorded).
- **Budget**: per source, characters demanded vs granted vs rendered.
- **Sources**: per source, the harvested candidate terms, the matched
  `(heard span, exact term)` pairs, and the rendered excerpt.
- **Text**: raw transcript, then working text, then grounded text; the fully
  rendered system/user prompts, the model reply, and the committed text.
- **Behavior**: the edit signal (below) and timings.

Before writing, the capture redacts tokens (43-char base64url runs). That is
a shape-matched backstop, not a guarantee. Records are stored 0600 in a 0700
directory and pruned at 500 records / 14 days. Flagged records are exempt
from pruning and survive until deleted by hand.

## The behavioral edit signal

Each record can carry a content-free signal of whether the user immediately
erased what was inserted
([`DogfoodEditSignalWatcher.swift`](../Sources/localvoxtral/Dogfood/DogfoodEditSignalWatcher.swift)).
A bounded post-commit window (2 s for 1–5 words up to 15 s for 41+ words)
watches for exactly two gestures: Backspace/forward-delete or ⌘A.

- Recorded: the gesture, a bucketed delay, the word-count bucket, and the
  output mode. The `clean` and `superseded` outcomes are recorded too;
  without the negative there is no denominator.
- Not recorded: key content, text, or anything about any other key.

The watcher is a global `NSEvent` keyDown observer. It needs no permission
beyond the Accessibility trust that insertion already requires. It is
installed only while a window is open and removed the instant it closes.

## The control socket

An instrumented build can also expose a local AF_UNIX control socket, so an
operator on the same machine can run a dictation and ask the app what it
joined and why
([`DogfoodControlSocket.swift`](../Sources/localvoxtral/Dogfood/DogfoodControlSocket.swift)).
It exists because two things cannot be observed from outside the process.
A dictation has no deterministic trigger (the real one is a modifier
*gesture*). And `ClaudeSessionRegistry` lives in the app, so
`localvoxtral --probe-surface` resolves only against the sessions the app last
saved to disk, never the live registry.

**Two gates, both required**, and the second is NOT the capture's:

```
defaults write com.localvoxtral.app debug.dogfood_control_socket_enabled -bool true
```

Writing capture records and accepting commands are different consents, so
arming one never arms the other. The app reads the setting once at launch.
Turning it on needs a relaunch, because a listener must not appear under a
running app.

Socket at `~/Library/Application Support/localvoxtral/dogfood/control/control.sock`,
0600 inside a 0700 directory, and the peer's uid is verified (`getpeereid`)
before a single byte is read.

Wire: one printable-ASCII line in (≤ 256 bytes), one line of JSON out, then
the server closes.

```
$ printf 'registry list\n' | nc -U ~/Library/Application\ Support/localvoxtral/dogfood/control/control.sock
{"ok":true,"command":"registry list","error":null,"result":{"count":1,"sessions":[…]}}
```

| Command | Answers |
| --- | --- |
| `session start overlay` / `session start live` | starts a dictation through the app's own modifier-tap handler; reports the phase and any refusal |
| `session stop` | ends it; while a start is still connecting, cancels that start instead of abandoning it |
| `join report` | the join the LAST dictation resolved, as `ClaudeSessionJoinSummary` |
| `surface probe` | resolves the focused surface NOW, against the live in-process registry |
| `registry list` | the live sessions, as shapes, so "nothing registered" is distinguishable from "resolution failed". For a REMOTE session it also reports whether each join arm's own inputs arrived: `remoteHerdrPane`/`remoteHerdrSocket`, `remoteCmuxSurface`, and `remoteSSHConnection`/`remoteSSHTTY`/`remoteMultiplexerLabel`/`remoteLocalTTY` for the two plain-ssh arms |

Limits to know before changing it:

- **`session start` is capped.** It auto-stops after two minutes, so a client
  that disconnects mid-dictation cannot leave the app recording. The cap is
  armed for anything on its way up, such as connecting or waiting on the
  microphone prompt, not just a live dictation. It is released only on
  evidence that the session actually ended. In particular, `session stop`
  arriving mid-connect does NOT simply disarm it. It cancels the connect
  (`cancelDictation`) and releases the cap only if the phase settled. Only
  the user can answer the microphone prompt, so a stop there cannot settle
  the phase. It reports `stopped: false` and leaves the cap armed, because
  disarming it there would leave the dictation that arrives moments later
  unbounded and unowned.
- **The cap belongs to ONE session, not to the clock.** It carries the capture
  generation it armed at and refuses to fire on a dictation that is not the
  one it opened. A cap left over from a session the owner ended by hand
  therefore cannot stop the owner's next one. One gap remains: if the owner
  starts their own dictation after a socket start is cancelled but before
  that session ever begins, the generations coincide and the cap can still
  end it.
- **`session start` is refused while a probe's resolve is still outstanding**,
  the mirror of `surface probe`'s refusal during a dictation. A probe is
  bounded only by abandonment. A wedged one therefore outlives its deadline
  inside the non-reentrant `ClaudeJoinAbstentionTap.collecting` and still
  holds its forward lease. A dictation started alongside it would interleave
  two resolutions against one tap.
- **It never bypasses a guard.** `session start` reaches
  `handleModifierOnlyTap`, the same function the HID gesture reaches, and is
  subject to the same Secure Keyboard Entry refusal, Accessibility state,
  microphone gate and backend readiness. A refusal is reported, never
  overridden.
- **Nothing identifying crosses.** Every reply value is a bool, a count or a
  closed enum name; no field is built from a token, nonce, marker, host, path,
  tty, pane id or session id.
- **Nothing can be injected.** No command carries a surface, a session or a
  join. Every verb observes real resolution.

## Dictating from a file

An instrumented build launched with `LOCALVOXTRAL_DOGFOOD_AUDIO_FILE` set to an
absolute path dictates from that WAV in place of the microphone
([`DogfoodAudioFileSource.swift`](../Sources/localvoxtral/Dogfood/DogfoodAudioFileSource.swift)).
An end-to-end check needs the same words on every run with nobody at the
machine. A file gives that, and needs neither a loudspeaker nor a microphone
grant.

```
open --env LOCALVOXTRAL_DOGFOOD_AUDIO_FILE=/path/to/utterance.wav localvoxtral.app
```

The file must be mono 16-bit PCM at 16 kHz, the format
`scripts/record-agent-eval.sh` writes. The app refuses any other format
instead of resampling it. Every dictation of that launch plays the file from
its start at real-time pace, then sends silence until the dictation stops.
The log line `dogfood audio file drained` (category `Dictation`) marks the
end of the file.

- **The path comes from the launch environment, never the control socket.**
  Audio turns into keystrokes in the focused app, so a socket command carrying
  it would break "nothing can be injected" above. Whoever sets the environment
  already chose the binary.
- **It never falls back to the microphone.** A missing or unusable file fails
  that dictation's start, with the reason in the popover and the log. The
  microphone permission gate reports authorized, because no microphone is
  used. The capture health monitor stays off, because its recovery would
  restart the microphone.
- **`scripts/e2e-dictation.sh` is its user.** It launches the bundle with a
  spoken scenario phrase, dictates into a throwaway target window through the
  control socket, and scores what was inserted. It runs in the UI smoke
  workflow (`docs/agent/test-tiers.md`).
- **`MicrophoneCaptureService` is not covered.** Device selection, format
  conversion and capture recovery are bypassed. Everything after the capture
  callback is the production path.

## What it deliberately does not do

- **No uploader, ever.** Records are local files; adding an uploader would
  defeat the point of the compile gate.
- **Never breaks a dictation.** Capture runs after the text is committed. A
  write failure costs the record, loudly, never the commit.
- **Not a keylogger.** See the two-gesture allowlist above.
- **Nothing sensitive in the unified log.** The capture's own log lines are
  counts, slugs, and filenames.

## Analyzing records

Records are plain JSON with sorted keys, so `jq` reads them. The `Screen.cause`,
`Allocation`, and `Source.entries` fields are the ones that answer "which
stage lost the term". The pipeline that assembles them is
[`DogfoodCapturePipeline.swift`](../Sources/localvoxtral/Dogfood/DogfoodCapturePipeline.swift);
the wiring point is
[`DictationSessionController+DogfoodCapture.swift`](../Sources/localvoxtral/Dogfood/DictationSessionController+DogfoodCapture.swift).
