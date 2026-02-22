# Changelog

All notable changes to this project are documented in this file.

## [0.3.0] - 2026-02-22

### Added
- Configurable global dictation shortcut with validation and persistence.
- Network connectivity monitoring plus realtime session health indicators.
- Microphone input device selection, recovery callbacks, and capture health monitoring.
- Robust transcript merge utilities with broad unit and integration coverage.

### Changed
- Unified provider flow for OpenAI-compatible realtime endpoints (`vLLM`/`voxmlx`) and `mlx-audio`.
- Hardened connection lifecycle: connect timeout handling, connection-failure alerts, and richer logging.
- Improved settings UX, including auto-paste controls and reordered sections.
- Packaging pipeline now assembles required dependency resource bundles inside the app artifact.

### Fixed
- Duplicate insertion on `mlx-audio` disconnect/finalization paths.
- Multiple microphone capture race/lifecycle edge cases in restart/reconfigure flows.
- Transcript edge cases for formatting overlap, replay dedupe, and punctuation spacing.
- Command-V fallback insertion now restores clipboard contents after temporary pasteboard use.

### Validation
- `swift build -c release`
- `swift test`
- `swift test --sanitize=thread`
- `./scripts/package_app.sh release 0.3.0 1`
