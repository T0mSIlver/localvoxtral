# Release Workflow Notes

## `release.yml`

This workflow publishes the macOS app zip to GitHub Releases.

- Trigger (`push`): when a tag matching `v*.*.*` is pushed (for example `v0.3.0`)
- Trigger (`workflow_dispatch`): manual run for an existing tag using the `tag` input

Pipeline steps:

1. Check out source (`push` ref or selected tag).
2. Derive `tag` and `version` metadata (version is tag without the `v` prefix).
3. Install Swift 6.2.
4. Run `swift build -c release`.
5. Run `swift test`.
6. Package app bundle with:
   - `./scripts/package_app.sh release <version> <github_run_number>`
7. Zip app bundle to:
   - `dist/localvoxtral-<tag>.zip`
8. Create/update GitHub release for the tag and upload the zip asset.

## Local release command

Use this from repo root:

```bash
./scripts/release.sh vX.Y.Z
```

What it does:

1. Verifies clean git state and `main` branch.
2. Runs local build/tests.
3. Packages and zips local app artifact.
4. Pushes `main`.
5. Creates and pushes the tag, which triggers `release.yml`.
