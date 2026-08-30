#!/usr/bin/env bash
# screen-lock-state.sh — print the console session's lock state, one word:
#
#   locked      a user is on the console and the screen is locked
#   unlocked    a user is on the console and the screen is not locked
#   no-session  nobody is logged into the console (or no GUI session at all)
#   error       the state could not be determined
#
# Extracted from ui-smoke-guard.sh so the SSH UI gate
# (scripts/mac/localvoxtral-ui-gate.sh) and the CI lane share ONE probe.
# The two callers deliberately apply OPPOSITE policies to `error`, and that
# asymmetry is the point of keeping the policy out of here:
#   - ui-smoke-guard fails OPEN (an uncomputable state must never silently
#     disable a scheduled lane);
#   - the UI gate fails CLOSED (it drives the owner's personal desktop; an
#     uncomputable state must never let it act).
#
# Two probes, in order:
#
# 1. CGSessionCopyCurrentDictionary — correct and cheap, but it only answers
#    from a process that already belongs to a GUI session. The CI runner is a
#    LaunchAgent in the console session, so this arm answers there.
# 2. ioreg IOConsoleUsers — the SAME CGSSessionScreenIsLocked key, read out of
#    the IORegistry instead of the caller's own session. This arm is what makes
#    the probe usable from an SSH login (the UI gate's case), where arm 1
#    returns no-session because the sshd session is not the Aqua session.
#
# Arm 2 only runs when arm 1 cannot answer, so the runner's behaviour is
# unchanged.
#
# Test seams (see test-ui-gate.sh):
#   LV_SCREEN_LOCK_STATE       locked|unlocked|no-session|error — short-circuit
#   LV_SCREEN_LOCK_SWIFT_CMD   command replacing `swift` for arm 1
#   LV_SCREEN_LOCK_IOREG_CMD   command replacing `ioreg` for arm 2
set -euo pipefail

if [[ -n "${LV_SCREEN_LOCK_STATE:-}" ]]; then
  printf '%s\n' "$LV_SCREEN_LOCK_STATE"
  exit 0
fi

swift_probe() {
  local swift_cmd="${LV_SCREEN_LOCK_SWIFT_CMD:-swift}"
  command -v "${swift_cmd%% *}" >/dev/null 2>&1 || { echo "error"; return; }
  # The lock key is only present, with value 1, while the screen is locked.
  # shellcheck disable=SC2086  # seam is a command line, split on purpose
  $swift_cmd - <<'SWIFT' 2>/dev/null || echo "error"
import CoreGraphics

guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
  print("no-session")
  exit(0)
}
print(session["CGSSessionScreenIsLocked"] != nil ? "locked" : "unlocked")
SWIFT
}

# `ioreg -n Root -d1 -a` prints an XML plist whose IOConsoleUsers array holds
# one dict per console session. Keys of interest, both optional:
#   kCGSSessionOnConsoleKey    <true/> while that session owns the console
#   CGSSessionScreenIsLocked   <true/> while its screen is locked
# The value element follows its <key>, so track the last key seen and inspect
# the next value. Only sessions currently ON the console count: a
# fast-user-switched-away session keeps stale lock keys.
ioreg_probe() {
  local ioreg_cmd="${LV_SCREEN_LOCK_IOREG_CMD:-ioreg -n Root -d1 -a}"
  command -v "${ioreg_cmd%% *}" >/dev/null 2>&1 || { echo "error"; return; }
  local raw
  # shellcheck disable=SC2086  # seam is a command line, split on purpose
  raw="$($ioreg_cmd 2>/dev/null)" || raw=""
  if [[ "$raw" != *IOConsoleUsers* ]]; then
    echo "error"
    return
  fi
  # Tokenised on `<` rather than parsed line by line: ioreg's XML puts each
  # element on its own line, but a hand-written or re-serialised plist may pack
  # several onto one, and a probe that silently reads such a file as
  # "no-session" would fail OPEN in the CI lane.
  awk '
    {
      n = split($0, parts, "<")
      for (i = 2; i <= n; i++) {
        token = "<" parts[i]
        if (token ~ /^<key>/) {
          key = substr(token, 6)
        } else if (token ~ /^<true\/>/ || token ~ /^<false\/>/) {
          value = (token ~ /^<true\/>/) ? 1 : 0
          if (key == "kCGSSessionOnConsoleKey") on_console = value
          else if (key == "CGSSessionScreenIsLocked") locked = value
          key = ""
        } else if (token ~ /^<\/dict>/) {
          # A dict boundary ends one session record: decide it before the next
          # one overwrites the flags.
          if (on_console) {
            found = 1
            if (locked) any_locked = 1
          }
          on_console = 0
          locked = 0
          key = ""
        }
      }
    }
    END {
      if (!found) print "no-session"
      else if (any_locked) print "locked"
      else print "unlocked"
    }
  ' <<<"$raw"
}

state="$(swift_probe)"
case "$state" in
  locked | unlocked)
    printf '%s\n' "$state"
    exit 0
    ;;
esac

# Arm 1 said no-session or error: ask the IORegistry, which answers from
# outside the caller's session.
fallback="$(ioreg_probe)"
case "$fallback" in
  locked | unlocked | no-session)
    printf '%s\n' "$fallback"
    ;;
  *)
    # Keep arm 1's answer when it was at least "no-session" — that is more
    # informative than "error".
    printf '%s\n' "${state:-error}"
    ;;
esac
