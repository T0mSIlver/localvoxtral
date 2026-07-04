# Workflow Notes

## `ci.yml`

Every PR and push to main: build, unit tests, live voxmlx integration tests,
app packaging, launch smoke test, and an installable app artifact
(`localvoxtral-app`, fetch with `scripts/try-pr.sh`). Same-repo branches run
on the self-hosted Mac runner; fork PRs run on GitHub-hosted macOS.

## `release.yml`

One-command, gate-then-tag releases on the self-hosted runner:

```bash
./scripts/release.sh            # patch bump
./scripts/release.sh minor      # or major, or an explicit X.Y.Z
```

Pipeline: compute next version from the latest `v*` tag → release build →
unit tests → live integration tests (voxmlx) → package app bundle → launch
smoke test → zip + dmg → **create tag** → publish GitHub release with
auto-generated notes and both artifacts.

The tag is created only after every gate passes, so a failed release leaves
no orphan tag. Releases are ad-hoc signed on purpose (a local signing cert
means nothing on users' machines); proper distribution signing needs a
Developer ID cert. Dispatch-only: pushing tags by hand no longer triggers a
release.

## `dmg-test.yml`

Manual-dispatch harness on the self-hosted Mac runner that packages the app,
builds the styled DMG, verifies it with `hdiutil`, and uploads it for eyeballing.

## `mlx-lm-test.yml`

Manual-dispatch harness that installs `mlx_lm.server` from any ref of the
T0mSIlver/mlx-lm fork on the self-hosted runner, serves the polishing model,
and probes chat/completions through the prompt-cache path. Used to verify
fork changes (MLX needs Apple Silicon).
