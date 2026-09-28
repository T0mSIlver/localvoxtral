# Test harness

Two pieces of the app exist only for testing it from outside, and never ship:
a local control socket that starts dictations and reports what the context
pipeline resolved, and a WAV file that stands in for the microphone. Both are
compiled under `#if DEBUG || LOCALVOXTRAL_E2E_HARNESS`
([`Package.swift`](../Package.swift)): debug builds and the unit tests have
them, a release build has neither, and `package_app.sh` checks every bundle's
binary for them (`scripts/packaging/check-harness-symbols.sh`). The UI smoke
workflow packages its app with `LOCALVOXTRAL_E2E_HARNESS=1`
(`docs/agent/invariants.md`, "The dogfood control socket is an accepted
tradeoff").

For the owner's UI gate to drive a harness build, dispatch UI Smoke on the
branch (`scripts/ui-smoke-dispatch.sh --override "harness build for the UI gate" <branch>`): its e2e-dictation job
packages the harness build, installs it into the gate's artifact root, and
prints the `launch --harness` command in the run summary. The run takes over
the owner's screen for its e2e check, so it needs the owner's go. Diagnostic records
ship in every build (`docs/agent/diagnostic-records.md`).

## The control socket

The app can expose a local AF_UNIX control socket, so an
operator on the same machine can run a dictation and ask the app what it
joined and why
([`DogfoodControlSocket.swift`](../Sources/localvoxtral/Dogfood/DogfoodControlSocket.swift)).
It exists because two things cannot be observed from outside the process.
A dictation has no deterministic trigger (the real one is a modifier
*gesture*). And `ClaudeSessionRegistry` lives in the app, so
`localvoxtral --probe-surface` resolves only against the sessions the app last
saved to disk, never the live registry.

**Two gates, both required**: the compile condition above, and

```
defaults write com.localvoxtral.app debug.dogfood_control_socket_enabled -bool true
```

The app reads the setting once at launch.
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

A build with the control socket, launched with `LOCALVOXTRAL_DOGFOOD_AUDIO_FILE` set to an
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
