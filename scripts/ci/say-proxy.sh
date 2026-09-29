#!/usr/bin/env bash
# say-proxy.sh <dir> [allowed output root]...
#
# Runs `say` for the agent-dictation eval (#960). Anything xctest starts under
# the Actions runner, launchd jobs included, lists only the built-in voices,
# while the runner's shell lists the downloaded ones. eval-e2e starts this
# loop from a shell step; EvalChildProcess, given LV_EVAL_SAY_PROXY_DIR, hands
# it requests.
#
# A request is <dir>/requests/<id>.req: say's arguments, each ended by a NUL,
# renamed into place once complete. The loop runs say with them, stdout to
# <dir>/results/<id>.out and stderr to <id>.err, then renames <id>.status
# (the exit code) into place and deletes the request. Arguments are checked,
# never evaluated; a rejected request gets status 64 and the reason in .err.
# Accepted, in this order:
#   -v ?                                       the voice listing
#   [-o <path>] [--file-format=WAVE] [--data-format=<fmt>] [-v <voice>] <text>
# with <voice> a name `say -v ?` listed at start, <path> under an allowed
# output root (default: $RUNNER_TEMP and the eval's wav cache), and <text> not
# starting with "-".
#
# SAY_PROXY_SAY names the say binary (tests pass a fake). Written for bash 3.2.
set -uo pipefail

dir="${1:?usage: say-proxy.sh <dir> [allowed output root]...}"
shift
if [ "$#" -gt 0 ]; then
  roots=("$@")
else
  roots=("${RUNNER_TEMP:-/nonexistent}" "$HOME/Library/Caches/localvoxtral-eval/wav")
fi
say="${SAY_PROXY_SAY:-/usr/bin/say}"
requests="$dir/requests"
results="$dir/results"
mkdir -p "$requests" "$results"

voices="$dir/voices.txt"
"$say" -v '?' 2>/dev/null | sed -E 's/ {2,}.*//' >"$voices"
echo "say-proxy: $(wc -l <"$voices" | tr -d ' ') voices, watching $requests"

allowed_path() {
  local path="$1" root
  case "/$path/" in */../*|*/./*) return 1 ;; esac
  for root in "${roots[@]}"; do
    case "$path" in "$root"/*) return 0 ;; esac
  done
  return 1
}

# check <arg>...: prints nothing and succeeds, or prints the reason.
check() {
  if [ "$#" -eq 2 ] && [ "$1" = -v ] && [ "$2" = '?' ]; then
    return 0
  fi
  [ "$#" -ge 1 ] || { echo "no arguments"; return 1; }
  while [ "$#" -gt 1 ]; do
    case "$1" in
      -o)
        [ "$#" -gt 2 ] || { echo "-o without a path"; return 1; }
        allowed_path "$2" || { echo "output path outside the allowed roots: $2"; return 1; }
        shift 2 ;;
      -v)
        [ "$#" -gt 2 ] || { echo "-v without a voice"; return 1; }
        grep -Fxq -- "$2" "$voices" || { echo "voice not listed: $2"; return 1; }
        shift 2 ;;
      --file-format=WAVE) shift ;;
      --data-format=*)
        case "${1#--data-format=}" in
          ''|*[!A-Za-z0-9@]*) echo "bad data format: $1"; return 1 ;;
        esac
        shift ;;
      *) echo "unexpected argument: $1"; return 1 ;;
    esac
  done
  case "$1" in -*) echo "text starts with -: $1"; return 1 ;; esac
  return 0
}

serve() {
  local request="$1" id args reason status
  id="$(basename "$request" .req)"
  args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done <"$request"
  rm -f "$request"
  if reason="$(check ${args[@]+"${args[@]}"})"; then
    "$say" "${args[@]}" >"$results/$id.out" 2>"$results/$id.err"
    status=$?
  else
    : >"$results/$id.out"
    echo "say-proxy refused: $reason" >"$results/$id.err"
    status=64
  fi
  echo "$status" >"$results/$id.status.tmp"
  mv "$results/$id.status.tmp" "$results/$id.status"
}

trap 'exit 0' TERM INT
while :; do
  for request in "$requests"/*.req; do
    [ -e "$request" ] && serve "$request"
  done
  sleep 0.1
done
