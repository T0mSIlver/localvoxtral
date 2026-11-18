#!/usr/bin/env bash
# sparkle-strings-without-em-dash.py on a fixture Sparkle.framework: binary
# plist strings in Base and another language, Versions/Current a symlink.
#   ./scripts/ci/test-sparkle-strings.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/packaging/sparkle-strings-without-em-dash.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lv-sparkle-strings.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

F="$TMP/Sparkle.framework"
python3 -I - "$F" <<'PY'
import os, plistlib, sys
f = sys.argv[1]
res = os.path.join(f, "Versions", "B", "Resources")
key = "%@ %@ is now available—you have %@. Would you like to download it now?"
for lang, value in {
    "Base": "%1$@ %2$@ is now available—you have %3$@. Would you like to download it now?",
    "pt-BR": "O app %1$@ %2$@ está disponível — sua versão é %3$@. Deseja baixá-lo agora?",
    "fr": "%1$@ %2$@ est disponible (vous avez %3$@).",
}.items():
    os.makedirs(os.path.join(res, lang + ".lproj"))
    with open(os.path.join(res, lang + ".lproj", "Sparkle.strings"), "wb") as out:
        plistlib.dump({key: value, "Cancel": "Cancel"}, out, fmt=plistlib.FMT_BINARY)
os.symlink("B", os.path.join(f, "Versions", "Current"))
PY
cp "$F/Versions/B/Resources/fr.lproj/Sparkle.strings" "$TMP/fr-before"

out="$(python3 -I "$SCRIPT" "$F")"
[[ "$out" == *"2 em dash string(s) rewritten in 3 file(s)"* ]] || fail "unexpected summary: $out"
pass "each real file once, through the Versions/Current symlink: $out"

read_key() {
  python3 -I -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); print(d["%@ %@ is now available—you have %@. Would you like to download it now?"])' "$1"
}
base="$(read_key "$F/Versions/B/Resources/Base.lproj/Sparkle.strings")"
[[ "$base" == '%1$@ %2$@ is now available. You have %3$@. Would you like to download it now?' ]] || fail "Base: $base"
pass "English: $base"
pt="$(read_key "$F/Versions/B/Resources/pt-BR.lproj/Sparkle.strings")"
[[ "$pt" == 'O app %1$@ %2$@ está disponível, sua versão é %3$@. Deseja baixá-lo agora?' ]] || fail "pt-BR: $pt"
pass "other languages get a comma: $pt"
head -c 6 "$F/Versions/B/Resources/Base.lproj/Sparkle.strings" | grep -q bplist || fail "Base.lproj is no longer a binary plist"
pass "the strings stay binary plists"
cmp -s "$TMP/fr-before" "$F/Versions/B/Resources/fr.lproj/Sparkle.strings" || fail "a file without an em dash was rewritten"
pass "a file without an em dash is left byte for byte"

echo "OK: sparkle-strings"
