#!/usr/bin/env bash
# Drafts captures in #918's two stages on real backends
# (QuickCaptureTwoStageLiveTests): GLM 5.3 on the Mistral API writes the
# first draft, billed to the Vibe plan key (never the Studio key), then
# Claude Code checks each issue in the checkout. Prints each stage's time
# and cost; writes one markdown file per capture to --out. Linux only.
#
#   scripts/linux/quick-capture-two-stage.sh --root CHECKOUT --captures FILE --out DIR
#
# FILE is a JSON list of capture strings.
set -euo pipefail

cd "$(dirname "$0")/../.."
if [[ "$(uname)" != Linux ]]; then
  echo "quick-capture-two-stage: Linux only; never spend inference on the Mac" >&2
  exit 2
fi
root="" captures="" out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --captures) captures="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "quick-capture-two-stage: unknown flag $1" >&2; exit 2 ;;
  esac
done
[[ -n "$root" && -n "$captures" && -n "$out" ]] \
  || { echo "quick-capture-two-stage: --root, --captures and --out are required" >&2; exit 2; }
mkdir -p "$out"

# The Vibe plan key: VIBE_MISTRAL_API_KEY, else MISTRAL_API_KEY in ~/.vibe/.env.
key_file="$(mktemp)"
chmod 600 "$key_file"
if [[ -n "${VIBE_MISTRAL_API_KEY:-}" ]]; then
  printf '%s' "$VIBE_MISTRAL_API_KEY" >"$key_file"
else
  sed -n 's/^MISTRAL_API_KEY=//p' "$HOME/.vibe/.env" | tr -d "\"'" | head -n 1 >"$key_file"
fi
[[ -s "$key_file" ]] || { echo "quick-capture-two-stage: no Vibe plan key" >&2; exit 2; }

SWIFT="${SWIFT:-swift}"
SCRATCH="${LV_LINUX_SCRATCH:-.build/linux}"
SWIFT="$SWIFT" LV_LINUX_SCRATCH="$SCRATCH" ./scripts/core-tests-linux.sh --filter NoSuchTestBuildOnly >/dev/null
resolved_backup="$(mktemp)"
cp Package.resolved "$resolved_backup"
trap 'cat "$resolved_backup" >Package.resolved; rm -f "$resolved_backup" "$key_file"' EXIT
env -i HOME="$HOME" PATH="$HOME/.local/bin:$PATH" LANG="${LANG:-C.UTF-8}" LV_QUICK_CAPTURE_TWO_STAGE=1 \
  QC_ROOT="$(realpath "$root")" QC_CAPTURES="$(realpath "$captures")" QC_OUT="$(realpath "$out")" \
  QC_ENDPOINT=https://api.mistral.ai/v1/chat/completions QC_MODEL=zai-glm-5-3 QC_KEY_FILE="$key_file" \
  "$SWIFT" test --skip-build --scratch-path "$SCRATCH" --filter QuickCaptureTwoStageLiveTests
