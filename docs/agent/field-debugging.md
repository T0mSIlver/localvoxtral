# Hand-testing & field debugging (the fast loop)

Learned the hard way (2026-07-04) — use these instead of manual steps:

- **Trying a PR build on the Mac**: `./scripts/try-pr.sh <pr-number|main>`
  downloads the exact CI-built artifact and launches it. No checkout, no
  build. Push → CI (~1.5 min) → try-pr.sh is the whole owner iteration loop.
  Pushes to main build no bundle, so `main` takes the newest dispatched
  build and, when it is behind main, offers to dispatch one and wait.
  `--dogfood` fetches the instrumented `localvoxtral-app-dogfood` artifact
  instead, verifies its `LVXDogfoodCapture` stamp, arms the runtime capture
  default, and launches — the one-command dogfood install. That artifact is
  opt-in in CI (`[dogfood-package]` in the PR body / head commit message, or
  a `workflow_dispatch` with `dogfood=true`); when the target run lacks it,
  the script offers to trigger a dispatch build and shows the latest run
  that has one.
  `--ui-gate` (composable with `--dogfood`) installs the bundle into the SSH
  UI gate's artifact root instead of leaving it in `/tmp`, and stops short of
  launching it — `ssh lv-ui 'launch ...'` is what starts it, and what records
  the pid every other gate verb addresses. The gate's roots are owner-writable
  only on purpose, so the install destination moves rather than the roots
  (`scripts/mac/install-ui-artifact.sh`, runbook `scripts/mac/README.md`).
  An agent driving the gate has no shell on that account: for it, the install
  is `gh workflow run CI --ref <branch> -f dogfood=true -f herdr=false`
  (`herdr=false` because a dispatch otherwise forces the live herdr lane on,
  and its fixture refuses to start beside the herdr the owner runs all day).
  The self-hosted
  runner is a launchd agent in the owner's GUI session, so its `$HOME` is the
  artifact root's home, and that dispatch (and ONLY a dispatch — the
  `[dogfood-package]` marker must never write into the owner's home) installs
  the bundle and prints the `launch` command in the run summary.
- **Driving the UI gate from the dev box**: `./scripts/mac-ui.sh <verb…>`
  passes one gate verb through a multiplexed ssh connection that stays open
  between calls (ControlMaster/ControlPersist, 600 s idle), so a
  click-by-click session pays the handshake once. Host from
  `git config localvoxtral.uihost` (default `tom@192.168.1.167`, override
  per call with `LV_UI_HOST`), key `~/.ssh/localvoxtral-ui-gate`;
  `--host` prints what it resolved, `--disconnect` closes the master. It
  adds no verb of its own — everything is validated on the Mac. The loop
  that is now fast: `state` once (read `takeover.leased` and
  `setup.helper.mode`), then `ax find <selector>` instead of `ax dump` to
  locate a control, then `batch` for a whole step
  (`./scripts/mac-ui.sh batch <<'EOF' … EOF`, one verb per line, validated
  whole before anything runs, stops at the first failure, output framed by
  `==lvui-batch-<tag>==` lines). The owner's audible warning is still spoken
  and waited for on the FIRST GUI verb of a burst; verbs inside the
  120 s takeover lease skip it and "done" is spoken once when the burst
  goes quiet. The first GUI verb after the owner reinstalls the gate
  compiles the AX helper once (tens of seconds, said on stderr); every call
  after that runs the binary. The gate itself is installed and updated BY
  HAND by the owner only (`scripts/mac/README.md`, "Reinstalling after a
  gate change"); `state`'s `setup.gate.revision` tells you whether the Mac
  runs the revision in your tree.
- **Code signing (why TCC used to reset)**: `package_app.sh` signs with
  `$LOCALVOXTRAL_CODESIGN_IDENTITY` when set, else ad-hoc. The owner's Mac
  has a self-signed code-signing cert `localvoxtral-dev`; the identity env
  var is set in the owner's shell AND in the runner's `.env`
  (`~/actions-runner/.env`, restart via `cd ~/actions-runner && ./svc.sh
  stop && ./svc.sh start`). Identity-signed builds keep their Accessibility
  (TCC) grant across rebuilds; ad-hoc builds get a fresh signature each time
  and macOS silently invalidates the old grant (fix: toggle the app off/on in
  System Settings → Accessibility). Microphone is gentler: a copy with
  another signature (an ad-hoc `/Applications` copy against an
  identity-signed `try-pr.sh` copy) is simply asked again, and the dialog
  can open on another display, so **Allow microphone…** looks like it did
  nothing (owner, 2026-09-22). tccd's `Failed to match existing code
  requirement … kTCCServiceMicrophone` line before `AUTHREQ_PROMPTING` is
  that re-prompt, not a fault. First codesign with a new key needs one
  GUI "Always Allow" keychain prompt — trigger it with a local
  `package_app.sh` run before relying on CI, or the runner job hangs.
  The same identity-vs-hash rule protects the tier-2 lanes' TCC grants: the
  `com.localvoxtral.runner-node-resign` LaunchAgent re-signs the runner's
  bundled `externals/node*` with `localvoxtral-dev` after every runner
  auto-update so the Accessibility/Screen Recording grants survive
  (`scripts/mac/runner-node-resign.sh`, owner runbook `scripts/mac/README.md`).
- **macOS 26 launch stall**: first launch of a *downloaded* ad-hoc-signed
  bundle stalls forever at `_dyld_start` (Gatekeeper first-exec scan);
  `xattr -cr` does NOT fix it, a LOCAL `codesign --force --deep --sign -`
  does. `install.sh` re-signs unconditionally for end users; `try-pr.sh`
  re-signs only ad-hoc artifacts (never downgrades identity-signed ones).
  Durable fix is Developer ID + notarization (roadmap #1).
- **Field bug on the Mac? Dispatch `mac-crashlog.yml` FIRST, theorize
  second** (`gh workflow run mac-crashlog.yml --ref main`). It reports, all
  redacted for the public Actions log: recent crash summaries (procPath +
  translocation + crashed-thread frames), running localvoxtral instances
  with their binary paths, an allowlisted settings snapshot, the app's
  subsystem-filtered unified log, and an exact reproduction of the model
  pre-download command. Confirm WHICH binary the user is actually running
  (try-pr copy vs /Applications) before debugging its behavior — that
  confusion and theorize-first cost an hour on 2026-07-05. Deeper tools:
  `scripts/mac-diag.sh` on the Mac, Export Diagnostics… in Settings > About,
  and (once the v2 gate is installed — owner runbook: `scripts/mac/README.md`)
  `./scripts/remote-build.sh diag|applog|voxlog|svc-status|disk|gc`.
- **"Why won't this terminal join a Claude session?"** — `--probe-surface`
  resolves the join for the frontmost surface once, prints it, and exits
  without a menu bar item or any other UI:

  ```
  /Applications/localvoxtral.app/Contents/MacOS/localvoxtral --probe-surface
  /Applications/localvoxtral.app/Contents/MacOS/localvoxtral --probe-surface --json
  ```

  Run it **from the terminal you would dictate into**: that terminal is the
  frontmost application, so it is the surface being probed. Run the binary
  **inside the .app bundle**, not a `.build/debug` copy: TCC keys grants to a
  code signature, so an unsigned loose build can only ever report
  `probe: accessibility permission not granted`. UNVERIFIED as of this writing
  (2026-08-28), and worth confirming on the first real run: whether a bundled
  binary started from a shell is attributed to the app's own identity or to the
  terminal as its responsible process. If it is the latter, the first probe
  raises consent prompts naming the terminal, and a refused Accessibility grant
  shows up as that same named reason rather than as anything about the surface.

  `--json` prints one line: `arm`, `abstentionReason`, `origin`, `terminal`,
  `herdrBound`, `workspaceIsLocal` — the same six fields, from the same
  mapper, as a dogfood record's `join` block
  (`ClaudeSessionJoinSummary`). Exit status is 0 when an arm joined, 1 when
  none did, 2 on a usage error.

  **`abstentionReason` is the diagnostic**, not `arm`. It is the resolver's own
  cause chain, oldest arm first — `tty: no live session on this device;
  remote-herdr: ssh session undeterminable (unreadableArguments)` says the tty
  read worked and the ssh probe could not read
  the client's arguments, which is a completely different bug from an empty
  chain (the surface was never identified at all). This is the signal that was
  missing when a Ghostty ssh wrapper made every remote probe report
  `undeterminable` (2026-08-03).

  **Claude Desktop is not frontmost while you type the command**, so it gets
  its own flag: `--probe-surface --desktop` probes the session focused inside
  the running Claude Desktop, with the Desktop arm's Accessibility read wired
  in (it is withheld otherwise, because it switches Electron's accessibility
  tree on).

  Two limits to read the output with. **The registry is the app's saved
  copy**: live session records live in the running app, built from hook
  traffic its broker received, and the verb restores what the app last saved
  to disk (read-only, through the app's own restore checks). It says so first
  when that is empty (`probe: no live Claude sessions in the registry`) — the
  arms then decline for that reason, and what you are reading is how far each
  one got on the SURFACE side. **The remote-herdr arm is read-only here by construction**: the
  forward and panel-metadata capabilities are passed as `nil`, so the probe
  cannot open an `ssh -L` that outlives it or leave an `lv-mic-…` stamp in an
  agents panel, and there is no flag that turns them on. It reaches
  `forward capability unavailable` and stops. Same reasoning withholds the cmux
  arm (Keychain prompt), the browser arm (reads the address bar), and every
  screen read.

  **After the fact, read the dictation's own line.** Every dictation writes one
  `.notice` line naming the arm that joined, or the gate or abstention chain
  that stopped it, and `.notice` survives in the unified log where the arms'
  `.info` lines do not:

  ```
  log show --last 1h --predicate 'subsystem == "com.localvoxtral" AND eventMessage BEGINSWITH "Claude join outcome"'
  ```

  `arm=none origin=none causes=gate: Claude Desktop target without session context`
  means the join was never attempted; `causes=desktopSession: no live session
  reports this desktop session` means the view was a session whose hooks never
  reached this Mac. The line carries no id, path or host, so it is safe to
  paste into an issue.

  Both of those limits are gone in a **dogfood build with the control socket
  armed** (`docs/dogfood-builds.md`): `surface probe` runs the same
  `ClaudeSurfaceProbe.summarize` decision INSIDE the app, so it resolves
  against the registry the broker has been filling since launch and against
  the app's full-capability resolver. `registry list` beside it answers the
  question the one-shot probe cannot — whether the chain reads that way
  because the registry is empty or because the surface was not identified. Use
  the verb here when you have the shipping binary and the socket when you are
  dogfooding; they print the same six fields from the same mapper.
- **README demo video**: `./scripts/record-demo.sh` on the Mac (GUI session)
  stages the scene, drives the real Right-Command tap/hold gesture with
  synthetic CGEvents, records, and encodes `dist/demo/demo.mp4`; the operator
  speaks the prompted lines. On the self-hosted runner, dispatch
  `record-demo.yml` instead: it runs hands-free (`DEMO_HANDS_FREE=1` — TTS
  through the BlackHole loopback, app mic pinned to it) and uploads the video
  as an artifact; one-time runner setup is `brew install blackhole-2ch
  ffmpeg`. GitHub renders inline video only from user-attachments URLs (no
  API for those), so the owner drag-drops the mp4 into a PR comment and
  pastes the URL into the README by hand.
  `DEMO_TERMINAL_AGENT=herdr` (explicit only, never auto) records the herdr
  pane-join scene — split panes in an isolated named herdr session, dictation
  into the focused Claude pane, log-asserted herdr join + pane.read context.
- **Dogfooding context capture** (`Sources/localvoxtral/Dogfood`): the app logs
  context COUNTS only, on purpose, which also makes a retrieval miss
  unattributable after the fact. The capture is the gated exception — it records
  the join outcome, the screen decision and its cause, each source's harvest and
  proposals, budget demands vs. grants, the rendered prompts, and the model's
  reply, so a wrong term can be blamed on exactly one of four stages
  (retrieval / matcher / conflict / budget). Records also carry a content-free
  behavioral signal (`DogfoodEditSignalWatcher`): a bounded post-commit window
  — 2 s for 1–5 words up to 15 s for very long transcripts — watching for the
  user immediately erasing what was inserted (Backspace, forward delete, or ⌘A).
  Only the gesture, a bucketed delay, the word-count bucket, and the output mode are
  recorded; no key content and no other key at all. It is a GLOBAL `NSEvent`
  keyDown observer (no new permission — the same Accessibility trust insertion
  already needs), installed only while a window is open and torn down the
  instant it closes, and the record is patched in place afterwards rather than
  held back for the window (a held record is lost to any quit). The `clean` and
  `superseded` outcomes are recorded too: without the negative there is no
  denominator. It is behind a COMPILE flag
  (`LOCALVOXTRAL_DOGFOOD`, or the gitignored `.dogfood-capture-enable` marker
  that crosses the build gate) plus a runtime opt-in
  (`defaults write com.localvoxtral.app debug.dogfood_capture_enabled -bool true`).
  Shipped releases do not contain it, and there is deliberately no uploader —
  records are local files under Application Support. Fastest install:
  `./scripts/try-pr.sh main --dogfood` (CI-built opt-in artifact, stamp
  verified, capture default armed automatically). `dogfood-package` remains
  the local-build equivalent; both keep the bundle id so the TCC grant
  survives and stamp `LVXDogfoodCapture` into Info.plist so you can tell
  which binary you are running — as does Settings > About's constant "Build"
  row (`DogfoodBuildStatus`), which also shows whether capture is armed in
  this process. User-facing docs: `docs/dogfood-builds.md`.
