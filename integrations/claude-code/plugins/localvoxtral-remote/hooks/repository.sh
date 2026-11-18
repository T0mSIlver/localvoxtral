#!/bin/sh
# localvoxtral repository reader — strict POSIX sh, needs only git.
#
#   repository.sh
#
# Prints the repository the current directory's `origin` names: owner/name
# when it is on github.com, else host/path (#971), and nothing without an
# origin. The hook shim sends it as X-Lvx-Env-Repository (#926), so the Mac
# merges every checkout of one repository into one project. A Mac before #971
# drops a host/path value. It reads no token and starts nothing; the agent
# projects scan runs it from each repository's directory.
set -u

# remote_repo <remote-url>: the repository a remote URL names, as
# host/owner/name: https, http, ssh (with or without a user or a port), git,
# or scp-style user@host:path, with or without `.git`; nothing for a local
# path or any other shape. ProjectRemote(remoteURL:) reads the same shapes on
# the Mac.
remote_repo() {
  case "$1" in
  https://* | http://* | ssh://* | git://*)
    rest="${1#*://}"
    host="${rest%%/*}"
    path="${rest#"$host"}"
    host="${host##*@}"
    host="${host%%:*}"
    ;;
  /* | ./* | ../* | *://*) return 0 ;;
  *:*)
    host="${1%%:*}"
    case "$host" in */*) return 0 ;; esac
    host="${host##*@}"
    path="${1#*:}"
    ;;
  *) return 0 ;;
  esac
  host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"
  while [ "${path#/}" != "$path" ]; do path="${path#/}"; done
  while [ "${path%/}" != "$path" ]; do path="${path%/}"; done
  path="${path%.git}"
  case "$host/$path" in
  */.* | .* | *//* | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./-]*) ;;
  ?*/?*/?*) echo "$host/$path" ;;
  esac
}

# github_repo <remote-url>: its owner/name when it is a github.com URL;
# nothing otherwise.
github_repo() {
  repo="$(remote_repo "$1")"
  case "$repo" in
  github.com/*/*/*) ;;
  github.com/?*/?*) echo "${repo#github.com/}" ;;
  esac
}

ORIGIN="$(git remote get-url origin 2>/dev/null)" || exit 0
REPO="$(github_repo "$ORIGIN")"
[ -n "$REPO" ] || REPO="$(remote_repo "$ORIGIN")"
[ -z "$REPO" ] || echo "$REPO"
exit 0
