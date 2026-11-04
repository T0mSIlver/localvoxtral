#!/usr/bin/env bash
# Regression test for verify-cask-install.sh: brew must never load the cask
# from a tap it does not trust. Homebrew 7 refuses an untrusted tap ("Refusing
# to load cask ... from untrusted tap"). Since 7.0.11 only install, reinstall
# and upgrade trust a tap on their own, and they remember it; `brew tap` does
# not. That failed the v0.17.0 pin twice: on the throwaway tap (2026-11-03),
# then on the public tap's `brew audit` before install (cask.yml run
# 41816967159, 2026-11-04).
#
# `brew` is a stub on PATH that applies those rules. The stub app is absent
# on purpose: the script gets past `brew audit` and `brew install`, then stops
# at its own "does not exist" check, which is as far as a machine without the
# real app can follow it. What this proves is the order of the brew calls.
#   ./scripts/ci/test-verify-cask-install.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
VERIFY="$ROOT_DIR/scripts/ci/verify-cask-install.sh"

if [[ -e /Applications/localvoxtral.app ]]; then
  echo "SKIP: this machine has /Applications/localvoxtral.app, which verify-cask-install.sh refuses to run beside"
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-verify-cask-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home" "$TMP_DIR/taps"
: >"$TMP_DIR/calls"
: >"$TMP_DIR/trusted"
echo 'cask "localvoxtral" do end' >"$TMP_DIR/localvoxtral.rb"

# $1 = STUB_TRUST: "yes" for Homebrew 7 (has `brew trust`), "no" for older.
cat >"$TMP_DIR/bin/brew" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$STUB_DIR/calls"
case "$1" in
  tap-new) mkdir -p "$STUB_DIR/taps/$3" ;;
  tap) mkdir -p "$STUB_DIR/taps/$2" ;;
  --repository) echo "$STUB_DIR/taps/$2" ;;
  trust)
    [[ "$STUB_TRUST" == yes ]] || { echo "Error: Unknown command: brew trust" >&2; exit 1; }
    [[ "$2" == --help ]] || echo "$3" >>"$STUB_DIR/trusted"
    ;;
  audit)
    tap="${3%/*}"
    if [[ "$STUB_TRUST" == yes ]] && ! grep -qx "$tap" "$STUB_DIR/trusted"; then
      echo "Error: Refusing to load cask $3 from untrusted tap $tap." >&2
      exit 1
    fi
    ;;
  install|reinstall|upgrade)
    [[ "$STUB_TRUST" != yes || "${3:-}" != */*/* ]] || echo "${3%/*}" >>"$STUB_DIR/trusted"
    ;;
  style|uninstall|untap) ;;
  *) echo "stub brew: unexpected: $*" >&2; exit 64 ;;
esac
STUB
chmod +x "$TMP_DIR/bin/brew"

# run_verify <yes|no> [public]: returns the script's status; output in
# $TMP_DIR/out and err. Without "public" it installs through --cask-file.
run_verify() {
  local status=0 trust="$1"
  if [[ "${2:-}" == public ]]; then set --; else set -- --cask-file "$TMP_DIR/localvoxtral.rb"; fi
  : >"$TMP_DIR/calls"; : >"$TMP_DIR/trusted"
  HOME="$TMP_DIR/home" PATH="$TMP_DIR/bin:$PATH" STUB_DIR="$TMP_DIR" STUB_TRUST="$trust" \
    "$VERIFY" v0.17.0 ${1+"$@"} \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err" || status=$?
  return "$status"
}
line_of() { grep -n -m1 -E "$1" "$TMP_DIR/calls" | cut -d: -f1; }

run_verify yes && fail "the script passed without the app being installed"
grep -q "untrusted tap" "$TMP_DIR/err" && fail "brew audit hit an untrusted tap: $(cat "$TMP_DIR/err")"
grep -q "does not exist" "$TMP_DIR/err" || fail "the script did not get past brew audit and install: $(cat "$TMP_DIR/err")"
trust_line="$(line_of '^trust --tap localvoxtral-ci/pretest$')"
audit_line="$(line_of '^audit ')"
[[ -n "$trust_line" && -n "$audit_line" && "$trust_line" -lt "$audit_line" ]] \
  || fail "the throwaway tap must be trusted before brew audit: $(cat "$TMP_DIR/calls")"
pass "the throwaway tap is trusted before brew audit loads its cask"

run_verify no && fail "the script passed without the app being installed"
grep -q "does not exist" "$TMP_DIR/err" || fail "without brew trust the script did not reach the install: $(cat "$TMP_DIR/err")"
grep -q '^trust --tap' "$TMP_DIR/calls" && fail "ran brew trust --tap on a Homebrew that has no such command"
pass "a Homebrew without brew trust is left alone"

# The public tap, as a user meets it: `brew tap` trusts nothing, so the first
# command that loads the cask must be the install.
run_verify yes public && fail "the script passed without the app being installed"
grep -q "untrusted tap" "$TMP_DIR/err" && fail "brew loaded the public tap's cask before anything trusted it: $(cat "$TMP_DIR/err")"
grep -q "does not exist" "$TMP_DIR/err" || fail "the public path did not reach the install: $(cat "$TMP_DIR/err")"
grep -v -- '--help' "$TMP_DIR/calls" | grep -q '^trust' && fail "the public path trusted the tap by hand, which a user never does"
pass "the public tap is first loaded by brew install, which trusts it as it does for a user"

echo "OK: verify-cask-install"
