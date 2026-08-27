# Hand-testing & field debugging (the fast loop)

Learned the hard way (2026-07-04) — use these instead of manual steps:

- **Trying a PR build on the Mac**: `./scripts/try-pr.sh <pr-number|main>`
  downloads the exact CI-built artifact and launches it. No checkout, no
  build. Push → CI (~1.5 min) → try-pr.sh is the whole owner iteration loop.
  `--dogfood` fetches the instrumented `localvoxtral-app-dogfood` artifact
  instead, verifies its `LVXDogfoodCapture` stamp, arms the runtime capture
  default, and launches — the one-command dogfood install. That artifact is
  opt-in in CI (`[dogfood-package]` in the PR body / head commit message, or
  a `workflow_dispatch` with `dogfood=true`); when the target run lacks it,
  the script offers to trigger a dispatch build and shows the latest run
  that has one.
- **Code signing (why TCC used to reset)**: `package_app.sh` signs with
  `$LOCALVOXTRAL_CODESIGN_IDENTITY` when set, else ad-hoc. The owner's Mac
  has a self-signed code-signing cert `localvoxtral-dev`; the identity env
  var is set in the owner's shell AND in the runner's `.env`
  (`~/actions-runner/.env`, restart via `cd ~/actions-runner && ./svc.sh
  stop && ./svc.sh start`). Identity-signed builds keep their Accessibility
  (TCC) grant across rebuilds; ad-hoc builds get a fresh signature each time
  and macOS silently invalidates the old grant (fix: toggle the app off/on in
  System Settings → Accessibility). First codesign with a new key needs one
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
