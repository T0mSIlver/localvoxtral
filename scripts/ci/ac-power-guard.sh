#!/usr/bin/env bash
# ac-power-guard.sh — decide whether a SCHEDULED self-hosted lane should run,
# based on the runner's power source.
#
# The self-hosted runner is the owner's personal MacBook (owner request,
# 2026-07-24): scheduled lanes — the eval-e2e nightly and the ui-smoke
# evening ladder — must not drain the battery when the machine is unplugged.
# Manual dispatches and label-triggered runs are explicit operator intent and
# never consult this guard; that enforcement is the caller's
# `github.event_name == 'schedule'` condition (or ui-smoke-guard.sh, which is
# itself schedule-only), not this script.
#
#   skip — the Mac is drawing from battery (or a UPS: also a battery)
#   run  — on AC power, or the probe is unavailable/unparseable. Probe
#          errors fail OPEN: an uncomputable state must never silently
#          disable a lane (same philosophy as ui-smoke-guard.sh and the CI
#          lane filters). Note the direction this buys: with a broken probe
#          a scheduled lane MAY still run unplugged — "never run on battery"
#          is best-effort by design, traded for "never silently dead".
#
# Output (GitHub-output style on stdout):
#   run=true|false
#   reason=<one line>
#
# Test seam (see test-ac-power-guard.sh):
#   AC_POWER_GUARD_STATE  ac|battery|error
set -euo pipefail

power_state() {
  if [[ -n "${AC_POWER_GUARD_STATE:-}" ]]; then
    echo "$AC_POWER_GUARD_STATE"
    return
  fi
  # `pmset -g ps` opens with "Now drawing from 'AC Power'" / "'Battery
  # Power'" / "'UPS Power'". Anything else — pmset absent (non-Mac), exit
  # failure, changed wording — is an error state and fails open.
  # Capture whole output, then take the first line via parameter expansion:
  # a `pmset | head -n 1` pipe under pipefail dies of SIGPIPE when the output
  # outgrows the pipe buffer, clobbering a successfully read battery line
  # into fail-open (PR #187 review finding; test: 80 KB trailing output).
  local raw first_line
  raw="$(pmset -g ps 2>/dev/null)" || raw=""
  first_line="${raw%%$'\n'*}"
  case "$first_line" in
    *"AC Power"*) echo "ac" ;;
    *"Battery Power"* | *"UPS Power"*) echo "battery" ;;
    *) echo "error" ;;
  esac
}

state="$(power_state)"
case "$state" in
  battery)
    echo "run=false"
    echo "reason=runner is on battery power — scheduled lanes wait for AC"
    ;;
  ac)
    echo "run=true"
    echo "reason=runner is on AC power"
    ;;
  *)
    echo "run=true"
    echo "reason=power probe unavailable ($state) — failing open"
    ;;
esac
