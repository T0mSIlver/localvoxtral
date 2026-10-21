#!/usr/bin/env bash
# install.sh refuses an Intel Mac or a macOS older than 15 before it downloads
# anything, and lets Apple Silicon on 15+ through, including from a shell under
# Rosetta (where `uname -m` says x86_64). uname, sysctl and sw_vers are stubbed;
# curl is a stub that fails the test if a refused platform reaches it.
#
# No network: ./scripts/ci/test-install-platform.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-install-platform.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/uname" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -s) echo Darwin ;;
  -m) echo "${LV_TEST_UNAME_M:-arm64}" ;;
  *) echo Darwin ;;
esac
STUB
cat > "$TMP_DIR/bin/sysctl" <<'STUB'
#!/usr/bin/env bash
# Intel Macs have no hw.optional.arm64 key: sysctl prints an error and fails.
[ -n "${LV_TEST_ARM64:-}" ] || exit 1
echo "$LV_TEST_ARM64"
STUB
cat > "$TMP_DIR/bin/sw_vers" <<'STUB'
#!/usr/bin/env bash
echo "$LV_TEST_MACOS"
STUB
# Reached only past the platform check: records that, and stops the run.
cat > "$TMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo reached >"$LV_TEST_CURL_LOG"
exit 22
STUB
chmod +x "$TMP_DIR/bin/"*

# run <arm64 key> <macOS version> <uname -m>: prints the installer's stderr.
run() {
  rm -f "$TMP_DIR/curl.log"
  { PATH="$TMP_DIR/bin:$PATH" LV_TEST_ARM64="$1" LV_TEST_MACOS="$2" LV_TEST_UNAME_M="$3" \
    LV_TEST_CURL_LOG="$TMP_DIR/curl.log" bash "$ROOT_DIR/scripts/install.sh" >/dev/null; } 2>&1 || true
}

out="$(run "" 15.4 x86_64)"
[[ "$out" == *"needs a Mac with Apple Silicon"* ]] || fail "Intel Mac: got: $out"
[ ! -e "$TMP_DIR/curl.log" ] || fail "Intel Mac: the installer went on to curl"

out="$(run 1 14.7.1 arm64)"
[[ "$out" == *"needs macOS 15 or later; this Mac runs macOS 14.7.1"* ]] || fail "macOS 14: got: $out"
[ ! -e "$TMP_DIR/curl.log" ] || fail "macOS 14: the installer went on to curl"

out="$(run 1 "" arm64)"
[[ "$out" == *"needs macOS 15 or later"* ]] || fail "unreadable macOS version: got: $out"

out="$(run 1 15.0 arm64)"
[ -e "$TMP_DIR/curl.log" ] || fail "Apple Silicon on macOS 15 was refused: $out"

out="$(run 1 26.1 x86_64)"
[ -e "$TMP_DIR/curl.log" ] || fail "Apple Silicon under Rosetta was refused: $out"

out="$(run 0 15.4 x86_64)"
[[ "$out" == *"needs a Mac with Apple Silicon"* ]] || fail "hw.optional.arm64=0: got: $out"

printf 'PASS: install.sh refuses Intel and macOS < 15 before downloading, accepts Apple Silicon on 15+ (Rosetta shell too)\n'
