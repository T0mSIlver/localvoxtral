# Security policy

## Reporting a vulnerability

Report privately through GitHub:
[**open a draft advisory**](https://github.com/T0mSIlver/localvoxtral/security/advisories/new).
Please do not open a public issue for anything exploitable.

Include the macOS version, the app version (menu bar → About), whether the
backend was managed or External URL, and the steps to reproduce. A crash log
from `~/Library/Logs/DiagnosticReports/` helps if the bug is a crash.

This is a single-maintainer project with no bounty programme. Expect a first
reply within a week. Once a fix ships, the advisory is published with credit
unless you ask otherwise.

## Supported versions

Only the latest stable release gets fixes. Nightlies are prereleases built
from `main` and are not a supported target.

## What is in scope

The app runs on your Mac, holds Accessibility and Microphone grants, and can
insert text into whatever window has focus. Anything that abuses that reach is
in scope:

- Code execution or command injection reachable from audio, a transcript, a
  model response, or a config file.
- Text reaching an application other than the focused one, or surviving past
  the commit it belonged to.
- Secrets escaping where they belong — an API key readable outside the
  keychain entry that holds it, or written to a log, a crash report, or a
  captured context payload.
- The remote-join path: the listener, the enrollment handshake, and the ssh
  forwards that connect the app to a coding-agent session on another machine.
- Release integrity — the signing and notarisation pipeline, or the Homebrew
  cask pointing at an artifact it did not build.

## What is not

- Anything that needs an attacker to already have your unlocked Mac.
- The server you point External URL mode at. You chose it; the app trusts it
  with your audio by design.
- macOS permission prompts. The app asks for Accessibility, Microphone and
  Screen Recording because the features named in the README need them.
- Resource exhaustion in a local helper process. It is a child process you
  started; killing it costs you a restart.
