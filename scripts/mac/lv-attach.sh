#!/usr/bin/env bash
set -euo pipefail

# lv-attach — open a whole-view herdr client on the owner's configured host.
#
# THIS SCRIPT EXISTS TO BE ALLOWLISTED, and everything about it is shaped by
# that. `term open` in the UI gate (scripts/mac/localvoxtral-ui-gate.sh) checks
# only the FIRST token of a command against LV_UI_TERM_COMMANDS, so an
# allowlisted name is trusted with every argument it will ever be given. The
# gate's stated test for adding a name is: AN ALLOWLISTED COMMAND MUST NOT BE
# ABLE TO RUN A CHILD COMMAND — not "must not be a shell", must not be able to
# start one through any flag or subcommand. `ssh` fails that test outright and
# is permanently denylisted; `claude`, `codex`, `opencode` and `herdr agent
# start` each fail it too.
#
# This wrapper passes it, and here is the whole argument:
#
#   * It takes ONE optional argument, a herdr session NAME, and nothing else.
#     No command. No second positional. Anything unrecognised is refused, not
#     passed on. There is exactly one flag, `--check`, which prints a readiness
#     verdict and exits WITHOUT running anything (the UI gate's `state` uses it
#     so the destination validator below has one implementation, not two);
#     every other `-*` is still refused outright.
#   * That name must match ^[A-Za-z0-9._-]{1,64}$ and must not begin with `-`.
#     There is no character in that set that a shell treats specially, so the
#     name cannot become a flag to ssh, cannot escape the remote command that
#     ssh assembles, and cannot reach a remote shell as anything but a literal.
#   * The destination is NOT an argument. It is read from the owner's own
#     config file, and validated on the way out.
#   * The argv is fixed: `ssh -t -- <destination> herdr [--session <name>]`.
#     There is no code path in this file that runs anything else, and no
#     `eval`, `bash -c`, `sh -c`, or `$@` in a command position anywhere in it
#     (pinned by scripts/ci/test-ui-gate.sh).
#
# WHY A WHOLE-VIEW CLIENT AND NOT `herdr terminal attach <pane>`:
# the app classifies the ssh it finds on the focused surface
# (`HerdrInvocation`, docs/agent/invariants.md) and REFUSES every herdr shape
# except a bare `herdr` or `herdr --session <name>`. `terminal attach` renders
# one pane rather than the server-global focus the join reads, so a wrapper
# that opened one would reliably produce a window the app deliberately never
# joins — i.e. it would be useless for the exact debugging `term open` exists
# for. A pane is selected INSIDE herdr, after attaching.
#
# CONFIG — the owner writes this, once:
#
#   ~/.lv-attach.conf
#     destination=builder            # an ssh alias, or user@host
#     session=work                   # optional default session name
#
#   `lv-attach --check` says whether that file resolves, and
#   `ssh lv-ui state` reports the same verdict under setup.lv_attach.
#
# ALLOWLISTING IT — in ~/.localvoxtral-ui-gate.conf:
#
#   LV_UI_TERM_COMMANDS="lv-attach"
#
# and `lv-attach` must be on the PATH of a GUI-launched terminal
# (scripts/mac/install-ui-artifact.sh installs it to ~/bin/lv-attach).

CONF="${LV_ATTACH_CONF:-$HOME/.lv-attach.conf}"

die() {
  printf 'lv-attach: %s\n' "$1" >&2
  exit "${2:-1}"
}

# --- arguments -------------------------------------------------------------
#
# Parsed by shape, not by loop-with-fallthrough: there is exactly one accepted
# shape and everything else is an error. In particular `-*` is refused BEFORE
# the charset check, so the error message names the real problem.

SESSION=""
CHECK=0
if (( $# > 1 )); then
  die "takes at most one argument (a herdr session name); got $#"
fi
if (( $# == 1 )); then
  case "$1" in
    # The ONE accepted flag, and the only code path in this file that does not
    # end in `exec ssh`. It exists because the UI gate's `state` has to be able
    # to say whether this wrapper is installed and whether its config resolves,
    # and re-implementing the validator below inside the gate would give the
    # boundary two copies that can drift. It reads the same file with the same
    # `sed`, prints a verdict, and returns — it opens no connection and starts
    # no child, so allowlisting `lv-attach` still admits nothing that can run a
    # command. Every other `-*` is refused exactly as before.
    --check) CHECK=1 ;;
    -*) die "does not take flags (got: $1)" ;;
  esac
  if (( CHECK == 0 )); then
    # An explicitly empty argument is a mistake, not "use the configured
    # default": silently falling back would make `lv-attach "$SOMETHING_UNSET"`
    # open a session nobody asked for.
    [[ -n "$1" ]] || die "the session name is empty"
    SESSION="$1"
  fi
fi

# --- --check's report ------------------------------------------------------
#
# key=value lines on stdout, exit 0 only when this wrapper would actually run.
#
#   conf=ok|missing|no-destination|invalid-destination|invalid-session
#   destination_kind=alias|user@host        (present when conf=ok)
#   destination=<alias>                     (ONLY when the destination is a
#                                            bare alias — see below)
#   session=configured|absent               (present when conf=ok)
#
# The destination is echoed only when it is a bare alias, and this is a
# deliberate line rather than squeamishness. A bare alias is a label in the
# owner's own ~/.ssh/config: it names no account and no address, and it is the
# value an operator actually needs, because the failure it catches is "this
# points at the wrong machine". A `user@host` destination IS an account and an
# address, and this gate's stated posture is that no host, session id or
# account crosses it (see `app`'s closed reply vocabulary). So the shape is
# reported and the value is not.
report_check() { # <status> [kind] [destination] [session]
  printf 'conf=%s\n' "$1"
  if [[ "$1" == ok ]]; then
    printf 'destination_kind=%s\n' "$2"
    [[ "$2" == alias ]] && printf 'destination=%s\n' "$3"
    printf 'session=%s\n' "$4"
    return 0
  fi
  return 1
}

# --- config ----------------------------------------------------------------
#
# READ, never sourced. Sourcing would make the config file a shell script, and
# the whole point of this wrapper is that no caller-reachable path runs one.

if [[ ! -f "$CONF" ]]; then
  if (( CHECK == 1 )); then report_check missing || exit 1; fi
  die "no config at $CONF (needs a line: destination=<ssh alias>)"
fi

read_conf_value() { # <key>
  # First assignment wins; trailing whitespace and comments dropped. `sed`,
  # not `source`.
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" \
    | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
    | head -n 1
}

DESTINATION="$(read_conf_value destination)"
if [[ -z "$DESTINATION" ]]; then
  if (( CHECK == 1 )); then report_check no-destination || exit 1; fi
  die "$CONF has no destination= line"
fi

if [[ -z "$SESSION" ]]; then
  SESSION="$(read_conf_value session)"
fi

# --- validation ------------------------------------------------------------
#
# Both values are validated the same way and for the same reason: each becomes
# an argv element of a real ssh invocation, and the session name additionally
# becomes a token of the REMOTE command, which ssh assembles into a string the
# remote login shell interprets. The charset below contains nothing a shell
# treats specially — no whitespace, quote, backslash, `$`, backtick, `;`, `&`,
# `|`, `<`, `>`, `(`, `)`, `*`, `?`, `!`, `~`, `#`, `=`, `:` or `/` — so a name
# that passes cannot be anything but a literal on either side.
#
# `=` and `:` are excluded deliberately even though a shell would not act on
# them: they are how an ssh option (`-oProxyCommand=…`) and a `-L` forward spec
# are written, and a validator that admitted them would be one leading dash
# away from a hole.

is_safe_name() { # <value>
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$1" != -* ]] && (( ${#1} <= 64 ))
}

# The destination may carry a user (`builder@host`); nothing else.
is_safe_destination() { # <value>
  local value="$1" user="" host="$1"
  case "$value" in
    *@*)
      user="${value%%@*}"
      host="${value#*@}"
      [[ -n "$user" ]] || return 1
      is_safe_name "$user" || return 1
      ;;
  esac
  [[ "$host" != *@* ]] || return 1
  is_safe_name "$host"
}

if ! is_safe_destination "$DESTINATION"; then
  # `--check` deliberately does NOT echo the value it is rejecting: a refused
  # destination is the one case where the file's contents are arbitrary text.
  if (( CHECK == 1 )); then report_check invalid-destination || exit 1; fi
  die "refusing destination from $CONF: must be an alias or user@host of [A-Za-z0-9._-], not starting with '-' (got: $DESTINATION)"
fi

if [[ -n "$SESSION" ]] && ! is_safe_name "$SESSION"; then
  if (( CHECK == 1 )); then report_check invalid-session || exit 1; fi
  die "refusing session name: must be 1-64 characters of [A-Za-z0-9._-] and must not start with '-' (got: $SESSION)"
fi

# Everything this wrapper needs resolved. `--check` stops here, one step short
# of the only thing this file ever runs.
if (( CHECK == 1 )); then
  DESTINATION_KIND=alias
  [[ "$DESTINATION" == *@* ]] && DESTINATION_KIND=user@host
  report_check ok "$DESTINATION_KIND" "$DESTINATION" \
    "$([[ -n "$SESSION" ]] && printf 'configured' || printf 'absent')"
  exit 0
fi

# --- exec ------------------------------------------------------------------
#
# `--` before the destination so a destination cannot be read as an option even
# if the validation above were ever loosened. `-t` because herdr is a TUI and
# needs a pty; `-t` is the only ssh flag here and it takes no value.
#
# The two invocation shapes below are exactly the two `HerdrInvocation` accepts
# (docs/agent/invariants.md). Adding a third is not a change to this file — it
# is a change to what the app will join.

if [[ -n "$SESSION" ]]; then
  exec ssh -t -- "$DESTINATION" herdr --session "$SESSION"
fi
exec ssh -t -- "$DESTINATION" herdr
