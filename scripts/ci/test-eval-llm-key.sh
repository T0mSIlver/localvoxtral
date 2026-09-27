#!/usr/bin/env bash
# Regression test (#851): `remote-build.sh eval-llm` bills a GLM model to the
# Vibe plan key, never to an exported MISTRAL_API_KEY, which sessions fill
# with the pay-per-call Studio key. Other Mistral models keep MISTRAL_API_KEY.
#
# ssh and rsync are stubbed. The rsync stub reads the eval marker the run
# syncs to the Mac and logs the last four characters of its key.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
REMOTE_BUILD="$ROOT_DIR/scripts/remote-build.sh"
MARKER="$ROOT_DIR/.llm-polish-eval-enable.json"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-eval-llm-key-test.XXXXXX")"
trap 'for _ in 1 2 3 4 5 6 7 8 9 10; do rm -rf "$TMP_DIR" 2>/dev/null && break; /bin/sleep 0.1; done' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ ! -e "$MARKER" ]] || fail "a marker from another run is in the tree: $MARKER"

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home/.vibe"
cat >"$TMP_DIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$TMP_DIR/bin/rsync" <<STUB
#!/usr/bin/env bash
if [[ -f "$MARKER" ]]; then
  sed -n 's/.*"apiKey": "\([^"]*\)".*/\1/p' "$MARKER" | sed 's/.*\(....\)\$/\1/' >>"\$LV_TEST_KEY_LOG"
fi
exit 0
STUB
chmod +x "$TMP_DIR/bin/ssh" "$TMP_DIR/bin/rsync"
printf 'MISTRAL_API_KEY="vibe-plan-key-VIBE"\n' >"$TMP_DIR/home/.vibe/.env"

common_env=(
  "PATH=$TMP_DIR/bin:$PATH"
  "HOME=$TMP_DIR/home"
  "LV_BUILD_HOST=fake-host"
  "LV_TEST_ON_MAC=1"
  "LV_ALLOW_HEAVY_MAC_RUN=1"
  "LV_BUILD_DIR=work/localvoxtral-eval-llm-key-regression"
  "LOCALVOXTRAL_REMOTE_LOG=$TMP_DIR/remote-build.log"
  "LOCALVOXTRAL_GC_LOG=$TMP_DIR/last-gc.log"
  "MISTRAL_API_KEY=studio-key-STDO"
  # Empty reads as unset, so a key the caller's shell exports stays out.
  "VIBE_MISTRAL_API_KEY="
)

# $1 = model alias, $2 = expected last four characters, rest = extra env.
expect_key() {
  local model="$1" want="$2" got
  shift 2
  : >"$TMP_DIR/keys.log"
  env "${common_env[@]}" "LV_TEST_KEY_LOG=$TMP_DIR/keys.log" "$@" \
    "$REMOTE_BUILD" eval-llm https://api.mistral.ai "$model" \
    >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr" || true
  got="$(head -n 1 "$TMP_DIR/keys.log")"
  [[ "$got" == "$want" ]] \
    || fail "$model $*: marker key ends in '${got:-no marker synced}', want '$want': $(tail -n 5 "$TMP_DIR/stderr")"
}

expect_key mistral/zai-glm-5-3 VIBE
expect_key mistral/zai-glm-5-3 OVRD VIBE_MISTRAL_API_KEY=vibe-override-OVRD
expect_key mistral/mistral-medium-3-5 STDO

# No Vibe key: a GLM eval refuses instead of falling back to the Studio key.
rm "$TMP_DIR/home/.vibe/.env"
expect_key mistral/zai-glm-5-3 ""
grep -q 'bills the Vibe plan key' "$TMP_DIR/stderr" \
  || fail "a GLM eval with no Vibe key did not name it: $(cat "$TMP_DIR/stderr")"

printf 'PASS: eval-llm bills GLM to the Vibe plan key and other Mistral models to MISTRAL_API_KEY\n'
