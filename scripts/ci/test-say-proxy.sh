#!/usr/bin/env bash
# Tests say-proxy.sh against a fake say: what it runs, what it refuses.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
PROXY="$ROOT_DIR/scripts/ci/say-proxy.sh"
work="$(mktemp -d)"
proxy_pid=""
cleanup() {
  [ -n "$proxy_pid" ] && kill "$proxy_pid" 2>/dev/null && wait "$proxy_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# The fake lists two voices and prints the arguments it got, one per line.
cat >"$work/say" <<'FAKE'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "$1" = -v ] && [ "$2" = '?' ]; then
  printf '%-30s%s\n' 'Samantha (English (US))' 'en_US    # Hello' 'Thomas' 'fr_FR    # Bonjour'
  exit 0
fi
printf '%s\n' "$@"
exit 3
FAKE
chmod +x "$work/say"

mkdir -p "$work/out"
SAY_PROXY_SAY="$work/say" "$PROXY" "$work/proxy" "$work/out" >"$work/proxy.log" 2>&1 &
proxy_pid=$!
for i in $(seq 1 100); do
  grep -q watching "$work/proxy.log" 2>/dev/null && break
  sleep 0.1
done
grep -q "2 voices, watching" "$work/proxy.log" || fail "proxy did not start: $(cat "$work/proxy.log")"

n=0
# request <arg>...: submits a request, waits for its status, and leaves the
# status in $status, stdout in $out and stderr in $err.
request() {
  n=$((n + 1))
  local id="r$n" i
  if [ "$#" -gt 0 ]; then
    printf '%s\0' "$@" >"$work/proxy/requests/$id.tmp"
  else
    : >"$work/proxy/requests/$id.tmp"
  fi
  mv "$work/proxy/requests/$id.tmp" "$work/proxy/requests/$id.req"
  for i in $(seq 1 100); do
    [ -e "$work/proxy/results/$id.status" ] && break
    sleep 0.1
  done
  [ -e "$work/proxy/results/$id.status" ] || fail "request $id: no status after 10 s ($(cat "$work/proxy.log"))"
  [ ! -e "$work/proxy/requests/$id.req" ] || fail "request $id: request not deleted"
  status="$(cat "$work/proxy/results/$id.status")"
  out="$(cat "$work/proxy/results/$id.out")"
  err="$(cat "$work/proxy/results/$id.err")"
}

refused() {
  local description="$1" expected="$2"
  shift 2
  request "$@"
  [ "$status" = 64 ] || fail "$description: status $status, expected 64"
  case "$err" in *"$expected"*) ;; *) fail "$description: stderr '$err' lacks '$expected'" ;; esac
  printf 'PASS: %s\n' "$description"
}

request -v '?'
[ "$status" = 0 ] || fail "listing: status $status"
case "$out" in *Thomas*fr_FR*) ;; *) fail "listing: output '$out'" ;; esac
echo "PASS: -v ? runs and its listing lands in .out"

request -o "$work/out/a.wav" --file-format=WAVE --data-format=LEI16@16000 \
  -v 'Samantha (English (US))' 'l'"'"'heure $(touch '"$work"'/pwned)'
[ "$status" = 3 ] || fail "synthesis: status $status, expected the fake's 3"
expected="$(printf '%s\n' -o "$work/out/a.wav" --file-format=WAVE --data-format=LEI16@16000 \
  -v 'Samantha (English (US))' 'l'"'"'heure $(touch '"$work"'/pwned)')"
[ "$out" = "$expected" ] || fail "synthesis: say got '$out'"
[ ! -e "$work/pwned" ] || fail "synthesis: the text was evaluated"
echo "PASS: synthesis passes every argument through verbatim, exit code included"

request -v Thomas 'Bonjour'
[ "$status" = 3 ] || fail "voice only: status $status"
echo "PASS: -v and text alone are accepted"

refused "an unlisted voice is refused" "voice not listed" -v Albert hello
refused "an output path outside the roots is refused" "outside the allowed roots" -o /tmp/x.wav hello
refused "a .. path is refused" "outside the allowed roots" -o "$work/out/../x.wav" hello
refused "text starting with - is refused" "text starts with -" -v Thomas --interactive
refused "an unknown option is refused" "unexpected argument" -f /etc/passwd hello
refused "a data format with shell characters is refused" "bad data format" '--data-format=a;b' hello
refused "an empty request is refused" "no arguments"
