#!/usr/bin/env bash
# Regression test for install.sh release-asset resolution (issue #131).
#
# v0.7.4 started shipping dSYM archives next to the app zip, and the GitHub
# API listed them first, so "take the first .zip asset" resolved the
# debug-symbol archive and the install failed at extraction. The fix selects
# the asset by its exact contractual name (localvoxtral-<tag>.zip, the name
# release.yml has produced for every release), so no ordering and no future
# extra zip asset can ever be picked by mistake. This test runs install.sh in
# dry-run mode against a stubbed curl serving hostile fixtures and asserts
# the app zip always wins — or that resolution fails loudly.
#
# Pure bash, no network, runs anywhere: ./scripts/ci/test-install-resolve.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-install-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Stub curl: writes the fixture named by LV_TEST_FIXTURE to the -o target and
# prints the HTTP code install.sh expects from -w '%{http_code}'.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 1
cat "$LV_TEST_FIXTURE" > "$out"
printf '200'
STUB
chmod +x "$TMP_DIR/bin/curl"

run_resolve() {
  local fixture="$1" version="$2"
  PATH="$TMP_DIR/bin:$PATH" LV_TEST_FIXTURE="$fixture" \
    LOCALVOXTRAL_INSTALL_DRYRUN=1 LOCALVOXTRAL_VERSION="$version" \
    bash "$ROOT_DIR/scripts/install.sh"
}

expected="https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.zip"

# Case 1: hostile asset ordering. Mirrors the real v0.7.4 API response (dSYM
# zip listed before the app zip, which triggered #131), plus the polishd dSYM
# zip release.yml attaches to newer releases, plus a hypothetical future
# non-dSYM zip listed first — the case a dSYM-only blocklist would get wrong.
cat > "$TMP_DIR/release.json" <<'JSON'
{
  "tag_name": "v0.7.4",
  "assets": [
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4-update.zip"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.dmg"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.dmg.sha256"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.dSYM.zip"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-polishd-v0.7.4.dSYM.zip"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.zip"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.zip.sha256"}
  ]
}
JSON

output="$(run_resolve "$TMP_DIR/release.json" v0.7.4)" || fail "install.sh dry run exited non-zero:
$output"
resolved="$(printf '%s\n' "$output" | sed -n 's/^Resolved zip: //p')"
[ "$resolved" = "$expected" ] ||
  fail "resolved '$resolved', expected '$expected'"
echo "PASS: exact app zip wins over dSYM zips and other zip assets"

# Case 2: a release without the contractual app zip must die loudly, not
# fall back to whatever zip is present (here: only a dSYM archive).
cat > "$TMP_DIR/release-dsym-only.json" <<'JSON'
{
  "tag_name": "v0.7.4",
  "assets": [
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.dSYM.zip"}
  ]
}
JSON

if output="$(run_resolve "$TMP_DIR/release-dsym-only.json" v0.7.4 2>&1)"; then
  fail "expected failure when the app zip asset is missing, got:
$output"
fi
case "$output" in
  *"has no asset named localvoxtral-v0.7.4.zip"*) ;;
  *) fail "expected 'has no asset named' error, got:
$output" ;;
esac
echo "PASS: release without the app zip fails with a clear error"

# Case 3: VERSION=latest — the expected asset name must come from the
# metadata's tag_name, not from LOCALVOXTRAL_VERSION.
output="$(run_resolve "$TMP_DIR/release.json" latest)" || fail "install.sh dry run (latest) exited non-zero:
$output"
resolved="$(printf '%s\n' "$output" | sed -n 's/^Resolved zip: //p')"
[ "$resolved" = "$expected" ] ||
  fail "latest resolved '$resolved', expected '$expected'"
echo "PASS: VERSION=latest resolves via the metadata tag_name"

echo "OK: all install.sh resolution tests passed"
