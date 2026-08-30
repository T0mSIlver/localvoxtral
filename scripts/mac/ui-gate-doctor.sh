#!/usr/bin/env bash
set -uo pipefail

# ui-gate-doctor — the UI gate's first-install checklist, executable.
#
#   scripts/mac/ui-gate-doctor.sh                    # on the Mac's GUI account
#   scripts/mac/ui-gate-doctor.sh --remote lv-ui     # from the Linux dev box
#   scripts/mac/ui-gate-doctor.sh --state-file <f>   # render a captured `state`
#
# Why it exists. Every setup item this reports was, in a real session
# (2026-08-30), invisible until a verb failed — and each failure looked exactly
# like a broken verb: `term open` refused everything because
# ~/.localvoxtral-ui-gate.conf did not exist, `app` denied because the dogfood
# socket's runtime consent was off, and nobody could see either from outside.
# The numbered list in scripts/mac/README.md said all of it; prose the owner
# reads and mis-follows is not a check.
#
# Every line is either `ok` or `FIX` followed by ONE copy-pasteable command.
# Exit 0 when nothing needs attention, 1 when something does, 2 when the gate
# could not be reached at all.
#
# What it cannot do, in any mode: prove that a TCC grant works in a session
# that arrived over SSH (it reports what the gate's own preflight saw), or that
# a capture is not black, or that a status menu appears. Those stay in the
# README's hand list, which now names only the items a script genuinely cannot
# reach.

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
REPO_GATE="$ROOT_DIR/scripts/mac/localvoxtral-ui-gate.sh"
INSTALLED_GATE="${LV_UI_INSTALLED_GATE:-$HOME/bin/localvoxtral-ui-gate.sh}"
AUTHORIZED_KEYS="${LV_UI_AUTHORIZED_KEYS:-$HOME/.ssh/authorized_keys}"

MODE=local
REMOTE_DEST=""
STATE_FILE=""

die() { printf 'ui-gate-doctor: %s\n' "$1" >&2; exit "${2:-2}"; }

while (( $# > 0 )); do
  case "$1" in
    --remote)
      shift
      [[ $# -gt 0 ]] || die "--remote needs an ssh destination"
      MODE=remote
      REMOTE_DEST="$1"
      ;;
    --state-file)
      shift
      [[ $# -gt 0 ]] || die "--state-file needs a path"
      MODE=file
      STATE_FILE="$1"
      ;;
    -h | --help)
      sed -n '3,12p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 \
  || die "python3 is required to read the gate's JSON"

# --- get a `state` document ------------------------------------------------

STATE_JSON=""
STATE_SOURCE=""
case "$MODE" in
  remote)
    STATE_JSON="$(ssh "$REMOTE_DEST" state 2>/dev/null || true)"
    STATE_SOURCE="ssh $REMOTE_DEST state"
    [[ -n "$STATE_JSON" ]] \
      || die "\`ssh $REMOTE_DEST state\` returned nothing — the key, the forced command or the host is wrong. Try: ssh -v $REMOTE_DEST state"
    ;;
  file)
    [[ -f "$STATE_FILE" ]] || die "no such file: $STATE_FILE"
    STATE_JSON="$(cat "$STATE_FILE")"
    STATE_SOURCE="$STATE_FILE"
    ;;
  local)
    [[ -x "$INSTALLED_GATE" ]] \
      || die "the gate is not installed at $INSTALLED_GATE. Install it: install -d -m 0700 \"\$HOME/bin\" && install -m 0755 $REPO_GATE \"$INSTALLED_GATE\""
    # Run the INSTALLED copy exactly as sshd would, so this reports the gate
    # the key actually reaches rather than the one in this checkout.
    STATE_JSON="$(SSH_ORIGINAL_COMMAND=state "$INSTALLED_GATE" 2>/dev/null || true)"
    STATE_SOURCE="$INSTALLED_GATE"
    [[ -n "$STATE_JSON" ]] \
      || die "$INSTALLED_GATE produced no output for \`state\`. Run it directly to see why: SSH_ORIGINAL_COMMAND=state $INSTALLED_GATE"
    ;;
esac

# --- local-only facts the gate cannot report about itself ------------------
#
# Passed in as key=value lines; the renderer treats an absent key as
# "not checkable from here" and stays quiet rather than guessing.

local_facts() {
  [[ "$MODE" == local ]] || return 0

  local installed_sum="" repo_sum=""
  installed_sum="$(sha256_of "$INSTALLED_GATE")"
  repo_sum="$(sha256_of "$REPO_GATE")"
  if [[ -n "$installed_sum" && -n "$repo_sum" ]]; then
    if [[ "$installed_sum" == "$repo_sum" ]]; then
      printf 'installed_gate=current\n'
    else
      printf 'installed_gate=stale\n'
    fi
  fi

  if [[ -f "$AUTHORIZED_KEYS" ]]; then
    if grep -q "command=\"$INSTALLED_GATE\"" "$AUTHORIZED_KEYS" 2>/dev/null; then
      if grep -q "restrict,command=\"$INSTALLED_GATE\"" "$AUTHORIZED_KEYS" 2>/dev/null; then
        printf 'forced_command=restrict\n'
      else
        printf 'forced_command=unrestricted\n'
      fi
    else
      printf 'forced_command=absent\n'
    fi
  else
    printf 'forced_command=no-authorized-keys\n'
  fi

  printf 'repo_gate=%s\n' "$REPO_GATE"
  printf 'installed_gate_path=%s\n' "$INSTALLED_GATE"
}

sha256_of() { # <path> -> lowercase digest, empty when unreadable
  local out=""
  [[ -f "$1" ]] || return 0
  if command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 "$1" 2>/dev/null || true)"
  elif command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum "$1" 2>/dev/null || true)"
  fi
  out="${out%% *}"
  [[ "$out" =~ ^[0-9a-f]{64}$ ]] && printf '%s' "$out"
}

FACTS="$(local_facts)"

# --- render ----------------------------------------------------------------

STATE_JSON="$STATE_JSON" FACTS="$FACTS" STATE_SOURCE="$STATE_SOURCE" MODE="$MODE" \
python3 <<'PY'
import json
import os
import sys

raw = os.environ["STATE_JSON"]
facts = dict(
    line.split("=", 1)
    for line in os.environ.get("FACTS", "").splitlines()
    if "=" in line
)
mode = os.environ["MODE"]

try:
    state = json.loads(raw)
except ValueError:
    sys.stderr.write(
        "ui-gate-doctor: %s did not return JSON. First 200 bytes:\n%s\n"
        % (os.environ["STATE_SOURCE"], raw[:200])
    )
    raise SystemExit(2)

setup = state.get("setup")
if setup is None:
    sys.stderr.write(
        "ui-gate-doctor: this `state` has no `setup` section, so the gate that "
        "answered predates setup reporting. Reinstall it from this checkout:\n"
        "  install -m 0755 scripts/mac/localvoxtral-ui-gate.sh ~/bin/localvoxtral-ui-gate.sh\n"
    )
    raise SystemExit(2)

rows = []          # (status, label, detail, fix)
def ok(label, detail=""):
    rows.append(("ok", label, detail, ""))
def fix(label, detail, command):
    rows.append(("FIX", label, detail, command))
def note(label, detail):
    rows.append(("--", label, detail, ""))

GATE_CONF = "~/.localvoxtral-ui-gate.conf"
ATTACH_CONF = "~/.lv-attach.conf"

# 1. the gate itself
rev = setup.get("gate", {}).get("revision", "unknown")
if facts.get("installed_gate") == "stale":
    fix("gate script",
        "the installed gate differs from this checkout (revision %s)" % rev,
        "install -m 0755 %s %s"
        % (facts.get("repo_gate", "scripts/mac/localvoxtral-ui-gate.sh"),
           facts.get("installed_gate_path", "~/bin/localvoxtral-ui-gate.sh")))
elif facts.get("installed_gate") == "current":
    ok("gate script", "revision %s, matches this checkout" % rev)
else:
    ok("gate script",
       "revision %s (compare: shasum -a 256 scripts/mac/localvoxtral-ui-gate.sh)" % rev)

# 2. the forced command (local only)
forced = facts.get("forced_command")
if forced == "restrict":
    ok("forced command", "restrict,command= on the gate key")
elif forced == "unrestricted":
    fix("forced command",
        "the key forces the gate but without `restrict` (pty and forwarding stay open)",
        "edit ~/.ssh/authorized_keys: prefix the gate's key line with  restrict,")
elif forced == "absent":
    fix("forced command",
        "no authorized_keys line forces the gate — the key would get a shell",
        'add to ~/.ssh/authorized_keys:  restrict,command="%s" <the ui-gate public key>'
        % facts.get("installed_gate_path", "~/bin/localvoxtral-ui-gate.sh"))
elif forced == "no-authorized-keys":
    fix("forced command", "no ~/.ssh/authorized_keys at all",
        "see scripts/mac/README.md, 'One-time install (owner GUI session on the Mac)'")

# 3. the lock probe — fail-closed, so a missing probe denies every GUI verb
if setup.get("lock_probe", {}).get("installed"):
    lock = state.get("screen_lock", "unknown")
    if lock == "unlocked":
        ok("screen lock", "unlocked")
    elif lock == "locked":
        note("screen lock",
             "locked — `state`, `log` and `gate-log` answer; every GUI verb denies until you unlock")
    else:
        fix("screen lock",
            "the probe answered %r, which denies every GUI-touching verb (fail closed)" % lock,
            "run the probe by hand on the Mac: ~/bin/localvoxtral-screen-lock-state.sh")
else:
    fix("lock probe",
        "not installed, so every GUI-touching verb denies (fail closed)",
        "install -m 0755 scripts/ci/screen-lock-state.sh ~/bin/localvoxtral-screen-lock-state.sh")

# 4. TCC — reported, never proved: this is what the gate's preflight saw.
tcc = state.get("tcc", {})
for key, label, verbs in (
    ("accessibility", "TCC accessibility", "ax dump/click/type, key, menu, dictate"),
    ("screen_recording", "TCC screen recording", "shot"),
):
    if tcc.get(key):
        ok(label, "granted (%s)" % verbs)
    else:
        fix(label, "not granted — %s cannot work" % verbs,
            "System Settings > Privacy & Security > %s: add /usr/libexec/sshd-keygen-wrapper"
            % ("Accessibility" if key == "accessibility" else "Screen Recording"))

# 5. the gate conf and the term-open allowlist
conf = setup.get("gate_conf", {})
term = setup.get("term_open", {})
commands = term.get("commands", [])
blocked = term.get("refused_by_denylist", [])
if conf.get("status") == "unparsable":
    fix("gate conf",
        "%s has a syntax error and is being IGNORED — every setting is at its default"
        % GATE_CONF,
        "bash -n %s   # then fix the line it names" % GATE_CONF)
elif not conf.get("present"):
    fix("gate conf",
        "%s does not exist, so `term open` accepts nothing" % GATE_CONF,
        "printf 'LV_UI_TERM_COMMANDS=\"lv-attach\"\\n' >> %s" % GATE_CONF)
else:
    ok("gate conf", "%s present and parses" % GATE_CONF)

unresolvable = term.get("unresolvable", [])
if not commands:
    fix("term open allowlist",
        "empty — `term open` denies every command (this is the shipped default)",
        "printf 'LV_UI_TERM_COMMANDS=\"lv-attach\"\\n' >> %s" % GATE_CONF)
elif unresolvable:
    # The 2026-08-30 failure exactly: allowlisted, and no executable behind it.
    # `term open` used to open an empty window and then blame the window.
    fix("term open allowlist",
        "allowlisted with no executable in ~/bin: %s — `term open` refuses these "
        "and opens nothing" % " ".join(unresolvable),
        "./scripts/mac/install-ui-artifact.sh dist/localvoxtral.app   # installs ~/bin/lv-attach")
elif blocked:
    fix("term open allowlist",
        "%s allowlisted but permanently refused (they can run a child command): %s"
        % (len(blocked), " ".join(blocked)),
        "remove %s from LV_UI_TERM_COMMANDS in %s" % (" ".join(blocked), GATE_CONF))
else:
    ok("term open allowlist", "accepts: %s" % " ".join(commands))

# 6. lv-attach: installed, allowlisted, and its own config resolving
attach = setup.get("lv_attach", {})
if not attach.get("installed"):
    fix("lv-attach wrapper",
        "not installed at ~/bin/lv-attach, so `term open ... lv-attach` cannot resolve it",
        "./scripts/mac/install-ui-artifact.sh dist/localvoxtral.app   # ships the wrapper too")
else:
    ok("lv-attach wrapper", "installed at ~/bin/lv-attach")

# Only worth its own row when the allowlist is non-empty: an empty one is
# already the row above, and repeating the same fix three times is how a
# checklist stops being read.
if attach.get("allowlisted"):
    ok("lv-attach allowlisted", "in LV_UI_TERM_COMMANDS")
elif attach.get("installed") and commands:
    fix("lv-attach allowlisted",
        "installed, but LV_UI_TERM_COMMANDS lists only %s" % " ".join(commands),
        "add lv-attach to LV_UI_TERM_COMMANDS in %s" % GATE_CONF)

attach_conf = attach.get("conf")
if attach_conf == "ok":
    where = attach.get("destination") or "a user@host destination (value withheld)"
    ok("lv-attach destination",
       "%s resolves -> %s%s"
       % (ATTACH_CONF, where,
          ", default session set" if attach.get("session_default") else ""))
elif attach_conf in ("missing", "absent"):
    fix("lv-attach destination", "%s does not exist" % ATTACH_CONF,
        "printf 'destination=<your ssh alias>\\n' > %s" % ATTACH_CONF)
elif attach_conf == "no-destination":
    fix("lv-attach destination", "%s has no destination= line" % ATTACH_CONF,
        "printf 'destination=<your ssh alias>\\n' >> %s" % ATTACH_CONF)
elif attach_conf == "invalid-destination":
    fix("lv-attach destination",
        "%s has a destination the wrapper refuses (it must be [A-Za-z0-9._-], "
        "optionally user@host, never starting with '-')" % ATTACH_CONF,
        "edit %s   # then: ~/bin/lv-attach --check" % ATTACH_CONF)
elif attach_conf == "invalid-session":
    fix("lv-attach destination",
        "%s has a session= the wrapper refuses" % ATTACH_CONF,
        "edit %s   # then: ~/bin/lv-attach --check" % ATTACH_CONF)
elif attach_conf == "present-unchecked":
    note("lv-attach destination",
         "%s exists but no wrapper is installed to validate it" % ATTACH_CONF)
elif attach_conf == "wrapper-too-old":
    fix("lv-attach destination",
        "the installed ~/bin/lv-attach predates `--check`, so its config cannot be validated",
        "./scripts/mac/install-ui-artifact.sh dist/localvoxtral.app   # refreshes the wrapper")

# 7. something to launch
artifacts = setup.get("artifacts", [])
if artifacts:
    ok("launchable builds",
       ", ".join("%s%s" % (a.get("name"), " (dogfood)" if a.get("dogfood") else "")
                 for a in artifacts))
else:
    fix("launchable builds",
        "no localvoxtral bundle under the artifact roots — `launch` has nothing to start",
        "./scripts/try-pr.sh <pr> --dogfood --ui-gate    # or: gh workflow run CI --ref <branch> -f dogfood=true")

# 8. the app under test
app = state.get("app", {})
if app.get("running"):
    ok("app under test",
       "pid %s%s" % (app.get("pid"), ", dogfood" if app.get("dogfood") else ", not a dogfood build"))
else:
    note("app under test",
         "none — `launch [--dogfood] <artifact>` first; shot/ax/key/menu/dictate/app all need one")

# 9. the dogfood control socket — TWO consents, deliberately
socket = setup.get("control_socket", {})
if socket.get("present"):
    ok("control socket", "bound; `app <command>` can be forwarded")
elif socket.get("consent") == "on":
    note("control socket",
         "consent armed but no socket bound — relaunch the dogfood build (`quit`, then `launch --dogfood ...`)")
else:
    fix("control socket",
        "debug.dogfood_control_socket_enabled is %s, so `app <command>` denies "
        "(a second consent on purpose — recording what you do and accepting "
        "commands on a socket are separate grants, and no installer arms this one)"
        % socket.get("consent", "unset"),
        "defaults write com.localvoxtral.app debug.dogfood_control_socket_enabled -bool true   # then relaunch")

width = max(len(label) for _, label, _, _ in rows)
print("localvoxtral UI gate readiness (%s)" % os.environ["STATE_SOURCE"])
print()
for status, label, detail, command in rows:
    print("  [%-3s] %-*s  %s" % (status, width, label, detail))
    if command:
        print("  %s  fix: %s" % (" " * (width + 7), command))
print()

pending = [r for r in rows if r[0] == "FIX"]
if pending:
    print("%d item(s) need attention. Re-run after each fix." % len(pending))
else:
    print("Every checkable item is ready.")
if mode != "local":
    print("Not checkable from here: the forced-command line and whether the "
          "installed gate matches this checkout — run this on the Mac for those.")
print("Never checkable by any script: that a TCC grant works in a session that "
      "arrived over SSH, that a capture is not black, and that a status menu "
      "appears — scripts/mac/README.md keeps those as hand checks.")

raise SystemExit(1 if pending else 0)
PY
