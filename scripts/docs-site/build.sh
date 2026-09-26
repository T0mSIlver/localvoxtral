#!/bin/bash
# Builds the docs site into <out-dir>/site and checks the app's docs links
# against it. Needs Zensical on PATH, at the version the docs-site workflow pins.
#
# Usage: scripts/docs-site/build.sh [out-dir]   (default .build/docs-site)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../../.build/docs-site}"

python3 "$HERE/stage.py" "$OUT"
zensical build --clean --config-file "$OUT/zensical.toml"
python3 "$HERE/check-app-links.py" "$OUT/site"
