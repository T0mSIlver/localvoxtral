#!/usr/bin/env bash
# Remove abandoned SwiftPM/XCTest processes from this checkout only.
#
# The self-hosted runner keeps one persistent checkout per repository. A job
# cancelled while `swift test` is running can leave its driver or xctest host
# behind; later suites then stall at arbitrary tests. Never use a global
# `pkill`: the owner and parallel worktrees may be running legitimate tests.
set -euo pipefail

TERM_POLLS="${LOCALVOXTRAL_STALE_TEST_TERM_POLLS:-50}"
TERM_POLL_SECONDS="${LOCALVOXTRAL_STALE_TEST_TERM_POLL_SECONDS:-0.1}"

fail() {
  printf 'stale-test cleanup: %s\n' "$*" >&2
  exit 1
}

canonical_directory() {
  local directory="$1"
  (cd "$directory" 2>/dev/null && pwd -P)
}

is_test_process_name() {
  local name="${1##*/}"
  case "$name" in
    xctest|swift-package|swift-test|swiftpm-testing*|XCBBuildService|localvoxtral*) return 0 ;;
    *) return 1 ;;
  esac
}

# Input records are tab-separated: pid, uid, state, executable, start identity,
# evidence path. Evidence is an lsof cwd or mapped-text path; XCTest itself
# lives in Xcode, but its package test bundle remains mapped from `.build`.
# Output records are pid, executable, identity. Keeping selection pure makes
# every fail-closed boundary deterministic to regression-test.
select_candidates() {
  local workspace="$1" current_uid="$2" excluded_pids="$3"
  local pid uid state executable identity evidence_path

  while IFS=$'\t' read -r pid uid state executable identity evidence_path; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    case " $excluded_pids " in
      *" $pid "*) continue ;;
    esac
    [[ "$uid" == "$current_uid" ]] || continue
    [[ "$state" != Z* ]] || continue
    is_test_process_name "$executable" || continue
    [[ -n "$identity" && -n "$evidence_path" ]] || continue
    case "$evidence_path" in
      "$workspace"|"$workspace"/*)
        printf '%s\t%s\t%s\n' "$pid" "${executable##*/}" "$identity"
        ;;
    esac
  done
}

if [[ "${1:-}" == "--select" ]]; then
  [[ $# -eq 4 ]] || fail "usage: $0 --select <workspace> <uid> <excluded-pids>"
  workspace="$(canonical_directory "$2")" || fail "workspace is unreadable: $2"
  select_candidates "$workspace" "$3" "$4"
  exit 0
fi

[[ $# -eq 1 ]] || fail "usage: $0 <workspace-root>"
[[ "$TERM_POLLS" =~ ^[0-9]+$ ]] || fail "invalid TERM poll count"
command -v lsof >/dev/null 2>&1 || fail "lsof is required for cwd-scoped cleanup"

workspace="$(canonical_directory "$1")" \
  || fail "workspace is unreadable"
current_uid="$(id -u)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lv-stale-tests.XXXXXX")"
snapshot="$tmp_dir/processes.tsv"
metadata="$tmp_dir/metadata.tsv"
lsof_records="$tmp_dir/lsof.txt"
candidates="$tmp_dir/candidates.tsv"
trap 'rm -rf "$tmp_dir"' EXIT

excluded_pids="$$"
ancestor="$PPID"
while [[ "$ancestor" =~ ^[0-9]+$ && "$ancestor" -gt 1 ]]; do
  case " $excluded_pids " in
    *" $ancestor "*) break ;;
  esac
  excluded_pids="$excluded_pids $ancestor"
  ancestor="$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d '[:space:]' || true)"
done

# Do not inspect or print full command lines: agent/tool invocations sometimes
# carry secrets there. One ps snapshot plus one lsof field-mode snapshot avoids
# per-process forks; neither command requests argv. Join them by PID in awk.
while read -r pid uid state executable identity; do
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  [[ "$uid" == "$current_uid" && "$state" != Z* ]] || continue
  is_test_process_name "$executable" || continue
  case " $excluded_pids " in
    *" $pid "*) continue ;;
  esac
  [[ -n "$identity" ]] || continue
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$pid" "$uid" "$state" "$executable" "$identity"
done < <(ps -axo pid=,uid=,state=,ucomm=,lstart=) >"$metadata"

lsof -n -P -u "$current_uid" -a -d cwd,txt -F pn >"$lsof_records" 2>/dev/null || true
awk -F '\t' '
  FNR == NR { metadata[$1] = $0; next }
  substr($0, 1, 1) == "p" { pid = substr($0, 2); next }
  substr($0, 1, 1) == "n" && (pid in metadata) {
    print metadata[pid] "\t" substr($0, 2)
  }
' "$metadata" "$lsof_records" >"$snapshot"

select_candidates "$workspace" "$current_uid" "$excluded_pids" \
  <"$snapshot" | sort -t $'\t' -k1,1n -u >"$candidates"

if [[ ! -s "$candidates" ]]; then
  printf 'stale-test cleanup: no abandoned processes in %s\n' "$workspace"
  exit 0
fi

candidate_is_same_process() {
  local pid="$1" expected_executable="$2" expected_identity="$3"
  local uid state executable identity
  uid="$(ps -o uid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  state="$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  executable="$(ps -o ucomm= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
  identity="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
  [[ "$uid" == "$current_uid" \
    && -n "$state" && "$state" != Z* \
    && "${executable##*/}" == "$expected_executable" \
    && "$identity" == "$expected_identity" ]]
}

while IFS=$'\t' read -r pid executable identity; do
  candidate_is_same_process "$pid" "$executable" "$identity" || continue
  printf 'stale-test cleanup: TERM pid=%s executable=%s\n' "$pid" "$executable"
  kill -TERM "$pid" 2>/dev/null || true
done <"$candidates"

poll=0
while (( poll < TERM_POLLS )); do
  any_live=0
  while IFS=$'\t' read -r pid executable identity; do
    if candidate_is_same_process "$pid" "$executable" "$identity"; then
      any_live=1
      break
    fi
  done <"$candidates"
  (( any_live == 1 )) || break
  sleep "$TERM_POLL_SECONDS"
  poll=$((poll + 1))
done

while IFS=$'\t' read -r pid executable identity; do
  if candidate_is_same_process "$pid" "$executable" "$identity"; then
    printf 'stale-test cleanup: KILL pid=%s executable=%s\n' "$pid" "$executable"
    kill -KILL "$pid" 2>/dev/null || true
  fi
done <"$candidates"

remaining=0
while IFS=$'\t' read -r pid executable identity; do
  if candidate_is_same_process "$pid" "$executable" "$identity"; then
    printf 'stale-test cleanup: pid=%s executable=%s survived cleanup\n' \
      "$pid" "$executable" >&2
    remaining=1
  fi
done <"$candidates"

(( remaining == 0 )) || exit 1
printf 'stale-test cleanup: complete\n'
