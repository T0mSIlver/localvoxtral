#!/usr/bin/env bash
# Regression test for install.sh release-asset resolution (issue #131).
#
# v0.7.4 started shipping dSYM archives next to the app zip, and the GitHub
# API lists them first, so "take the first .zip asset" resolved the
# debug-symbol archive and the install failed at extraction. This test runs
# install.sh in dry-run mode against a stubbed curl serving a fixture that
# mirrors the real v0.7.4 API asset ordering, and asserts the app zip wins.
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
  local fixture="$1"
  PATH="$TMP_DIR/bin:$PATH" LV_TEST_FIXTURE="$fixture" \
    LOCALVOXTRAL_INSTALL_DRYRUN=1 LOCALVOXTRAL_VERSION=v0.7.4 \
    bash "$ROOT_DIR/scripts/install.sh"
}

# Case 1: real v0.7.4 asset ordering (dSYM zip listed before the app zip),
# plus the polishd dSYM zip that release.yml attaches to newer releases.
cat > "$TMP_DIR/release.json" <<'JSON'
{
  "tag_name": "v0.7.4",
  "assets": [
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.dmg"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.dmg.sha256"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.dSYM.zip"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-polishd-v0.7.4.dSYM.zip"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.zip"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.zip.sha256"}
  ]
}
JSON

output="$(run_resolve "$TMP_DIR/release.json")" || fail "install.sh dry run exited non-zero:
$output"
resolved="$(printf '%s\n' "$output" | sed -n 's/^Resolved zip: //p')"
expected="https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.zip"
[ "$resolved" = "$expected" ] ||
  fail "resolved '$resolved', expected '$expected'"
echo "PASS: app zip wins over dSYM zips"

# Case 2: a release with only dSYM zips must die loudly, not install symbols.
cat > "$TMP_DIR/release-dsym-only.json" <<'JSON'
{
  "tag_name": "v0.7.4",
  "assets": [
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.dSYM.zip"}
  ]
}
JSON

if output="$(run_resolve "$TMP_DIR/release-dsym-only.json" 2>&1)"; then
  fail "expected failure when only dSYM zips exist, got:
$output"
fi
printf '%s\n' "$output" | grep -q 'No .zip asset found' ||
  fail "expected 'No .zip asset found' error, got:
$output"
echo "PASS: dSYM-only release fails with a clear error"

echo "OK: all install.sh resolution tests passed"
