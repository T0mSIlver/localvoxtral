# Showing the owner a view

`ViewSnapshotTests` renders the app's views to PNG inside a normal test
process, so a GitHub-hosted runner can produce them: no packaged app, no Mac,
no UI gate. Use it when the owner should see what a view looks like. PRs don't
need screenshots.

## Get the PNGs

Push the branch, then:

```bash
./scripts/view-snapshots.sh [--filter ViewSnapshotTests/<test>] [branch]
```

It dispatches `.github/workflows/view-snapshots.yml` on the branch as GitHub
has it, waits for that run, downloads the PNGs to
`.build/view-snapshots/<short sha>/` and prints one path per line. Send the
ones that matter with `SendUserFile`, or embed them in a PR body through the
orphan `pr-assets` branch (commit-pinned raw URLs).

`--filter` takes the whole class (default) or one case, such as
`testSettingsPanes`; nothing else runs there. On a Mac, `swift test --filter
ViewSnapshotTests` writes the same PNGs to `.build/snapshots/`. The build
host's SSH gate refuses copying files back, so from Linux use the script.

## Add a view or a state

Add a case to `Tests/localvoxtralTests/ViewSnapshotTests.swift`, or a state to
an existing case's list, and render it with `record(_:name:width:height:growToFit:)`:

- Build the model from the fakes in `TestSupport` over `makeSettings()`, then
  set the state you want on it. Pass a `ManualSessionClock`, as every view
  model test does.
- Nothing personal may reach an image: the artifacts are public. No real
  transcripts, paths, host names or device names; the fakes already avoid
  them.
- `growToFit: true` grows the window until no scroll view has content below
  the fold, so a long Settings pane is pictured whole.
- A view that loads in `.task` needs its data injected, not awaited: the
  History and Insights panes take a model or fixed numbers for this.

## What the pictures are and are not

- Rendering waits on run-loop turns (`RunLoop.main.run(before: .distantPast)`),
  never on the clock.
- `ShortcutRecorderField` draws a dashed "Shortcut" box: the real control
  traps without the `Assets.car` only `package_app.sh` compiles.
- The status popover is an `NSMenu` in the app; hosted in a window it draws
  as the buttons it is made of.
- The overlay sits on a flat gray backdrop; its blur needs a real desktop.
- The renders are identical from run to run on one machine image (5 runs on
  the build host, 2 hosted runs on one runner image, all 27 images) and differ
  between machines, so nothing compares them against stored images: a
  reference would go red on every runner-image update (#572).
