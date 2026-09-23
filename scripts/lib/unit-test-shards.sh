# shellcheck shell=bash
# Sourced. Runs the unit suite as N xctest processes at once (#442).
#
# `swift test --parallel` forks one xctest per test METHOD, about 4,000 spawns,
# and is slower than a serial run. This splits by test CLASS instead: one
# build, one listing, then N `swift test --skip-build --ignore-lock --filter …`
# runs side by side, each running whole classes in xctest's usual order. The
# classes are dealt to shards heaviest first, by the seconds in
# scripts/ci/unit-suite-seconds.txt (a class missing from it is weighed by its
# test count), so the slowest shard ends close to the others.
#
# Both callers use this: `remote-build.sh test` (each swift command goes over
# the build gate's ssh, which only admits `swift build …` and `swift test …`)
# and the hosted `build-test` step (scripts/ci/run-unit-shards.sh, local). The
# caller defines `lv_shard_swift ARGS…`, which runs `swift ARGS…` where the
# package lives, and calls `lv_run_unit_shards`.
#
# Written for bash 3.2 (the hosted macOS image's /bin/bash): no `wait -n`, no
# associative arrays, no mapfile.
#
# Stale weights only unbalance the shards. To refresh them after a full
# `./scripts/remote-build.sh test` on a quiet Mac:
#   bash -c '. scripts/lib/unit-test-shards.sh
#     lv_unit_suite_seconds .build/last-remote.log' >scripts/ci/unit-suite-seconds.txt

LV_SHARD_ROOT="${LV_SHARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LV_SHARD_WEIGHTS="${LV_SHARD_WEIGHTS:-$LV_SHARD_ROOT/scripts/ci/unit-suite-seconds.txt}"

# Per-class seconds from an XCTest log, heaviest first: "<seconds> <class>".
lv_unit_suite_seconds() {
  awk '
    /^Test Suite .* (passed|failed) at / {
      name = $0
      sub(/^Test Suite \047/, "", name)
      sub(/\047 .*/, "", name)
      pending = name
      next
    }
    pending != "" && /Executed [0-9]+ tests?, with/ {
      if (pending !~ /^(All tests|Selected tests|.*\.xctest)$/) {
        line = $0
        sub(/.* in [0-9.]+ \(/, "", line)
        sub(/\) seconds.*/, "", line)
        printf "%.3f %s\n", line, pending
      }
      pending = ""
    }
  ' "$@" | sort -k1,1rn -k2,2
}

# Reads `swift test list` output on stdin ("Module.Class/testMethod", one per
# line) and prints one line per shard: "<test count> <class> <class> …".
# Lines matching any extended regex in LV_SHARD_SKIP_PATTERNS (space
# separated, the same names the run passes to --skip) are dropped first.
# Any other line holding a "/" is a test id the shards cannot count (a Swift
# Testing test: a free function, a nested suite, "name()"), so the plan fails
# naming it rather than leave that test out.
#   $1  number of shards
#   $2  weights file ("<seconds> <class>" per line); may be missing
lv_plan_unit_shards() {
  local shards="$1" weights="$2"
  awk -v shards="$shards" -v skips="${LV_SHARD_SKIP_PATTERNS:-}" -v weights="$weights" '
    BEGIN {
      skip_count = split(skips, skip, " ")
      while ((getline line < weights) > 0) {
        if (split(line, field, " ") == 2) { seconds[field[2]] = field[1] + 0; known_total += field[1] }
      }
    }
    /\// {
      for (i = 1; i <= skip_count; i++) {
        if (skip[i] != "" && $0 ~ skip[i]) next
      }
      if ($0 !~ /^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\/[A-Za-z_][A-Za-z0-9_]*$/) {
        print "not an XCTest test id, which the shards cannot run and count: " $0 > "/dev/stderr"
        failed = 1
        exit 4
      }
      # A class is planned as "Module.Class": the package has more than one
      # test module (localvoxtralTests, localvoxtralCoreTests), and each
      # shard filter has to name the module its class lives in. The weights
      # file is keyed by the bare class name.
      split($0, parts, "/")
      class = parts[1]
      bare[class] = class
      sub(/^[^.]*\./, "", bare[class])
      if (!(class in tests)) { order[++class_count] = class }
      tests[class]++
      test_total++
    }
    END {
      if (failed) exit 4
      if (class_count == 0) exit 3
      # A class the weights file does not know yet is weighed at the known
      # classes average cost per test.
      known_tests = 0
      for (c in tests) if (bare[c] in seconds) known_tests += tests[c]
      per_test = (known_tests > 0) ? known_total / known_tests : 0.01
      if (per_test <= 0) per_test = 0.01
      for (i = 1; i <= class_count; i++) {
        c = order[i]
        weight[c] = (bare[c] in seconds) ? seconds[bare[c]] : tests[c] * per_test
      }
      # Heaviest first, ties by name, each to the lightest shard so far
      # (lowest index on a tie): the same input always gives the same plan.
      for (i = 1; i <= class_count; i++) sorted[i] = order[i]
      for (i = 2; i <= class_count; i++) {
        c = sorted[i]
        j = i - 1
        while (j >= 1 && (weight[sorted[j]] < weight[c] || \
            (weight[sorted[j]] == weight[c] && sorted[j] > c))) {
          sorted[j + 1] = sorted[j]
          j--
        }
        sorted[j + 1] = c
      }
      for (s = 1; s <= shards; s++) { load[s] = 0; count[s] = 0; members[s] = "" }
      for (i = 1; i <= class_count; i++) {
        c = sorted[i]
        best = 1
        for (s = 2; s <= shards; s++) if (load[s] < load[best]) best = s
        load[best] += weight[c]
        count[best] += tests[c]
        members[best] = members[best] " " c
      }
      for (s = 1; s <= shards; s++) {
        if (members[s] != "") print count[s] members[s]
      }
    }
  '
}

# Tests an XCTest log says it ran: the last "Executed N tests" line is the
# whole run's total. Prints 0 when there is none (a crash before the end).
lv_executed_test_count() {
  awk '/Executed [0-9]+ tests?, with/ { n = $0; sub(/.*Executed /, "", n); sub(/ .*/, "", n); last = n }
    END { print (last == "" ? 0 : last) }' "$1"
}


# lv_run_unit_shards <shards> <log> <skip-name>… [-- <extra swift test args>…]
#
# Builds, lists, plans and runs the shards, and writes ONE log: the build
# output, then each shard's whole output in shard order, then a summary line.
# Stdout gets the same lines, each shard's block once that shard and the
# ones before it have ended. Exit status is non-zero when the build or any shard fails,
# or when the shards together ran fewer tests than the listing holds (a class
# no --filter matched, a crash).
#
# LV_SHARD_BUILD_ARGS adds words to the build command (--enable-code-coverage).
lv_run_unit_shards() {
  local shards="$1" log="$2"
  shift 2
  local -a skip_args=() extra_args=()
  local skip_names=""
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    skip_args+=(--skip "$1")
    skip_names+="$1 "
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  extra_args=("$@")

  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/lv-unit-shards.XXXXXX")" || return 1
  mkdir -p "$(dirname "$log")"
  : >"$log"

  local started=$SECONDS build_status
  echo "==> Building the tests" | tee -a "$log"
  # shellcheck disable=SC2086  # a word list on purpose
  lv_shard_swift build --build-tests ${LV_SHARD_BUILD_ARGS:-} 2>&1 | tee -a "$log"
  build_status="${PIPESTATUS[0]}"
  if [[ "$build_status" != "0" ]]; then
    echo "==> Build failed (exit $build_status)" | tee -a "$log"
    rm -rf "$work"
    return 1
  fi
  local build_seconds=$((SECONDS - started))

  if ! lv_shard_swift test list --skip-build >"$work/list" 2>"$work/list.err"; then
    { cat "$work/list.err" "$work/list"; echo "==> Listing the tests failed"; } | tee -a "$log"
    rm -rf "$work"
    return 1
  fi
  if ! LV_SHARD_SKIP_PATTERNS="$skip_names" lv_plan_unit_shards "$shards" "$LV_SHARD_WEIGHTS" \
      <"$work/list" >"$work/plan" 2>"$work/plan.err"; then
    { echo "==> No shard plan from this listing:"; cat "$work/plan.err" "$work/list"; } | tee -a "$log"
    rm -rf "$work"
    return 1
  fi
  local expected=0 planned count
  planned="$(wc -l <"$work/plan" | tr -d ' ')"
  while read -r count _; do expected=$((expected + count)); done <"$work/plan"
  echo "==> $expected tests in $planned shards (build ${build_seconds} s)" | tee -a "$log"

  # Ctrl-C or the CI supervisor's timeout still leaves every shard's output so
  # far in the log, so a hang names the test it hung in; the caller's own
  # handlers run afterwards. Armed before the first shard starts, and the
  # handler reads LV_SHARD_* at signal time, so no signal finds it missing.
  LV_SHARD_WORK="$work" LV_SHARD_LOG="$log" LV_SHARD_PLANNED="$planned"
  LV_SHARD_PIDS=()
  LV_SHARD_SAVED_TRAPS="$(trap -p INT TERM HUP)"
  trap 'lv_interrupt_unit_shards INT' INT
  trap 'lv_interrupt_unit_shards TERM' TERM
  trap 'lv_interrupt_unit_shards HUP' HUP

  local index=0 line class
  while read -r line; do
    index=$((index + 1))
    local -a filter_args=()
    for class in ${line#* }; do
      # "Module.Class/" matches that class's methods and no other class's:
      # the module name pins the start and the slash the end, without the
      # regex metacharacters the build gate refuses.
      filter_args+=(--filter "$class/")
    done
    lv_run_one_unit_shard "$work" "$index" \
      ${skip_args[@]+"${skip_args[@]}"} "${filter_args[@]}" \
      ${extra_args[@]+"${extra_args[@]}"} &
    LV_SHARD_PIDS+=($!)
  done <"$work/plan"

  local ran=0 status=0 shard_status seconds executed classes
  for index in $(seq 1 "$planned"); do
    wait "${LV_SHARD_PIDS[$((index - 1))]}" 2>/dev/null
    read -r shard_status seconds <"$work/$index.status" 2>/dev/null || { shard_status=1; seconds="?"; }
    executed="$(lv_executed_test_count "$work/$index.log")"
    ran=$((ran + executed))
    classes="$(sed -n "${index}p" "$work/plan" | awk '{ print NF - 1 }')"
    {
      echo "==> Shard $index/$planned: $classes classes"
      cat "$work/$index.log"
      echo "==> Shard $index/$planned: exit $shard_status, $executed tests, ${seconds} s"
    } | tee -a "$log"
    : >"$work/$index.logged"
    [[ "$shard_status" == "0" ]] || status=1
  done
  trap - INT TERM HUP
  eval "$LV_SHARD_SAVED_TRAPS"

  echo "==> Unit shards: $ran of $expected tests ran in $planned shards, $((SECONDS - started)) s (build ${build_seconds} s)" \
    | tee -a "$log"
  if (( ran != expected )); then
    echo "==> FAILED: the shards ran $ran tests; the listing holds $expected" | tee -a "$log"
    status=1
  fi
  rm -rf "$work"
  return "$status"
}

# Background job: one shard's `swift test`, its output and "<exit> <seconds>".
# A TERM reaches `swift test` too: `lv_shard_swift &` is a subshell, so the
# swift process is its child, which killing the subshell alone would orphan.
#
# --skip-build still opens SwiftPM's build database, and a sibling shard that
# holds it at that moment makes this one exit before running any test ("database
# is locked"). Only that case is retried, up to twice.
lv_run_one_unit_shard() {
  local work="$1" index="$2" child shard_status shard_started=$SECONDS attempt
  shift 2
  : >"$work/$index.log"
  for attempt in 1 2 3; do
    lv_shard_swift test --skip-build --ignore-lock "$@" >"$work/$index.attempt" 2>&1 &
    child=$!
    # shellcheck disable=SC2064
    trap "pkill -TERM -P $child 2>/dev/null; kill $child 2>/dev/null; wait $child 2>/dev/null; cat '$work/$index.attempt' >>'$work/$index.log'; exit 143" TERM INT HUP
    wait "$child"
    shard_status=$?
    cat "$work/$index.attempt" >>"$work/$index.log"
    if (( shard_status == 0 || attempt == 3 )) \
        || ! grep -q "database is locked" "$work/$index.attempt" \
        || [[ "$(lv_executed_test_count "$work/$index.attempt")" != "0" ]]; then
      break
    fi
    echo "==> Shard $index: SwiftPM's build database was locked by another shard; retrying" \
      >>"$work/$index.log"
    sleep 1
  done
  echo "$shard_status $((SECONDS - shard_started))" >"$work/$index.status"
}

# Signal handler of lv_run_unit_shards: stop the shards, log what they printed,
# then restore the caller's handlers and deliver the signal again to them.
lv_interrupt_unit_shards() {
  local signal="$1" index
  trap '' INT TERM HUP
  if (( ${#LV_SHARD_PIDS[@]} > 0 )); then
    kill "${LV_SHARD_PIDS[@]}" 2>/dev/null
    wait "${LV_SHARD_PIDS[@]}" 2>/dev/null
  fi
  for index in $(seq 1 "$LV_SHARD_PLANNED"); do
    [[ -f "$LV_SHARD_WORK/$index.logged" ]] && continue
    {
      echo "==> Shard $index/$LV_SHARD_PLANNED: INTERRUPTED; its output so far:"
      cat "$LV_SHARD_WORK/$index.log" 2>/dev/null
    } | tee -a "$LV_SHARD_LOG"
  done
  rm -rf "$LV_SHARD_WORK"
  trap - INT TERM HUP
  eval "$LV_SHARD_SAVED_TRAPS"
  kill -s "$signal" $$
  # Reached only when the caller's handler returned instead of exiting.
  case "$signal" in
    HUP) exit 129 ;;
    INT) exit 130 ;;
    *) exit 143 ;;
  esac
}
